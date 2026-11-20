// 편지: 친구에게 쓴 쪽지를 오모기가 물고 가서 30분~3시간 뒤에 전한다. 가끔은 잃어버린다.
// Mac 판(omogi/letters.swift)을 옮긴 것이다. 같은 서버를 쓰므로 Mac 친구와 편지를 주고받을 수 있다.
//
// 나르는 길은 둘이다 (ILetterTransport):
//   연습 배달 LoopbackPost — 나에게 보내면 이 PC 안에서 시간이 지난 뒤 돌아온다. 서버를 쓰지 않는다.
//   서버 배달 ServerPost (Server.cs) — 친구 코드로 맺은 친구에게 간다. 사용자가 "친구" 창에서 시작해야만 켜진다.
//
// 편지는 받는 사람만 열 수 있게 잠가서 보낸다 (LetterCrypto). Mac 판과 맞춰야 하므로 형식을 바꾸지 말 것:
//   봉투 = [버전 1바이트 = 1] + [보내는 쪽 임시 공개 키, P-256 X9.63 비압축 65바이트] + [AES-256-GCM: nonce 12 + 암호문 + tag 16]
//   키   = HKDF-SHA256(ECDH(P-256) 공유 비밀, salt 없음, info = "omogi-letter-v1" + 임시 공개 키 + 받는 사람 공개 키, 32바이트)

using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace Omogi
{
    static class LetterRules
    {
        public const int MaxChars = 200;
        public const int DailyLimit = 5;          // 친구 한 명에게 하루에 보낼 수 있는 수

        /// 사람이 세는 글자 수 (Mac 판의 String.count 와 맞춘다).
        public static int Count(string s)
        {
            return string.IsNullOrEmpty(s) ? 0 : new StringInfo(s).LengthInTextElements;
        }

        /// 편지 본문: 줄바꿈을 \n 하나로 맞추고 앞뒤 빈칸을 뗀다.
        public static string Clean(string s)
        {
            return (s ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Trim();
        }
    }

    // 파일과 JSON 을 다루는 작은 도구들.
    static class LetterFiles
    {
        public static string FormatDate(DateTime t)
        {
            return t.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        }

        public static bool ParseDate(string s, out DateTime t)
        {
            t = DateTime.MinValue;
            if (string.IsNullOrEmpty(s)) return false;
            return DateTime.TryParse(s, CultureInfo.InvariantCulture,
                                     DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out t);
        }

        /// JSON 배열 안의 객체들 (배열이 아니거나 없으면 빈 목록).
        public static List<Dictionary<string, object>> Rows(object o)
        {
            var list = new List<Dictionary<string, object>>();
            if (o == null || o is string) return list;
            var e = o as IEnumerable;
            if (e == null || o is IDictionary) return list;
            foreach (object x in e)
            {
                var d = x as Dictionary<string, object>;
                if (d != null) list.Add(d);
            }
            return list;
        }

        public static string Text(Dictionary<string, object> j, string key)
        {
            object o;
            return j != null && j.TryGetValue(key, out o) ? o as string : null;
        }

        public static bool Flag(Dictionary<string, object> j, string key)
        {
            object o;
            return j != null && j.TryGetValue(key, out o) && o is bool && (bool)o;
        }

        public static byte[] Base64(string s)
        {
            if (s == null) return null;
            try { return Convert.FromBase64String(s); }
            catch { return null; }
        }

        /// 쓰다가 꺼져도 예전 파일이 깨지지 않게 옆에 쓴 뒤 바꿔 놓는다.
        public static void WriteAtomic(string path, byte[] data)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string tmp = path + ".tmp";
            File.WriteAllBytes(tmp, data);
            if (File.Exists(path))
            {
                try { File.Replace(tmp, path, null); return; }
                catch { File.Delete(path); }
            }
            File.Move(tmp, path);
        }

        public static void WriteJson(string path, object value)
        {
            try { WriteAtomic(path, new UTF8Encoding(false).GetBytes(Json.Write(value))); }
            catch (Exception e) { Log.Write("편지: 파일을 쓰지 못함 (" + e.GetType().Name + ")"); }
        }
    }

    // ───────────────────── 이 PC 에만 두는 비밀 ─────────────────────
    // 편지 열쇠와 서버 로그인 정보를 두는 곳: %APPDATA%\Omogi\secrets\ . Windows 의 사용자 보호(DPAPI)로 잠가서
    // 이 Windows 계정으로만 열 수 있다. 다른 PC 로 파일을 옮기면 열리지 않는다.
    static class SecretStore
    {
        static string Dir { get { return Path.Combine(Config.Dir, "secrets"); } }

        public static byte[] Load(string name)
        {
            try
            {
                string path = Path.Combine(Dir, name);
                if (!File.Exists(path)) return null;
                byte[] locked = File.ReadAllBytes(path);
                if (locked.Length == 0) return null;
                return ProtectedData.Unprotect(locked, null, DataProtectionScope.CurrentUser);
            }
            catch (Exception e)
            {
                Log.Write("비밀 보관: " + name + " 을 열지 못함 (" + e.GetType().Name + ")");
                return null;
            }
        }

        public static bool Exists(string name)
        {
            try { return File.Exists(Path.Combine(Dir, name)); }
            catch { return false; }
        }

        /// data 가 null 이면 지운다.
        public static void Save(string name, byte[] data)
        {
            try
            {
                string path = Path.Combine(Dir, name);
                if (data == null) { if (File.Exists(path)) File.Delete(path); return; }
                LetterFiles.WriteAtomic(path, ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser));
            }
            catch (Exception e)
            {
                Log.Write("비밀 보관: " + name + " 을 쓰지 못함 (" + e.GetType().Name + ")");
            }
        }

        /// 열 수 없게 된 파일을 덮어쓰기 전에 옆으로 치워 둔다.
        public static void SetAside(string name)
        {
            try
            {
                string path = Path.Combine(Dir, name), bad = path + ".bad";
                if (!File.Exists(path)) return;
                if (File.Exists(bad)) File.Delete(bad);
                File.Move(path, bad);
            }
            catch { }
        }
    }

    // ───────────────────── 잠그기 ─────────────────────
    /// HKDF-SHA256 (RFC 5869).
    static class Hkdf
    {
        public static byte[] Extract(byte[] salt, byte[] ikm)
        {
            using (var h = new HMACSHA256(salt == null || salt.Length == 0 ? new byte[32] : salt)) return h.ComputeHash(ikm);
        }

        public static byte[] Expand(byte[] prk, byte[] info, int length)
        {
            if (length < 0 || length > 255 * 32) throw new ArgumentOutOfRangeException("length");
            var okm = new byte[length];
            var t = new byte[0];
            int done = 0;
            using (var h = new HMACSHA256(prk))
            {
                for (byte i = 1; done < length; i++)
                {
                    var block = new byte[t.Length + (info == null ? 0 : info.Length) + 1];
                    Buffer.BlockCopy(t, 0, block, 0, t.Length);
                    if (info != null) Buffer.BlockCopy(info, 0, block, t.Length, info.Length);
                    block[block.Length - 1] = i;
                    t = h.ComputeHash(block);
                    int n = Math.Min(t.Length, length - done);
                    Buffer.BlockCopy(t, 0, okm, done, n);
                    done += n;
                }
            }
            return okm;
        }
    }

    /// AES-256-GCM (Windows CNG, bcrypt.dll). nonce 12바이트, tag 16바이트, 덧붙이는 인증 자료 없음.
    static class AesGcm
    {
        public const int NonceSize = 12, TagSize = 16;
        const int StatusAuthTagMismatch = unchecked((int)0xC000A002);

        [StructLayout(LayoutKind.Sequential)]
        struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO
        {
            public int cbSize;
            public int dwInfoVersion;
            public IntPtr pbNonce;
            public int cbNonce;
            public IntPtr pbAuthData;
            public int cbAuthData;
            public IntPtr pbTag;
            public int cbTag;
            public IntPtr pbMacContext;
            public int cbMacContext;
            public int cbAAD;
            public long cbData;
            public int dwFlags;
        }

        [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
        static extern int BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, string pszAlgId, string pszImplementation, int dwFlags);
        [DllImport("bcrypt.dll")]
        static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);
        [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
        static extern int BCryptSetProperty(IntPtr hObject, string pszProperty, byte[] pbInput, int cbInput, int dwFlags);
        [DllImport("bcrypt.dll")]
        static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr phKey, IntPtr pbKeyObject, int cbKeyObject,
                                                     byte[] pbSecret, int cbSecret, int dwFlags);
        [DllImport("bcrypt.dll")]
        static extern int BCryptDestroyKey(IntPtr hKey);
        [DllImport("bcrypt.dll")]
        static extern int BCryptEncrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo,
                                        IntPtr pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);
        [DllImport("bcrypt.dll")]
        static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo,
                                        IntPtr pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);

        static void Check(int status, string what)
        {
            if (status != 0) throw new CryptographicException(what + " 0x" + status.ToString("X8"));
        }

        // 잠그기와 열기의 공통 부분. 열 때 tag 가 맞지 않으면 null.
        static byte[] Run(bool encrypt, byte[] key, byte[] nonce, byte[] input, byte[] tag)
        {
            if (key == null || key.Length != 32) throw new ArgumentException("key");
            if (nonce == null || nonce.Length != NonceSize) throw new ArgumentException("nonce");
            if (tag == null || tag.Length != TagSize) throw new ArgumentException("tag");
            IntPtr alg = IntPtr.Zero, hKey = IntPtr.Zero;
            GCHandle pinNonce = GCHandle.Alloc(nonce, GCHandleType.Pinned), pinTag = GCHandle.Alloc(tag, GCHandleType.Pinned);
            try
            {
                Check(BCryptOpenAlgorithmProvider(out alg, "AES", null, 0), "BCryptOpenAlgorithmProvider");
                byte[] mode = Encoding.Unicode.GetBytes("ChainingModeGCM\0");
                Check(BCryptSetProperty(alg, "ChainingMode", mode, mode.Length, 0), "BCryptSetProperty");
                Check(BCryptGenerateSymmetricKey(alg, out hKey, IntPtr.Zero, 0, key, key.Length, 0), "BCryptGenerateSymmetricKey");

                var info = new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
                info.cbSize = Marshal.SizeOf(typeof(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO));
                info.dwInfoVersion = 1;
                info.pbNonce = pinNonce.AddrOfPinnedObject();
                info.cbNonce = nonce.Length;
                info.pbTag = pinTag.AddrOfPinnedObject();
                info.cbTag = tag.Length;

                var output = new byte[input.Length];
                int written;
                int status = encrypt
                    ? BCryptEncrypt(hKey, input, input.Length, ref info, IntPtr.Zero, 0, output, output.Length, out written, 0)
                    : BCryptDecrypt(hKey, input, input.Length, ref info, IntPtr.Zero, 0, output, output.Length, out written, 0);
                if (!encrypt && status == StatusAuthTagMismatch) return null;
                Check(status, encrypt ? "BCryptEncrypt" : "BCryptDecrypt");
                if (written != input.Length) throw new CryptographicException("AES-GCM 길이");
                return output;
            }
            finally
            {
                if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
                if (alg != IntPtr.Zero) BCryptCloseAlgorithmProvider(alg, 0);
                pinNonce.Free();
                pinTag.Free();
            }
        }

        /// 암호문을 돌려주고 tag(16바이트)를 채운다.
        public static byte[] Encrypt(byte[] key, byte[] nonce, byte[] plain, out byte[] tag)
        {
            tag = new byte[TagSize];
            return Run(true, key, nonce, plain, tag);
        }

        /// tag 가 맞지 않으면(바뀐 편지, 다른 열쇠) null.
        public static byte[] Decrypt(byte[] key, byte[] nonce, byte[] cipher, byte[] tag)
        {
            return Run(false, key, nonce, cipher, (byte[])tag.Clone());
        }
    }

    /// 편지 열쇠 하나 (P-256). 공개 키는 X9.63 비압축 65바이트(04 + X + Y)로 다룬다.
    sealed class LetterKey : IDisposable
    {
        const int PublicMagic = 0x314B4345;      // BCRYPT_ECDH_PUBLIC_P256_MAGIC  "ECK1"
        const int PrivateMagic = 0x324B4345;     // BCRYPT_ECDH_PRIVATE_P256_MAGIC "ECK2"

        readonly CngKey key;
        /// X9.63 비압축 공개 키 65바이트
        public readonly byte[] Public;
        /// 비밀 값 D 32바이트 (새로 만들었거나 읽어 온 것. 이 PC 밖으로 내보내지 않는다)
        readonly byte[] scalar;

        LetterKey(CngKey key, byte[] pub, byte[] scalar)
        {
            this.key = key;
            Public = pub;
            this.scalar = scalar;
        }

        public static bool LooksLikePublic(byte[] x963)
        {
            return x963 != null && x963.Length == 65 && x963[0] == 4;
        }

        static byte[] Blob(int magic, byte[] x963, byte[] d)
        {
            var blob = new byte[8 + 64 + (d == null ? 0 : 32)];
            blob[0] = (byte)magic; blob[1] = (byte)(magic >> 8); blob[2] = (byte)(magic >> 16); blob[3] = (byte)(magic >> 24);
            blob[4] = 32;                                         // cbKey (little endian)
            Buffer.BlockCopy(x963, 1, blob, 8, 64);               // X, Y
            if (d != null) Buffer.BlockCopy(d, 0, blob, 72, 32);  // D
            return blob;
        }

        public static LetterKey Create()
        {
            var p = new CngKeyCreationParameters { ExportPolicy = CngExportPolicies.AllowPlaintextExport };
            CngKey k = CngKey.Create(CngAlgorithm.ECDiffieHellmanP256, null, p);
            try
            {
                byte[] blob = k.Export(CngKeyBlobFormat.EccPrivateBlob);       // 머리 8 + X 32 + Y 32 + D 32
                if (blob.Length != 104 || BitConverter.ToInt32(blob, 0) != PrivateMagic || BitConverter.ToInt32(blob, 4) != 32)
                    throw new CryptographicException("ECC blob");
                var pub = new byte[65];
                pub[0] = 4;
                Buffer.BlockCopy(blob, 8, pub, 1, 64);
                var d = new byte[32];
                Buffer.BlockCopy(blob, 72, d, 0, 32);
                Array.Clear(blob, 0, blob.Length);
                return new LetterKey(k, pub, d);
            }
            catch { k.Dispose(); throw; }
        }

        /// 비밀 값 D(32바이트, 큰 쪽이 앞)와 그 공개 키로 만든다.
        public static LetterKey FromScalar(byte[] d, byte[] x963)
        {
            if (d == null || d.Length != 32 || !LooksLikePublic(x963)) throw new ArgumentException("key");
            byte[] blob = Blob(PrivateMagic, x963, d);
            CngKey k = CngKey.Import(blob, CngKeyBlobFormat.EccPrivateBlob);
            Array.Clear(blob, 0, blob.Length);
            return new LetterKey(k, (byte[])x963.Clone(), (byte[])d.Clone());
        }

        /// 보관용: D 32 + 공개 키 65
        public byte[] Stored()
        {
            var s = new byte[97];
            Buffer.BlockCopy(scalar, 0, s, 0, 32);
            Buffer.BlockCopy(Public, 0, s, 32, 65);
            return s;
        }

        public static LetterKey FromStored(byte[] s)
        {
            if (s == null || s.Length != 97) throw new ArgumentException("stored key");
            var d = new byte[32];
            var pub = new byte[65];
            Buffer.BlockCopy(s, 0, d, 0, 32);
            Buffer.BlockCopy(s, 32, pub, 0, 65);
            return FromScalar(d, pub);
        }

        /// 상대 공개 키와 맞춘 공유 비밀로 HKDF-Extract 까지 한 값(PRK): HMAC-SHA256(key = 0 서른두 개, 공유 비밀의 X 좌표).
        /// 공유 비밀 자체는 Windows 밖으로 꺼내지 않는다.
        public byte[] Agree(byte[] peerX963)
        {
            if (!LooksLikePublic(peerX963)) throw new ArgumentException("peer");
            using (var ecdh = new ECDiffieHellmanCng(key))
            using (ECDiffieHellmanPublicKey peer = ECDiffieHellmanCngPublicKey.FromByteArray(Blob(PublicMagic, peerX963, null), CngKeyBlobFormat.EccPublicBlob))
            {
                // hmacKey 를 null 로 주면 "공유 비밀을 HMAC 키로 쓰라"는 다른 뜻이 되므로 0 서른두 개를 직접 준다 (HKDF 의 salt 없음과 같다).
                return ecdh.DeriveKeyFromHmac(peer, HashAlgorithmName.SHA256, new byte[32], null, null);
            }
        }

        public void Dispose() { key.Dispose(); }
    }

    static class LetterCrypto
    {
        static readonly byte[] Info = Encoding.UTF8.GetBytes("omogi-letter-v1");
        public const int Overhead = 1 + 65 + AesGcm.NonceSize + AesGcm.TagSize;     // 94
        static readonly object gate = new object();
        static LetterKey cached;
        static string cachedDir;

        /// 이 PC 의 편지 열쇠. 처음 쓸 때 만들어 SecretStore 에 둔다. 만들 수 없으면 null.
        public static LetterKey Identity()
        {
            lock (gate)
            {
                string dir = Config.Dir;
                if (cached != null && cachedDir == dir) return cached;
                cached = null;
                try
                {
                    byte[] d = SecretStore.Load("letter-key");
                    if (d != null)
                    {
                        try { cached = LetterKey.FromStored(d); }
                        catch (Exception e) { Log.Write("편지: 보관한 열쇠를 읽지 못함 (" + e.GetType().Name + ")"); }
                    }
                    if (cached == null)
                    {
                        LetterKey k = LetterKey.Create();
                        if (SecretStore.Exists("letter-key")) SecretStore.SetAside("letter-key");
                        SecretStore.Save("letter-key", k.Stored());
                        Log.Write("편지: 새 열쇠를 만듦");
                        cached = k;
                    }
                    cachedDir = dir;
                }
                catch (Exception e)
                {
                    Log.Write("편지: 열쇠를 만들지 못함 (" + e.GetType().Name + ")");
                    cached = null;
                }
                return cached;
            }
        }

        /// 내 공개 키 (X9.63 65바이트). 서버에는 base64 로 보낸다. 열쇠가 없으면 null.
        public static byte[] PublicKey
        {
            get { LetterKey k = Identity(); return k == null ? null : k.Public; }
        }

        static byte[] Concat(params byte[][] parts)
        {
            var all = new byte[parts.Sum(p => p.Length)];
            int at = 0;
            foreach (byte[] p in parts) { Buffer.BlockCopy(p, 0, all, at, p.Length); at += p.Length; }
            return all;
        }

        /// HKDF 의 뒤쪽 절반: PRK 에서 AES 키 32바이트를 뽑는다.
        internal static byte[] DeriveKey(byte[] prk, byte[] eph, byte[] recipient)
        {
            return Hkdf.Expand(prk, Concat(Info, eph, recipient), 32);
        }

        /// 봉투를 조각으로 나눈다. 모양이 맞지 않으면 false.
        internal static bool Split(byte[] envelope, out byte[] ephPub, out byte[] nonce, out byte[] cipher, out byte[] tag)
        {
            ephPub = nonce = cipher = tag = null;
            if (envelope == null || envelope.Length <= Overhead || envelope[0] != 1) return false;
            ephPub = new byte[65];
            nonce = new byte[AesGcm.NonceSize];
            tag = new byte[AesGcm.TagSize];
            cipher = new byte[envelope.Length - Overhead];
            Buffer.BlockCopy(envelope, 1, ephPub, 0, 65);
            Buffer.BlockCopy(envelope, 66, nonce, 0, nonce.Length);
            Buffer.BlockCopy(envelope, 66 + nonce.Length, cipher, 0, cipher.Length);
            Buffer.BlockCopy(envelope, envelope.Length - tag.Length, tag, 0, tag.Length);
            return ephPub[0] == 4;
        }

        /// 받는 사람의 공개 키로 잠근다. 잠글 수 없으면 null.
        public static byte[] Seal(string text, byte[] recipient)
        {
            if (text == null || !LetterKey.LooksLikePublic(recipient)) return null;
            try
            {
                using (LetterKey eph = LetterKey.Create())
                {
                    byte[] key = DeriveKey(eph.Agree(recipient), eph.Public, recipient);
                    var nonce = new byte[AesGcm.NonceSize];
                    using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(nonce);
                    byte[] tag;
                    byte[] cipher = AesGcm.Encrypt(key, nonce, Encoding.UTF8.GetBytes(text), out tag);
                    Array.Clear(key, 0, key.Length);
                    return Concat(new byte[] { 1 }, eph.Public, nonce, cipher, tag);
                }
            }
            catch (Exception e)
            {
                Log.Write("편지: 잠그지 못함 (" + e.GetType().Name + ")");
                return null;
            }
        }

        /// 내 열쇠로 연다. 열 수 없으면 null.
        public static string Open(byte[] envelope, LetterKey me = null)
        {
            try
            {
                byte[] ephPub, nonce, cipher, tag;
                if (!Split(envelope, out ephPub, out nonce, out cipher, out tag)) return null;
                if (me == null) me = Identity();
                if (me == null) return null;
                byte[] key = DeriveKey(me.Agree(ephPub), ephPub, me.Public);
                byte[] plain = AesGcm.Decrypt(key, nonce, cipher, tag);
                Array.Clear(key, 0, key.Length);
                if (plain == null) return null;
                return new UTF8Encoding(false, true).GetString(plain);     // UTF-8 이 아니면 열지 못한 것으로 친다
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    // ───────────────────── 배달 ─────────────────────
    sealed class Friend
    {
        public string Id;
        public string Name;
        public byte[] PublicKey;       // 서로 친구가 된 뒤에만 있다
        public string Status;          // "practice"(나 자신), "accepted", "pending"
        public bool Incoming;          // 상대가 나에게 보낸 요청
        public string Handle;          // 상대가 정한 아이디 (없을 수 있다)
        /// 목록에 보여 줄 이름: "이름 (@아이디)"
        public string Label { get { return Handle != null ? Name + " (@" + Handle + ")" : Name; } }
    }

    sealed class Arrival
    {
        public string Id;
        public string FromName;
        public byte[] Envelope;
    }

    /// 편지를 나르는 길.
    interface ILetterTransport
    {
        /// 잠근 편지를 맡긴다. 언제 도착할지, 잃어버릴지는 맡은 쪽이 정하고 보낸 쪽에는 알려 주지 않는다. done(편지 ID, null) 또는 done(null, 오류).
        void Send(byte[] envelope, Friend to, string fromName, Action<string, ServerError> done);
        /// 나에게 도착한 편지와, 내가 보낸 것 가운데 잃어버린 편지의 ID 를 가져온다.
        void Fetch(Action<List<Arrival>, List<string>> done);
        /// 저장을 마쳤으니 맡은 쪽에서 지워도 된다고 알린다.
        void Ack(List<string> arrived, List<string> lost);
    }

    /// 연습 배달: 서버 노릇을 이 PC 의 파일 하나가 한다. 보낸 편지가 시간이 지나면 나에게 돌아온다.
    sealed class LoopbackPost : ILetterTransport
    {
        sealed class Item
        {
            public string Id;
            public string FromName;
            public byte[] Envelope;
            public DateTime DeliverAt;
            public bool Lost;
        }

        static readonly Random random = new Random();
        static string FilePath { get { return Path.Combine(Config.Dir, "practice-post.json"); } }

        static List<Item> Load()
        {
            var list = new List<Item>();
            try
            {
                if (!File.Exists(FilePath)) return list;
                foreach (var j in LetterFiles.Rows(Json.ParseAny(File.ReadAllText(FilePath, Encoding.UTF8))))
                {
                    string id = LetterFiles.Text(j, "id");
                    byte[] env = LetterFiles.Base64(LetterFiles.Text(j, "envelope"));
                    DateTime at;
                    if (id == null || env == null || !LetterFiles.ParseDate(LetterFiles.Text(j, "deliverAt"), out at)) continue;
                    list.Add(new Item { Id = id, FromName = LetterFiles.Text(j, "fromName") ?? "나", Envelope = env, DeliverAt = at, Lost = LetterFiles.Flag(j, "lost") });
                }
            }
            catch (Exception e) { Log.Write("편지: practice-post.json 을 읽지 못함 (" + e.GetType().Name + ")"); }
            return list;
        }

        static void Write(List<Item> items)
        {
            LetterFiles.WriteJson(FilePath, items.Select(i => new Dictionary<string, object>
            {
                { "id", i.Id }, { "fromName", i.FromName }, { "envelope", Convert.ToBase64String(i.Envelope) },
                { "deliverAt", LetterFiles.FormatDate(i.DeliverAt) }, { "lost", i.Lost },
            }).ToList());
        }

        public void Send(byte[] envelope, Friend to, string fromName, Action<string, ServerError> done)
        {
            double lo = Math.Min(Config.LetterMinMinutes, Config.LetterMaxMinutes), hi = Math.Max(Config.LetterMinMinutes, Config.LetterMaxMinutes);
            double minutes, roll;
            lock (random) { minutes = lo + random.NextDouble() * (hi - lo); roll = random.NextDouble() * 100; }
            var item = new Item
            {
                Id = Guid.NewGuid().ToString().ToUpperInvariant(), FromName = fromName, Envelope = envelope,
                DeliverAt = DateTime.UtcNow.AddMinutes(minutes), Lost = roll < Config.LetterLossPercent,
            };
            var all = Load();
            all.Add(item);
            Write(all);
            done(item.Id, null);
        }

        public void Fetch(Action<List<Arrival>, List<string>> done)
        {
            DateTime now = DateTime.UtcNow;
            var due = Load().Where(i => i.DeliverAt <= now).ToList();
            done(due.Where(i => !i.Lost).Select(i => new Arrival { Id = i.Id, FromName = i.FromName, Envelope = i.Envelope }).ToList(),
                 due.Where(i => i.Lost).Select(i => i.Id).ToList());
        }

        public void Ack(List<string> arrived, List<string> lost)
        {
            var gone = new HashSet<string>(arrived.Concat(lost));
            if (gone.Count == 0) return;
            Write(Load().Where(i => !gone.Contains(i.Id)).ToList());
        }
    }

    // ───────────────────── 편지함 ─────────────────────
    // 모든 것은 화면 스레드에서 다룬다. 서버 일은 Server 가 다른 스레드에서 하고 결과만 화면 스레드로 돌려준다.
    sealed class LetterBox
    {
        public sealed class Received
        {
            public string Id;
            public string FromName;
            public string Body;
            public DateTime At;        // UTC
            public bool Read;
        }

        public sealed class Sent
        {
            public string Id;
            public string ToId;
            public string ToName;
            public string Body;
            public DateTime At;        // UTC
            public bool Lost;
            public bool LostTold;      // 잃어버렸다고 펫이 알렸는지
        }

        public sealed class ProfileInfo
        {
            public string Code;
            public string Name;
            public string Handle;      // 내가 정한 아이디
        }

        static string FilePath { get { return Path.Combine(Config.Dir, "letters.json"); } }

        readonly List<Received> inbox = new List<Received>();
        readonly List<Sent> sent = new List<Sent>();
        ProfileInfo profile;           // 편지 서버에 등록한 내 이름과 친구 코드
        readonly LoopbackPost practice = new LoopbackPost();
        readonly Server server;
        readonly ServerPost serverPost;
        readonly ICourier pet;
        Timer timer;
        DateTime lastServerPoll = DateTime.MinValue;
        List<Friend> serverFriends = new List<Friend>();      // 친구와 요청 (서버에서 받은 것)

        /// 읽지 않은 편지 수, 친구 목록, 내 정보가 바뀌면 화면 스레드에서 알린다.
        public event Action Changed;
        /// 서버로 새 편지가 왔을 때 (연습 배달은 부르지 않는다). 보낸 사람의 이름을 준다.
        public Action<string> OnNewLetter;

        public IList<Received> Inbox { get { return inbox; } }
        public IList<Sent> SentLetters { get { return sent; } }
        public int UnreadCount { get { return inbox.Count(l => !l.Read); } }
        public ProfileInfo Profile { get { return profile; } }
        public bool ServerAvailable { get { return server != null; } }
        /// 편지 서버를 쓰는 중인지. 사용자가 "친구" 창에서 시작해야 true 가 된다.
        public bool Online { get { return server != null && profile != null; } }
        public IList<Friend> ServerFriends { get { return serverFriends; } }

        /// 편지를 보낼 수 있는 상대: 연습 상대(나 자신)와 서로 친구가 된 사람들.
        public List<Friend> Friends
        {
            get
            {
                var list = new List<Friend> { new Friend { Id = "self", Name = "나에게 (연습)", PublicKey = LetterCrypto.PublicKey, Status = "practice" } };
                list.AddRange(serverFriends.Where(f => f.Status == "accepted" && f.PublicKey != null));
                return list;
            }
        }

        public LetterBox(ICourier pet) : this(pet, Server.Shared) { }

        /// server 가 null 이면 연습 배달만 한다 (자체 점검에서 쓴다).
        internal LetterBox(ICourier pet, Server server)
        {
            this.pet = pet;
            this.server = server;
            serverPost = server == null ? null : new ServerPost(server);
            LoadSaved();
        }

        void LoadSaved()
        {
            try
            {
                if (!File.Exists(FilePath)) return;
                var j = Json.Parse(File.ReadAllText(FilePath, Encoding.UTF8));
                object o;
                DateTime at;
                foreach (var r in LetterFiles.Rows(j.TryGetValue("inbox", out o) ? o : null))
                {
                    string id = LetterFiles.Text(r, "id");
                    if (id == null) continue;
                    if (!LetterFiles.ParseDate(LetterFiles.Text(r, "at"), out at)) at = DateTime.UtcNow;
                    inbox.Add(new Received { Id = id, FromName = LetterFiles.Text(r, "fromName") ?? "친구", Body = LetterFiles.Text(r, "body") ?? "", At = at, Read = LetterFiles.Flag(r, "read") });
                }
                foreach (var r in LetterFiles.Rows(j.TryGetValue("sent", out o) ? o : null))
                {
                    string id = LetterFiles.Text(r, "id");
                    if (id == null) continue;
                    if (!LetterFiles.ParseDate(LetterFiles.Text(r, "at"), out at)) at = DateTime.UtcNow;
                    sent.Add(new Sent
                    {
                        Id = id, ToId = LetterFiles.Text(r, "toID") ?? "", ToName = LetterFiles.Text(r, "toName") ?? "친구", Body = LetterFiles.Text(r, "body") ?? "",
                        At = at, Lost = LetterFiles.Flag(r, "lost"), LostTold = LetterFiles.Flag(r, "lostTold"),
                    });
                }
                var p = j.TryGetValue("profile", out o) ? o as Dictionary<string, object> : null;
                if (p != null && LetterFiles.Text(p, "code") != null)
                    profile = new ProfileInfo { Code = LetterFiles.Text(p, "code"), Name = LetterFiles.Text(p, "name") ?? "", Handle = LetterFiles.Text(p, "handle") };
            }
            catch (Exception e) { Log.Write("편지: letters.json 을 읽지 못함 (" + e.GetType().Name + ")"); }
        }

        void Save()
        {
            var j = new Dictionary<string, object>
            {
                { "inbox", inbox.Select(l => new Dictionary<string, object>
                    { { "id", l.Id }, { "fromName", l.FromName }, { "body", l.Body }, { "at", LetterFiles.FormatDate(l.At) }, { "read", l.Read } }).ToList() },
                { "sent", sent.Select(l => new Dictionary<string, object>
                    { { "id", l.Id }, { "toID", l.ToId }, { "toName", l.ToName }, { "body", l.Body }, { "at", LetterFiles.FormatDate(l.At) },
                      { "lost", l.Lost }, { "lostTold", l.LostTold } }).ToList() },
            };
            if (profile != null)
            {
                var p = new Dictionary<string, object> { { "code", profile.Code }, { "name", profile.Name } };
                if (profile.Handle != null) p["handle"] = profile.Handle;
                j["profile"] = p;
            }
            LetterFiles.WriteJson(FilePath, j);
            RaiseChanged();
        }

        void RaiseChanged()
        {
            Action h = Changed;
            if (h == null) return;
            try { h(); }
            catch (Exception e) { Log.Write("오류: " + e); }
        }

        /// 20초마다 새 편지를 확인하기 시작한다. 화면 스레드에서 부른다.
        public void Start()
        {
            if (timer != null) return;
            timer = new Timer { Interval = 20000 };
            timer.Tick += (s, e) => Poll();
            timer.Start();
            var first = new Timer { Interval = 4000 };
            first.Tick += (s, e) =>
            {
                first.Stop();
                first.Dispose();
                // 이미 서버를 쓰고 있었으면 등록을 한 번 더 확인한다 (로그인 정보가 사라졌어도 여기서 다시 이어진다).
                if (profile != null && server != null) GoOnline(profile.Name, "", _ => { });
                Poll();
            };
            first.Start();
        }

        // ── 서버: 시작·친구 ──
        /// 편지 서버에 내 이름과 편지 공개 키를 등록하고 친구 코드를 받는다. 실패하면 이유를 돌려준다 (잘 됐으면 null).
        public void GoOnline(string name, string handle, Action<string> done)
        {
            if (server == null) { done("이 앱에는 편지 서버가 연결되어 있지 않아요."); return; }
            string clean = (name ?? "").Trim();
            if (LetterRules.Count(clean) > 20) clean = new StringInfo(clean).SubstringByTextElements(0, 20);
            if (clean.Length == 0) { done("이름을 적어 주세요."); return; }
            byte[] pub = LetterCrypto.PublicKey;
            if (pub == null) { done("이 PC 에서 편지 열쇠를 만들지 못했어요."); return; }
            var args = new Dictionary<string, object> { { "p_name", clean }, { "p_public_key", Convert.ToBase64String(pub) } };
            server.Call("omogi_register", args, r =>
            {
                if (!r.Ok) { done(r.Error.Message); return; }
                var j = r.Value as Dictionary<string, object>;
                string code = LetterFiles.Text(j, "code");
                if (code == null) { done("서버의 대답을 읽지 못했어요."); return; }
                if (profile == null || profile.Code != code) Log.Write("편지: 서버에 등록함");
                profile = new ProfileInfo { Code = code, Name = clean, Handle = LetterFiles.Text(j, "handle") };
                Save();
                string wanted = (handle ?? "").Trim();
                if (wanted.Length == 0) RefreshFriends(() => done(null));
                else SetHandle(wanted, problem => RefreshFriends(() => done(problem)));
            });
        }

        /// 아이디를 정하거나 바꾼다. 안 되면 이유를 돌려준다.
        public void SetHandle(string handle, Action<string> done)
        {
            if (!Online) { done("먼저 편지 서버를 시작해 주세요."); return; }
            server.Call("omogi_set_handle", new Dictionary<string, object> { { "p_handle", handle } }, r =>
            {
                if (!r.Ok) { done(r.Error.Message); return; }
                string h = LetterFiles.Text(r.Value as Dictionary<string, object>, "handle");
                if (h == null) { done("서버의 대답을 읽지 못했어요."); return; }
                if (profile != null) profile.Handle = h;
                Save();
                done(null);
            });
        }

        /// 서버의 내 계정(친구 관계, 오가는 중인 편지)을 지우고 서버 쓰기를 그만둔다. 이 PC 에 받은 편지는 남는다.
        public void LeaveServer(Action<string> done)
        {
            if (server == null) { done(null); return; }
            server.Call("omogi_delete_account", null, r =>
            {
                if (!r.Ok) { done(r.Error.Message); return; }
                server.Forget();
                profile = null;
                serverFriends = new List<Friend>();
                Save();
                Log.Write("편지: 서버 계정을 지움");
                done(null);
            });
        }

        public void RefreshFriends(Action done = null)
        {
            if (!Online) { if (done != null) done(); return; }
            server.Call("omogi_list_friends", null, r =>
            {
                if (r.Ok && r.Value != null && !(r.Value is string) && r.Value is IEnumerable && !(r.Value is IDictionary))
                {
                    serverFriends = ParseFriends(r.Value);
                    RaiseChanged();
                }
                if (done != null) done();
            });
        }

        /// omogi_list_friends 의 대답을 읽는다.
        internal static List<Friend> ParseFriends(object value)
        {
            var list = new List<Friend>();
            foreach (var j in LetterFiles.Rows(value))
            {
                string id = LetterFiles.Text(j, "id"), name = LetterFiles.Text(j, "name"), status = LetterFiles.Text(j, "status");
                if (id == null || name == null || status == null) continue;
                byte[] key = LetterFiles.Base64(LetterFiles.Text(j, "public_key"));
                list.Add(new Friend { Id = id, Name = name, PublicKey = key, Status = status, Incoming = LetterFiles.Flag(j, "incoming"), Handle = LetterFiles.Text(j, "handle") });
            }
            return list;
        }

        /// 아이디나 친구 코드로 요청한다. 결과를 한 줄로 돌려준다.
        public void RequestFriend(string code, Action<string> done)
        {
            if (!Online) { done("먼저 편지 서버를 시작해 주세요."); return; }
            server.Call("omogi_request_friend", new Dictionary<string, object> { { "p_code", code } }, r =>
            {
                if (!r.Ok) { done(r.Error.Message); return; }
                var j = r.Value as Dictionary<string, object>;
                string name = LetterFiles.Text(j, "name") ?? "친구";
                bool accepted = LetterFiles.Text(j, "status") == "accepted";
                RefreshFriends(() => done(accepted ? name + "와(과) 친구가 됐어요." : name + "에게 요청을 보냈어요. 수락하면 친구가 돼요."));
            });
        }

        public void Respond(Friend friend, bool accept, Action done)
        {
            if (server == null) return;
            server.Call("omogi_respond_friend", new Dictionary<string, object> { { "p_friend", friend.Id }, { "p_accept", accept } }, _ => RefreshFriends(done));
        }

        public void Remove(Friend friend, bool block, Action done)
        {
            if (server == null) return;
            server.Call("omogi_remove_friend", new Dictionary<string, object> { { "p_friend", friend.Id }, { "p_block", block } }, _ => RefreshFriends(done));
        }

        // ── 보내기·받기 ──
        ILetterTransport TransportFor(string friendId)
        {
            return friendId == "self" ? (ILetterTransport)practice : serverPost;
        }

        /// 편지를 맡긴다. 보낼 수 없으면 이유를, 보냈으면 null 을 돌려준다.
        public void Send(string text, Friend friend, Action<string> done)
        {
            string body = LetterRules.Clean(text);
            if (body.Length == 0) { done("편지가 비어 있어요."); return; }
            if (LetterRules.Count(body) > LetterRules.MaxChars) { done(LetterRules.MaxChars + "자까지만 쓸 수 있어요."); return; }
            DateTime dayAgo = DateTime.UtcNow.AddSeconds(-86400);
            int today = sent.Count(l => l.ToId == friend.Id && l.At > dayAgo);
            if (today >= LetterRules.DailyLimit) { done("한 친구에게는 하루에 " + LetterRules.DailyLimit + "통까지만 보낼 수 있어요."); return; }
            ILetterTransport via = TransportFor(friend.Id);
            byte[] envelope = friend.PublicKey == null || via == null ? null : LetterCrypto.Seal(body, friend.PublicKey);
            if (envelope == null) { done("편지를 잠그지 못했어요."); return; }
            via.Send(envelope, friend, "나", (id, error) =>
            {
                if (error != null) { done(error.Message); return; }
                sent.Insert(0, new Sent { Id = id, ToId = friend.Id, ToName = friend.Name, Body = body, At = DateTime.UtcNow });
                Save();
                Log.Write("편지: 한 통을 맡김 (" + (friend.Id == "self" ? "연습" : "서버") + ")");
                if (pet != null) pet.CarryOut();
                done(null);
            });
        }

        public void MarkAllRead()
        {
            if (UnreadCount == 0) return;
            foreach (Received l in inbox) l.Read = true;
            Save();
        }

        /// 새로 온 것을 가져오고, 펫이 알릴 것이 있으면 알린다. 연습 배달은 매번, 서버는 5분에 한 번 (serverNow 면 바로) 확인한다.
        public void Poll(bool serverNow = false)
        {
            Collect(practice);
            if (Online && serverPost != null && (serverNow || (DateTime.UtcNow - lastServerPoll).TotalSeconds > 300))
            {
                lastServerPoll = DateTime.UtcNow;
                Collect(serverPost);
            }
        }

        void Collect(ILetterTransport via)
        {
            via.Fetch((arrived, lost) =>
            {
                bool changed = false;
                foreach (Arrival a in arrived)
                {
                    if (inbox.Any(l => l.Id == a.Id)) continue;
                    // 열 수 없는 편지(열쇠가 바뀐 경우 등)도 서버에서는 지워야 하므로, 못 읽었다는 말로 남긴다.
                    string body = LetterCrypto.Open(a.Envelope) ?? "(이 편지는 열 수 없었어요.)";
                    inbox.Insert(0, new Received { Id = a.Id, FromName = a.FromName, Body = body, At = DateTime.UtcNow, Read = false });
                    changed = true;
                    if (via is ServerPost && OnNewLetter != null)
                    {
                        try { OnNewLetter(a.FromName); } catch (Exception e) { Log.Write("편지: 도착 알림 오류 " + e.GetType().Name); }
                    }
                }
                foreach (string id in lost)
                {
                    Sent s = sent.FirstOrDefault(l => l.Id == id);
                    if (s != null && !s.Lost) { s.Lost = true; changed = true; }
                }
                if (changed)
                {
                    Log.Write("편지: 도착 " + arrived.Count + "통, 누락 " + lost.Count + "통");
                    Save();
                }
                via.Ack(arrived.Select(a => a.Id).ToList(), lost);      // 저장한 뒤에 지우게 한다
                Present();
            });
        }

        // 펫이 지금 나설 수 없으면 다음 확인 때 다시 시도한다.
        void Present()
        {
            if (pet == null) return;
            Received first = inbox.FirstOrDefault(l => !l.Read);
            if (first != null && !pet.IsHoldingMail)
            {
                int n = UnreadCount;
                pet.BringMail(n > 1 ? "편지 " + n + "통이 왔어요 — 눌러서 열기" : first.FromName + "의 편지가 왔어요 — 눌러서 열기");
                return;
            }
            Sent gone = sent.FirstOrDefault(l => l.Lost && !l.LostTold);
            if (gone != null && !pet.IsHoldingMail && pet.ReportLost(gone.ToName + "에게 가던 편지를 잃어버렸어요…"))
            {
                gone.LostTold = true;
                Save();
            }
        }
    }

    // ───────────────────── 창 ─────────────────────
    /// 세 창의 공통 부분: 크기가 고정된 창, 닫으면 숨기기만 한다. 좌표는 96dpi 기준으로 적고 S()/R() 로 화면 배율에 맞춘다.
    class LetterForm : Form
    {
        protected readonly float K;
        readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();

        protected LetterForm(string title, int width, int height)
        {
            float dpi = 96f;
            try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX; }
            catch { }
            K = dpi / 96f;
            Text = title;
            Font = Face(9f);
            AutoScaleMode = AutoScaleMode.Dpi;          // 기준 크기를 주지 않으므로 자동 배율은 일어나지 않는다. 배율은 S() 로 직접 맞춘다.
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            ClientSize = new Size(S(width), S(height));
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { }
        }

        protected int S(int v) { return (int)Math.Round(v * K); }
        protected Rectangle R(int x, int y, int w, int h) { return new Rectangle(S(x), S(y), S(w), S(h)); }

        protected Font Face(float size, bool bold = false, bool mono = false)
        {
            string k = size + (bold ? "b" : "") + (mono ? "m" : "");
            Font f;
            if (!fonts.TryGetValue(k, out f))
            {
                f = new Font(mono ? "Consolas" : "Malgun Gothic", size, bold ? FontStyle.Bold : FontStyle.Regular);
                fonts[k] = f;
            }
            return f;
        }

        protected Label MakeLabel(string text, Rectangle frame, float size = 9f, bool bold = false, Color? color = null)
        {
            return new Label
            {
                Text = text, Bounds = frame, Font = Face(size, bold), ForeColor = color ?? SystemColors.ControlText,
                UseMnemonic = false, AutoSize = false, BackColor = Color.Transparent,
            };
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
            }
            base.OnFormClosing(e);
        }

        /// 보이게 하고 앞으로 가져온다.
        public void Front()
        {
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
        }

        protected void Warn(string title, string text)
        {
            MessageBox.Show(Visible ? this : null, text, title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        bool snapping;
        protected override bool ShowWithoutActivation { get { return snapping; } }

        /// 창을 그림 파일로 남긴다 (자체 점검에서 쓴다). 숨겨진 창이면 화면 밖에서 잠깐 띄워 그린 뒤 다시 숨긴다
        /// (한 번도 보인 적 없는 창은 안쪽 컨트롤이 아직 만들어지지 않아 빈 그림이 되기 때문이다).
        public void Snapshot(string pngPath)
        {
            bool hidden = !Visible;
            if (hidden)
            {
                snapping = true;
                StartPosition = FormStartPosition.Manual;
                Location = new Point(-32000, -32000);
                Show();
            }
            try
            {
                Update();
                using (var bmp = new Bitmap(Math.Max(1, Width), Math.Max(1, Height)))
                {
                    DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
                    bmp.Save(pngPath, ImageFormat.Png);
                }
            }
            finally
            {
                if (hidden)
                {
                    Hide();
                    snapping = false;
                    CenterToScreen();
                }
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                foreach (Font f in fonts.Values) f.Dispose();
                fonts.Clear();
            }
            base.Dispose(disposing);
        }
    }

    /// 비어 있을 때 흐린 안내 글이 보이는 입력 칸.
    sealed class HintBox : TextBox
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

        string hint = "";
        public string Hint
        {
            get { return hint; }
            set { hint = value ?? ""; Apply(); }
        }

        void Apply()
        {
            if (!IsHandleCreated) return;
            try { SendMessage(Handle, 0x1501 /* EM_SETCUEBANNER */, (IntPtr)1, hint); }
            catch { }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Apply();
        }
    }

    // ── 편지 쓰기 ──
    sealed class ComposeForm : LetterForm
    {
        readonly LetterBox box;
        readonly ComboBox friendPicker = new ComboBox();
        readonly TextBox editor = new TextBox();
        readonly Label counter;
        readonly Button sendButton = new Button();
        List<Friend> composeFriends = new List<Friend>();
        bool sending;
        /// "친구 추가…" 를 눌렀을 때
        public Action AddFriend;

        public ComposeForm(LetterBox box) : base("편지 쓰기", 380, 300)
        {
            this.box = box;
            SuspendLayout();
            Controls.Add(MakeLabel("받는 사람", R(20, 22, 62, 18)));
            friendPicker.DropDownStyle = ComboBoxStyle.DropDownList;
            friendPicker.Bounds = R(84, 18, 176, 24);
            // 친구가 없으면 받는 사람에 연습 상대만 보인다. 여기서 바로 친구를 맺으러 갈 수 있게 한다.
            var add = new Button { Text = "친구 추가…", Bounds = R(264, 16, 100, 28), UseMnemonic = false };
            add.Click += (s, e) => { if (AddFriend != null) AddFriend(); };
            editor.Multiline = true;
            editor.AcceptsReturn = true;
            editor.ScrollBars = ScrollBars.Vertical;
            editor.Font = Face(10.5f);
            editor.Bounds = R(20, 54, 340, 150);
            editor.TextChanged += (s, e) => UpdateCounter();
            counter = MakeLabel("", R(20, 210, 340, 18), 9f, false, SystemColors.GrayText);
            counter.TextAlign = ContentAlignment.MiddleRight;
            var hint = MakeLabel("30분에서 3시간 사이에 도착해요. 가끔은 오모기가 길을 잃기도 해요.", R(20, 236, 190, 52), 8.25f, false, SystemColors.GrayText);
            sendButton.Text = "오모기에게 맡기기";
            sendButton.UseMnemonic = false;
            sendButton.Bounds = R(214, 248, 150, 32);
            sendButton.Click += (s, e) => SendTapped();
            Controls.AddRange(new Control[] { friendPicker, add, editor, counter, hint, sendButton });
            KeyPreview = true;
            ResumeLayout(false);
            Prepare();
        }

        // Ctrl+Enter 로 보낸다.
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.Control && e.KeyCode == Keys.Enter)
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                if (sendButton.Enabled) SendTapped();
                return;
            }
            base.OnKeyDown(e);
        }

        /// 창을 열 때마다: 받는 사람 목록을 처음부터 다시 채운다.
        public void Prepare()
        {
            composeFriends = new List<Friend>();
            ReloadPicker();
            UpdateCounter();
        }

        public void FocusEditor()
        {
            ActiveControl = editor;
            editor.Focus();
        }

        // 친구 목록이 바뀌면(방금 친구가 됐을 때 등) 받는 사람 목록도 고른 것을 지키며 새로 채운다.
        public void ReloadPicker()
        {
            int at = friendPicker.SelectedIndex;
            string chosen = at >= 0 && at < composeFriends.Count ? composeFriends[at].Id : null;
            bool hadFriends = composeFriends.Count > 1;
            composeFriends = box.Friends;
            friendPicker.BeginUpdate();
            friendPicker.Items.Clear();
            foreach (Friend f in composeFriends) friendPicker.Items.Add(f.Label);
            friendPicker.EndUpdate();
            int i = chosen == null ? -1 : composeFriends.FindIndex(f => f.Id == chosen);
            if (i >= 0 && (hadFriends || composeFriends.Count == 1)) friendPicker.SelectedIndex = i;
            else if (composeFriends.Count > 1) friendPicker.SelectedIndex = 1;      // 친구가 생겼으면 연습 상대 대신 첫 친구
            else if (composeFriends.Count > 0) friendPicker.SelectedIndex = 0;
        }

        void UpdateCounter()
        {
            int n = LetterRules.Count(LetterRules.Clean(editor.Text));
            counter.Text = n + " / " + LetterRules.MaxChars;
            counter.ForeColor = n > LetterRules.MaxChars ? Color.Firebrick : SystemColors.GrayText;
            sendButton.Enabled = !sending && n > 0 && n <= LetterRules.MaxChars;
        }

        void SendTapped()
        {
            int i = friendPicker.SelectedIndex;
            if (sending || i < 0 || i >= composeFriends.Count) return;
            sending = true;
            sendButton.Enabled = false;
            box.Send(editor.Text, composeFriends[i], problem =>
            {
                sending = false;
                if (problem != null)
                {
                    UpdateCounter();
                    Warn("편지를 보내지 못했어요", problem);
                    return;
                }
                editor.Text = "";
                UpdateCounter();
                Hide();
            });
        }
    }

    // ── 편지함 ──
    sealed class InboxForm : LetterForm
    {
        const int MaxShown = 300;      // 화면에 그리는 편지 수 (파일에는 모두 남아 있다)
        readonly LetterBox box;
        readonly RadioButton tabInbox = new RadioButton(), tabSent = new RadioButton();
        readonly Panel list = new Panel();
        static readonly CultureInfo korean = CultureInfo.GetCultureInfo("ko-KR");

        public InboxForm(LetterBox box) : base("편지함", 420, 480)
        {
            this.box = box;
            SuspendLayout();
            SetUpTab(tabInbox, "받은 편지", 110);
            SetUpTab(tabSent, "보낸 편지", 210);
            tabInbox.Checked = true;
            list.Bounds = R(0, 46, 420, 434);
            list.AutoScroll = true;
            list.BackColor = SystemColors.Window;
            Controls.AddRange(new Control[] { tabInbox, tabSent, list });
            ResumeLayout(false);
            RenderList();
        }

        void SetUpTab(RadioButton b, string text, int x)
        {
            b.Appearance = Appearance.Button;
            b.Text = text;
            b.UseMnemonic = false;
            b.TextAlign = ContentAlignment.MiddleCenter;
            b.Bounds = R(x, 10, 100, 27);
            b.CheckedChanged += (s, e) => { if (b.Checked) RenderList(); };
        }

        public void SelectInboxTab() { tabInbox.Checked = true; }

        string Stamp(DateTime utc)
        {
            return utc.ToLocalTime().ToString("M'월' d'일' tt h:mm", korean);
        }

        public void RenderList()
        {
            list.SuspendLayout();
            list.AutoScrollPosition = new Point(0, 0);
            var old = list.Controls.Cast<Control>().ToList();
            list.Controls.Clear();
            foreach (Control c in old) c.Dispose();

            int width = S(420) - SystemInformation.VerticalScrollBarWidth - S(32), y = S(14);
            Action<string, string, string> add = (title, mark, text) =>
            {
                var head = new Label { Text = title, Font = Face(9f, true), ForeColor = SystemColors.GrayText, AutoSize = true, UseMnemonic = false, Location = new Point(S(16), y) };
                list.Controls.Add(head);
                Size hs = head.GetPreferredSize(Size.Empty);
                if (mark != null)
                    list.Controls.Add(new Label { Text = mark, Font = Face(9f, true), ForeColor = Color.Firebrick, AutoSize = true, UseMnemonic = false, Location = new Point(S(16) + hs.Width + S(8), y) });
                y += hs.Height + S(3);
                if (!string.IsNullOrEmpty(text))
                {
                    var body = new Label
                    {
                        Text = text.Replace("\r\n", "\n"), Font = Face(10.5f), ForeColor = SystemColors.WindowText, AutoSize = true, UseMnemonic = false,
                        MaximumSize = new Size(width, 0), Location = new Point(S(16), y),
                    };
                    var menu = new ContextMenuStrip();
                    menu.Items.Add("복사", null, (s, e) => { try { Clipboard.SetText(text.Replace("\r\n", "\n").Replace("\n", "\r\n")); } catch { } });
                    body.ContextMenuStrip = menu;
                    body.Disposed += (s, e) => menu.Dispose();
                    list.Controls.Add(body);
                    y += body.GetPreferredSize(new Size(width, 0)).Height;
                }
                y += S(18);
            };

            if (tabInbox.Checked)
            {
                foreach (var l in box.Inbox.Take(MaxShown)) add(l.FromName + " · " + Stamp(l.At), l.Read ? null : "새 편지", l.Body);
                if (box.Inbox.Count == 0) add("아직 받은 편지가 없어요", null, "메뉴의 ‘편지 쓰기’에서 나에게 연습 편지를 보내 보세요.");
            }
            else
            {
                foreach (var l in box.SentLetters.Take(MaxShown)) add(l.ToName + " · " + Stamp(l.At), l.Lost ? "잃어버림" : null, l.Body);
                if (box.SentLetters.Count == 0) add("아직 보낸 편지가 없어요", null, "");
            }
            // 맨 아래에 여백을 둔다.
            list.Controls.Add(new Label { AutoSize = false, Bounds = new Rectangle(0, y, 1, 1) });
            list.ResumeLayout(true);
        }
    }

    // ── 친구 ──
    sealed class FriendsForm : LetterForm
    {
        const int W = 400, BaseHeight = 460;
        readonly LetterBox box;
        readonly HintBox nameField = new HintBox(), codeField = new HintBox(), handleField = new HintBox();
        string note = "";
        List<Friend> rowFriends = new List<Friend>();
        bool busy;

        public FriendsForm(LetterBox box) : base("친구", W, BaseHeight)
        {
            this.box = box;
            nameField.MaxLength = 40;
            codeField.MaxLength = 40;
            handleField.MaxLength = 40;
            RenderFriends();
        }

        public void ClearNote() { note = ""; }

        Label AddLabel(string text, int x, int y, int w, int h, float size = 9.75f, bool bold = false, Color? color = null)
        {
            Label l = MakeLabel(text, R(x, y, w, h), size, bold, color);
            Controls.Add(l);
            return l;
        }

        Button AddButton(string text, int x, int y, int w, int h, Action action)
        {
            var b = new Button { Text = text, Bounds = R(x, y, w, h), Font = Face(8.25f), UseMnemonic = false };
            b.Click += (s, e) => action();
            Controls.Add(b);
            return b;
        }

        void AddField(HintBox field, string hint, int x, int y, int w, bool mono)
        {
            field.Font = mono ? Face(9.75f, false, true) : Face(9.75f);
            field.Bounds = R(x, y, w, 24);
            field.Hint = hint;
            Controls.Add(field);
        }

        bool IsField(Control c) { return c == nameField || c == codeField || c == handleField; }

        // 창의 내용을 지금 상태에 맞게 새로 그린다 (서버 없음 / 시작 전 / 사용 중).
        public void RenderFriends()
        {
            // 글을 쓰던 중이면 지우지 않는다.
            foreach (HintBox f in new[] { nameField, codeField, handleField })
                if (f.Parent != null && f.Focused && f.Text.Length > 0) return;

            SuspendLayout();
            var old = Controls.Cast<Control>().ToList();
            Controls.Clear();
            foreach (Control c in old) if (!IsField(c)) c.Dispose();

            Color gray = SystemColors.GrayText;
            // 친구가 많으면 창을 그만큼 키운다 (네 명까지는 기본 높이).
            rowFriends = box.Profile == null ? new List<Friend>()
                : box.ServerFriends.OrderBy(f => f.Incoming ? 0 : f.Status == "accepted" ? 1 : 2).Take(12).ToList();
            int height = BaseHeight + Math.Max(0, rowFriends.Count - 4) * 44;
            var size = new Size(S(W), S(height));
            if (ClientSize != size) ClientSize = size;       // 왼쪽 위 자리는 그대로다

            try
            {
                if (!box.ServerAvailable)
                {
                    AddLabel("아직 편지 서버가 연결되지 않았어요", 24, 36, W - 48, 24, 11.25f, true);
                    AddLabel("지금은 ‘편지 쓰기’에서 나에게 보내는 연습 편지만 쓸 수 있어요. 서버가 준비되면 이 창에서 친구 코드를 주고받아 친구를 맺게 됩니다.",
                             24, 70, W - 48, 76, 9.75f, false, gray);
                    return;
                }

                LetterBox.ProfileInfo me = box.Profile;
                if (me == null)
                {
                    AddLabel("친구와 편지 주고받기", 24, 30, W - 48, 24, 11.25f, true);
                    AddLabel("시작하면 아래 이름과 편지를 잠그는 공개 키가 편지 서버에 저장되고, 친구 코드가 만들어져요. 이메일이나 비밀번호는 필요 없어요.\n\n편지 내용은 받는 친구만 열 수 있게 잠가서 보내므로 서버에서는 읽을 수 없어요. 언제든 이 창에서 서버의 내 정보를 지울 수 있어요.",
                             24, 62, W - 48, 160, 9.75f, false, gray);
                    AddLabel("친구에게 보일 이름", 24, 232, 200, 18, 9f);
                    AddField(nameField, "20자까지", 24, 254, 220, false);
                    AddLabel("아이디 — 친구가 나를 찾을 때 씁니다 (안 정해도 돼요)", 24, 292, W - 48, 18, 9f);
                    AddField(handleField, "영문 소문자·숫자·_ 3~16자", 24, 314, 220, true);
                    Button go = AddButton("시작하기", 252, 311, 100, 30, StartTapped);
                    go.Font = Face(9.75f);
                    go.Enabled = !busy;
                    if (note.Length > 0) AddLabel(note, 24, 352, W - 48, 40, 9f, false, Color.Firebrick);
                    return;
                }

                // 내 아이디가 있으면 아이디를 크게, 없으면 친구 코드를 크게 보여 준다.
                string big = me.Handle != null ? "@" + me.Handle : me.Code;
                AddLabel(me.Handle == null ? me.Name + "의 친구 코드" : me.Name + "의 아이디   ·   친구 코드 " + me.Code, 24, 24, 352, 18, 9f, false, gray);
                var code = new TextBox       // 골라서 복사할 수 있게 읽기 전용 입력 칸으로 둔다
                {
                    Text = big, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = BackColor, TabStop = false,
                    Font = Face(big.Length > 12 ? 14f : 18f, true, true), Bounds = R(24, 46, 260, 32),
                };
                Controls.Add(code);
                AddButton("복사", 290, 48, 86, 26, CopyCode);
                int y = 92;

                AddField(handleField, me.Handle == null ? "아이디 정하기 (영문 소문자·숫자·_)" : "새 아이디로 바꾸기", 24, y, 220, true);
                AddButton(me.Handle == null ? "아이디 정하기" : "아이디 바꾸기", 252, y - 1, 110, 26, HandleTapped);
                y += 38;

                AddLabel("친구의 아이디나 코드를 받았다면", 24, y + 2, 300, 18, 9f, false, gray);
                AddField(codeField, "아이디 또는 8자 코드", 24, y + 26, 220, true);
                AddButton("친구 요청", 252, y + 25, 86, 26, RequestTapped);
                y += 60;
                if (note.Length > 0)
                {
                    AddLabel(note, 24, y + 2, W - 48, 18, 9f, false, gray).AutoEllipsis = true;
                    y += 24;
                }

                Controls.Add(new Label { AutoSize = false, Bounds = new Rectangle(S(24), S(y + 7), S(W - 48), 1), BackColor = SystemColors.ControlDark });
                y += 16;

                if (rowFriends.Count == 0)
                    AddLabel("아직 친구가 없어요. 위의 코드를 친구에게 보내거나, 친구의 코드를 입력해 보세요.", 24, y + 8, W - 48, 40, 9f, false, gray);
                for (int i = 0; i < rowFriends.Count; i++)
                {
                    Friend f = rowFriends[i];
                    string state = f.Incoming ? "친구 요청이 왔어요" : f.Status == "accepted" ? "친구" : "수락을 기다리는 중";
                    AddLabel(f.Label, 24, y + 5, f.Incoming ? 176 : 230, 19, 9.75f, true).AutoEllipsis = true;
                    AddLabel(state, 24, y + 25, 170, 16, 8.25f, false, gray);
                    if (f.Incoming)
                    {
                        AddButton("수락", 204, y + 11, 52, 25, () => AcceptTapped(f));
                        AddButton("거절", 260, y + 11, 52, 25, () => DeclineTapped(f));
                        AddButton("차단", 316, y + 11, 52, 25, () => BlockTapped(f));
                    }
                    else
                    {
                        AddButton(f.Status == "accepted" ? "끊기" : "취소", 260, y + 11, 52, 25, () => RemoveTapped(f));
                        if (f.Status == "accepted") AddButton("차단", 316, y + 11, 52, 25, () => BlockTapped(f));
                    }
                    y += 44;
                }
                AddButton("서버에서 내 정보 지우기…", 20, height - 38, 180, 25, LeaveTapped);
            }
            finally
            {
                ResumeLayout(true);
            }
        }

        // 누른 단추가 그 자리에서 사라지지 않게, 누름 처리가 끝난 뒤에 다시 그린다.
        void RedrawFriends(string text)
        {
            if (IsHandleCreated && !IsDisposed) BeginInvoke((Action)(() => RedrawNow(text)));
            else RedrawNow(text);
        }

        void RedrawNow(string text)
        {
            if (IsDisposed) return;
            note = text ?? "";
            nameField.Text = "";
            codeField.Text = "";
            handleField.Text = "";
            ActiveControl = null;
            RenderFriends();
        }

        void StartTapped()
        {
            if (busy) return;
            string name = nameField.Text, handle = handleField.Text;
            busy = true;
            box.GoOnline(name, handle, problem =>
            {
                busy = false;
                if (problem == null) box.Poll(true);
                RedrawFriends(problem ?? "");
            });
        }

        void CopyCode()
        {
            LetterBox.ProfileInfo me = box.Profile;
            if (me == null) return;
            try { Clipboard.SetText(me.Handle != null ? "@" + me.Handle : me.Code); }
            catch { RedrawFriends("복사하지 못했어요. 다시 눌러 주세요."); return; }
            RedrawFriends("복사했어요. 친구에게 보내 주세요.");
        }

        void HandleTapped()
        {
            string wanted = handleField.Text.Trim();
            if (wanted.Length == 0) return;
            box.SetHandle(wanted, problem => RedrawFriends(problem ?? "아이디를 정했어요."));
        }

        void RequestTapped()
        {
            string code = codeField.Text.Trim();
            if (code.Length == 0) return;
            box.RequestFriend(code, RedrawFriends);
        }

        void AcceptTapped(Friend f) { box.Respond(f, true, () => RedrawFriends(f.Name + "와(과) 친구가 됐어요.")); }
        void DeclineTapped(Friend f) { box.Respond(f, false, () => RedrawFriends("")); }
        void RemoveTapped(Friend f) { box.Remove(f, false, () => RedrawFriends("")); }

        bool Confirm(string title, string text)
        {
            return MessageBox.Show(this, text, title, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.OK;
        }

        void BlockTapped(Friend f)
        {
            if (!Confirm(f.Name + "을(를) 차단할까요?", "서로 편지를 보낼 수 없게 되고, 이 사람은 다시 친구 요청을 할 수 없어요. 오는 중이던 편지도 사라져요.")) return;
            box.Remove(f, true, () => RedrawFriends(""));
        }

        void LeaveTapped()
        {
            if (!Confirm("서버에서 내 정보를 지울까요?", "친구 관계와 오가는 중인 편지가 모두 사라지고, 친구 코드도 없어져요. 이 PC 에 이미 받은 편지는 남아요. 되돌릴 수 없어요.")) return;
            box.LeaveServer(problem => RedrawFriends(problem ?? ""));
        }
    }

    sealed class LetterWindows
    {
        readonly LetterBox box;
        ComposeForm compose;
        InboxForm inbox;
        FriendsForm friends;
        bool quiet;        // 편지함을 열면서 읽음으로 바꾸는 동안은 다시 그리지 않는다

        public LetterWindows(LetterBox box)
        {
            this.box = box;
            box.Changed += () =>
            {
                if (inbox != null && inbox.Visible && !quiet) inbox.RenderList();
                if (friends != null && friends.Visible) friends.RenderFriends();
                if (compose != null && compose.Visible) compose.ReloadPicker();
            };
        }

        static bool Alive(Form f) { return f != null && !f.IsDisposed; }

        /// 창을 (보이지 않게) 만들어 돌려준다. 그림으로 남길 때 쓴다.
        public ComposeForm ComposeForm
        {
            get
            {
                if (!Alive(compose)) { compose = new ComposeForm(box); compose.AddFriend = ShowFriends; }
                return compose;
            }
        }

        public InboxForm InboxForm
        {
            get
            {
                if (!Alive(inbox)) inbox = new InboxForm(box);
                return inbox;
            }
        }

        public FriendsForm FriendsForm
        {
            get
            {
                if (!Alive(friends)) friends = new FriendsForm(box);
                return friends;
            }
        }

        public void ShowCompose()
        {
            ComposeForm w = ComposeForm;
            w.Prepare();
            w.Front();
            w.FocusEditor();
            box.RefreshFriends();
        }

        public void ShowInbox()
        {
            InboxForm w = InboxForm;
            if (box.UnreadCount > 0) w.SelectInboxTab();
            w.RenderList();
            w.Front();
            quiet = true;
            try { box.MarkAllRead(); }       // 새 편지 표시는 이번에 그린 화면에만 남는다
            finally { quiet = false; }
            box.Poll(true);
        }

        public void ShowFriends()
        {
            FriendsForm w = FriendsForm;
            w.ClearNote();
            w.RenderFriends();
            w.Front();
            box.RefreshFriends();
        }
    }

    // ───────────────────── 자체 점검 ─────────────────────
    /// 네트워크 없이 할 수 있는 확인. 잠그기·열기는 Windows 에서만 돌아간다 (CNG).
    static class LetterSelfTest
    {
        // Mac 에서 CryptoKit 으로 만든 값 (letters.swift 의 LetterCrypto.seal 과 똑같은 절차).
        const string MacPrivateD = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020101";
        const string MacPublic = "0497cecc7f5f1a64d5c47303a6b22504d9e28628cf61b22d0a7fe60f4d5a394173f38523b3938248324cbcdfce9bc60f795107dac28142a89a95269833b67d546f";
        const string MacPlain = "안녕, 오모기! 편지가 잘 도착했니? 🐦";
        const string MacEnvelope = "AQQj5YKsRb2ci1/QIDmjFmdsLNiRIH7jQQPLXXFcPwjCZDYF34voIuKxE7Y7W7uGJEbkmj2TIU3PYlN/N1/xuJxkN+ilM/r1+q99L/GfMP0Rvo7SUSaEm3n0k4EZY8PhzVKOvtOP/wRWOexpCL7Oo+0l0Dr5io5SQarZbgX1QhyStzJbHRwbdX6WeMmpaYrKXw==";
        const string MacSharedX = "18dac00641ac236b8c14f2666e70b5434353826bf9bc483f638f68bf50ad104a";     // 위 봉투의 ECDH 공유 비밀 (X 좌표)
        const string MacAesKey = "47b12ca36f43b2c84fe2c9be251edba49a33489b8fae9bae477e79cc9bb0b8f2";      // 위 봉투의 AES 키

        internal static byte[] Hex(string s)
        {
            var b = new byte[s.Length / 2];
            for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(s.Substring(i * 2, 2), 16);
            return b;
        }

        static bool Same(byte[] a, byte[] b)
        {
            return a != null && b != null && a.SequenceEqual(b);
        }

        sealed class FakeCourier : ICourier
        {
            public int Carried, Brought, Lost;
            public string LastText;
            public bool CarryOut() { Carried++; return true; }
            public bool BringMail(string text) { Brought++; LastText = text; return true; }
            public bool ReportLost(string text) { Lost++; LastText = text; return true; }
            public bool IsHoldingMail { get { return false; } }
        }

        public static void Run(Action<string, bool> check)
        {
            Action<string, Func<bool>> test = (name, body) =>
            {
                bool ok;
                try { ok = body(); }
                catch (Exception e) { ok = false; name += " [" + e.GetType().Name + ": " + e.Message + "]"; }
                check(name, ok);
            };

            // (3) HKDF — RFC 5869 Test Case 1
            test("편지: HKDF-SHA256 (RFC 5869 시험 1)", () =>
            {
                byte[] prk = Hkdf.Extract(Hex("000102030405060708090a0b0c"), Hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"));
                byte[] okm = Hkdf.Expand(prk, Hex("f0f1f2f3f4f5f6f7f8f9"), 42);
                return Same(prk, Hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"))
                    && Same(okm, Hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"));
            });

            // Mac 이 만든 봉투의 공유 비밀에서 같은 AES 키가 나오는지 (ECDH 를 빼고 키 만드는 절차만)
            test("편지: Mac 과 같은 키 만들기 (HKDF info)", () =>
            {
                byte[] env = Convert.FromBase64String(MacEnvelope), eph, nonce, cipher, tag;
                if (!LetterCrypto.Split(env, out eph, out nonce, out cipher, out tag)) return false;
                byte[] key = LetterCrypto.DeriveKey(Hkdf.Extract(null, Hex(MacSharedX)), eph, Hex(MacPublic));
                return Same(key, Hex(MacAesKey)) && nonce.Length == 12 && tag.Length == 16 && cipher.Length == Encoding.UTF8.GetByteCount(MacPlain);
            });

            // (4) AES-256-GCM — GCM 명세(McGrew·Viega) Test Case 14: 키·nonce·평문이 모두 0
            test("편지: AES-256-GCM 표준 벡터", () =>
            {
                byte[] tag;
                byte[] c = AesGcm.Encrypt(new byte[32], new byte[12], new byte[16], out tag);
                if (!Same(c, Hex("cea7403d4d606b6e074ec5d3baf39d18")) || !Same(tag, Hex("d0d1c8a799996bf0265b98b5d48ab919"))) return false;
                if (!Same(AesGcm.Decrypt(new byte[32], new byte[12], c, tag), new byte[16])) return false;
                tag[0] ^= 1;
                return AesGcm.Decrypt(new byte[32], new byte[12], c, tag) == null;
            });

            // (2) Mac 에서 잠근 봉투를 연다
            test("편지: Mac 에서 잠근 편지 열기", () =>
            {
                using (LetterKey me = LetterKey.FromScalar(Hex(MacPrivateD), Hex(MacPublic)))
                    return LetterCrypto.Open(Convert.FromBase64String(MacEnvelope), me) == MacPlain;
            });

            // Mac 의 공개 키로 잠근 것을 Mac 의 열쇠로 다시 연다 (Mac 으로 보내는 방향)
            test("편지: Mac 공개 키로 잠그고 열기", () =>
            {
                using (LetterKey mac = LetterKey.FromScalar(Hex(MacPrivateD), Hex(MacPublic)))
                {
                    byte[] env = LetterCrypto.Seal(MacPlain, mac.Public);
                    return env != null && LetterCrypto.Open(env, mac) == MacPlain;
                }
            });

            // (1) 잠그고 열기, 다른 열쇠, 바뀐 편지, 봉투 길이
            const string sample = "오모기야, 이 편지를 잘 전해 줘.\n둘째 줄";
            byte[] sealedEnvelope = null;
            test("편지: 잠그고 열기", () =>
            {
                using (LetterKey a = LetterKey.Create())
                {
                    sealedEnvelope = LetterCrypto.Seal(sample, a.Public);
                    return sealedEnvelope != null && LetterCrypto.Open(sealedEnvelope, a) == sample;
                }
            });
            test("편지: 봉투 길이 = 94 + 본문 바이트", () =>
                sealedEnvelope != null && sealedEnvelope.Length == LetterCrypto.Overhead + Encoding.UTF8.GetByteCount(sample)
                && sealedEnvelope[0] == 1 && sealedEnvelope[1] == 4);
            check("편지: C# 으로 잠근 봉투 길이 " + (sealedEnvelope == null ? "(잠그지 못함)" : sealedEnvelope.Length + "바이트, base64 " + Convert.ToBase64String(sealedEnvelope).Length + "자"),
                  sealedEnvelope != null);
            test("편지: 다른 열쇠로는 열리지 않음", () =>
            {
                using (LetterKey a = LetterKey.Create())
                using (LetterKey b = LetterKey.Create())
                {
                    byte[] env = LetterCrypto.Seal(sample, a.Public);
                    return env != null && LetterCrypto.Open(env, b) == null;
                }
            });
            test("편지: 바뀐 편지는 열리지 않음", () =>
            {
                using (LetterKey a = LetterKey.Create())
                {
                    byte[] env = LetterCrypto.Seal(sample, a.Public);
                    if (env == null) return false;
                    foreach (int at in new[] { 70, 80, env.Length - 1 })       // nonce, 암호문, tag
                    {
                        var bad = (byte[])env.Clone();
                        bad[at] ^= 0x20;
                        if (LetterCrypto.Open(bad, a) != null) return false;
                    }
                    var cut = new byte[env.Length - 1];
                    Buffer.BlockCopy(env, 0, cut, 0, cut.Length);
                    var version = (byte[])env.Clone();
                    version[0] = 2;
                    return LetterCrypto.Open(cut, a) == null && LetterCrypto.Open(version, a) == null && LetterCrypto.Open(new byte[10], a) == null;
                }
            });
            test("편지: 열쇠를 보관했다가 다시 읽기", () =>
            {
                using (LetterKey a = LetterKey.Create())
                using (LetterKey again = LetterKey.FromStored(a.Stored()))
                {
                    byte[] env = LetterCrypto.Seal(sample, a.Public);
                    return Same(a.Public, again.Public) && LetterCrypto.Open(env, again) == sample;
                }
            });

            // 서버 대답 읽기 (네트워크 없이 모양만)
            test("편지: 서버 대답 읽기", () =>
            {
                var friends = LetterBox.ParseFriends(Json.ParseAny(
                    "[{\"id\":\"a\",\"name\":\"가\",\"handle\":null,\"status\":\"pending\",\"incoming\":true,\"public_key\":null}," +
                    "{\"id\":\"b\",\"name\":\"나\",\"handle\":\"na_1\",\"status\":\"accepted\",\"incoming\":false,\"public_key\":\"" + Convert.ToBase64String(Hex(MacPublic)) + "\"}]"));
                List<Arrival> arrived;
                List<string> lost;
                ServerPost.ParseMail(Json.ParseAny("{\"arrived\":[{\"id\":\"x\",\"from\":\"b\",\"from_name\":\"나\",\"envelope\":\"" + MacEnvelope + "\"}],\"lost\":[\"y\",\"z\"]}"),
                                     out arrived, out lost);
                return friends.Count == 2 && friends[0].Incoming && friends[0].PublicKey == null && friends[0].Handle == null
                    && friends[1].Label == "나 (@na_1)" && Same(friends[1].PublicKey, Hex(MacPublic))
                    && arrived.Count == 1 && arrived[0].FromName == "나" && arrived[0].Envelope.Length == 145 && lost.Count == 2
                    && new ServerError("omogi:daily_limit").Message.Contains("5통")
                    && Server.FromManifest("{\"url\":\"http://x.example\",\"key\":\"k\"}") == null
                    && Server.FromManifest("{\"url\":\"https://x.example\",\"key\":\"sb_secret_1\"}") == null;
            });

            // (5) 연습 배달: 임시 폴더에서 보내고, 바로 도착하게 해서 받아 본다
            string realDir = Config.Dir;
            double realMin = Config.LetterMinMinutes, realMax = Config.LetterMaxMinutes, realLoss = Config.LetterLossPercent;
            string temp = Path.Combine(Path.GetTempPath(), "omogi-letters-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                Config.Dir = temp;
                Config.LetterMinMinutes = 0;
                Config.LetterMaxMinutes = 0;
                Config.LetterLossPercent = 0;

                test("편지: 연습 배달 파일 (맡기기 → 도착 → 지우기)", () =>
                {
                    var post = new LoopbackPost();
                    string id = null;
                    post.Send(new byte[] { 1, 2, 3 }, null, "나", (i, e) => id = i);
                    List<Arrival> got = null;
                    post.Fetch((a, l) => got = a);
                    if (id == null || got == null || got.Count != 1 || got[0].Id != id || !Same(got[0].Envelope, new byte[] { 1, 2, 3 })) return false;
                    post.Ack(new List<string> { id }, new List<string>());
                    post.Fetch((a, l) => got = a);
                    return got.Count == 0;
                });

                test("편지: 나에게 보낸 연습 편지가 편지함에 도착", () =>
                {
                    var pet = new FakeCourier();
                    var box = new LetterBox(pet, null);
                    int changes = 0;
                    box.Changed += () => changes++;
                    Friend self = box.Friends[0];
                    string problem = "(대답 없음)";
                    box.Send("  " + sample + "\r\n", self, p => problem = p);
                    if (problem != null || pet.Carried != 1 || box.SentLetters.Count != 1 || box.UnreadCount != 0) return false;
                    box.Poll();
                    if (box.UnreadCount != 1 || box.Inbox[0].Body != sample || pet.Brought != 1 || changes < 2) return false;
                    var reopened = new LetterBox(null, null);              // 파일에서 다시 읽어도 그대로인지
                    if (reopened.UnreadCount != 1 || reopened.Inbox[0].Body != sample || reopened.SentLetters[0].ToId != "self") return false;
                    box.MarkAllRead();
                    string tooLong = "(대답 없음)", empty = "(대답 없음)";
                    box.Send(new string('가', LetterRules.MaxChars + 1), self, p => tooLong = p);
                    box.Send(" \r\n ", self, p => empty = p);
                    return box.UnreadCount == 0 && tooLong != null && empty != null && box.SentLetters.Count == 1;
                });

                test("편지: 잃어버린 연습 편지를 알림", () =>
                {
                    Config.LetterLossPercent = 100;
                    var pet = new FakeCourier();
                    var box = new LetterBox(pet, null);
                    box.MarkAllRead();
                    string problem = "(대답 없음)";
                    box.Send(sample, box.Friends[0], p => problem = p);
                    box.Poll();
                    return problem == null && box.SentLetters[0].Lost && box.SentLetters[0].LostTold && pet.Lost == 1 && box.UnreadCount == 0;
                });

                test("편지: 하루 " + LetterRules.DailyLimit + "통 제한", () =>
                {
                    Config.LetterLossPercent = 0;
                    var box = new LetterBox(null, null);
                    string last = null;
                    for (int i = box.SentLetters.Count; i < LetterRules.DailyLimit + 1; i++) box.Send(sample, box.Friends[0], p => last = p);
                    return last != null && box.SentLetters.Count == LetterRules.DailyLimit;
                });
            }
            finally
            {
                Config.Dir = realDir;
                Config.LetterMinMinutes = realMin;
                Config.LetterMaxMinutes = realMax;
                Config.LetterLossPercent = realLoss;
                try { Directory.Delete(temp, true); }
                catch { }
            }
        }
    }
}
