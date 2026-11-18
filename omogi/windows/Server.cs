// 편지 서버(Supabase)와 말하는 부분. SDK 없이 HTTPS 요청만 쓴다. Mac 판(omogi/server.swift)과 같은 서버, 같은 규칙이다.
// 서버 주소와 공개용 키는 실행 파일에 넣은 server.json 에서 읽는다 (Config.Dir 에 server.json 이 있으면 그쪽이 먼저다).
// 없으면 서버 기능은 꺼진다.
//   {"url": "https://xxxx.supabase.co", "key": "sb_publishable_..."}
// 이 키는 앱에 넣어 배포하라고 만든 공개용 키다. 관리용 비밀 키(sb_secret_...)는 절대 넣지 말 것.
// 로그인은 가입 절차 없는 익명 로그인이고, 받은 로그인 정보는 SecretStore(Letters.cs)에 둔다. 서버 쪽 규칙은 omogi/server/schema.sql.

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;

namespace Omogi
{
    sealed class ServerError
    {
        public readonly string Code;
        public ServerError(string code) { Code = code; }

        /// 사용자에게 보여 줄 말
        public string Message
        {
            get
            {
                switch (Code)
                {
                    case "omogi:no_such_code": return "그 아이디나 코드를 찾지 못했어요.";
                    case "omogi:bad_handle": return "아이디는 영문 소문자, 숫자, 밑줄(_)로 3~16자여야 해요.";
                    case "omogi:handle_taken": return "이미 다른 사람이 쓰는 아이디예요.";
                    case "omogi:too_many_requests": return "보낸 친구 요청이 너무 많아요. 수락을 기다려 주세요.";
                    case "omogi:not_friends": return "아직 친구가 아니에요.";
                    case "omogi:daily_limit": return "한 친구에게는 하루에 " + LetterRules.DailyLimit + "통까지만 보낼 수 있어요.";
                    case "omogi:bad_envelope": return "편지가 너무 길어요.";
                    case "omogi:not_registered":
                    case "omogi:not_signed_in": return "편지 서버에 다시 연결해야 해요.";
                    case "offline": return "서버에 닿지 못했어요. 인터넷 연결을 확인해 주세요.";
                    case "anonymous_disabled": return "서버에서 익명 로그인이 꺼져 있어요.";
                    default: return "서버에서 문제가 생겼어요. (" + Code + ")";
                }
            }
        }
    }

    /// 서버 함수 하나를 부른 결과. Error 가 null 이면 성공이고 Value 는 서버가 준 JSON (없을 수 있다).
    sealed class ServerReply
    {
        public readonly ServerError Error;
        public readonly object Value;
        public ServerReply(ServerError error, object value) { Error = error; Value = value; }
        public bool Ok { get { return Error == null; } }
    }

    /// 맡긴 일을 한 번에 하나씩, 맡긴 순서대로 다른 스레드에서 한다 (새로 고침 토큰은 한 번만 쓸 수 있다).
    sealed class SerialWorker
    {
        readonly Queue<Action> jobs = new Queue<Action>();
        readonly string name;
        bool running;

        public SerialWorker(string name) { this.name = name; }

        public void Run(Action job)
        {
            lock (jobs)
            {
                jobs.Enqueue(job);
                if (running) return;
                running = true;
            }
            var t = new Thread(Loop) { IsBackground = true, Name = name };
            t.Start();
        }

        void Loop()
        {
            while (true)
            {
                Action job;
                lock (jobs)
                {
                    if (jobs.Count == 0) { running = false; return; }
                    job = jobs.Dequeue();
                }
                try { job(); }
                catch (Exception e) { Log.Write("서버: 오류 " + e.GetType().Name); }
            }
        }
    }

    sealed class Server
    {
        static readonly object sharedGate = new object();
        static bool sharedLoaded;
        static Server shared;

        /// server.json 이 없거나 쓸 수 없으면 null.
        public static Server Shared
        {
            get
            {
                lock (sharedGate)
                {
                    if (!sharedLoaded)
                    {
                        sharedLoaded = true;
                        try { shared = Load(); }
                        catch (Exception e) { Log.Write("서버: server.json 을 읽지 못함: " + e.Message); }
                    }
                    return shared;
                }
            }
        }

        static string ReadManifest()
        {
            try
            {
                string path = Path.Combine(Config.Dir, "server.json");
                if (File.Exists(path)) return File.ReadAllText(path, Encoding.UTF8);
            }
            catch { }
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("server.json"))
            {
                if (s == null) return null;
                using (var r = new StreamReader(s, Encoding.UTF8)) return r.ReadToEnd();
            }
        }

        static Server Load()
        {
            string text = ReadManifest();
            if (string.IsNullOrEmpty(text)) return null;
            return FromManifest(text);
        }

        /// server.json 의 내용으로 만든다. https 주소가 아니거나 키가 없거나 비밀 키면 null.
        internal static Server FromManifest(string text)
        {
            Dictionary<string, object> j;
            try { j = Json.Parse(text.TrimStart('﻿')); }
            catch { return null; }
            string url = Json.Str(j, "url"), key = Json.Str(j, "key");
            Uri b;
            if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out b) || b.Scheme != Uri.UriSchemeHttps) return null;
            if (string.IsNullOrEmpty(key) || key.StartsWith("sb_secret", StringComparison.Ordinal)) return null;
            return new Server(b, key);
        }

        sealed class Session
        {
            public string Access;
            public string Refresh;
            public DateTime Expires;      // UTC
        }

        readonly Uri baseUri;
        readonly string key;
        readonly SerialWorker queue = new SerialWorker("omogi.server");
        Session session;                  // queue 위에서만 만진다
        bool sessionLoaded;

        Server(Uri baseUri, string key)
        {
            this.baseUri = baseUri;
            this.key = key;
            try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; }
            catch { }
        }

        // 보관해 둔 로그인 정보를 처음 쓸 때 한 번 읽는다 (queue 위에서만 부른다).
        void LoadSession()
        {
            if (sessionLoaded) return;
            sessionLoaded = true;
            try
            {
                byte[] d = SecretStore.Load("session");
                if (d == null) return;
                var j = Json.Parse(Encoding.UTF8.GetString(d));
                string a = Json.Str(j, "access"), r = Json.Str(j, "refresh");
                DateTime exp;
                if (!string.IsNullOrEmpty(a) && !string.IsNullOrEmpty(r) && LetterFiles.ParseDate(Json.Str(j, "expires"), out exp))
                    session = new Session { Access = a, Refresh = r, Expires = exp };
            }
            catch { }
        }

        void Store(Session s)
        {
            sessionLoaded = true;
            session = s;
            if (s == null) { SecretStore.Save("session", null); return; }
            var j = new Dictionary<string, object>
            {
                { "access", s.Access }, { "refresh", s.Refresh }, { "expires", LetterFiles.FormatDate(s.Expires) },
            };
            SecretStore.Save("session", Encoding.UTF8.GetBytes(Json.Write(j)));
        }

        /// 이 PC 의 로그인 정보를 지운다 (서버의 계정은 그대로다).
        public void Forget() { queue.Run(() => Store(null)); }

        // 요청 하나를 보내고 끝날 때까지 기다린다 (queue 위에서만 부른다). 돌려주는 값: HTTP 상태(닿지 못하면 0)와 JSON.
        int Post(string path, object body, string bearer, out object json)
        {
            json = null;
            HttpWebResponse resp = null;
            int status = 0;
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(new Uri(baseUri, path));
                req.Method = "POST";
                req.Timeout = 15000;
                req.ReadWriteTimeout = 15000;
                req.ContentType = "application/json";
                req.Accept = "application/json";
                req.UserAgent = "Omogi-Windows/" + AppInfo.Version;
                req.AllowAutoRedirect = false;
                req.ServicePoint.Expect100Continue = false;
                req.Headers["apikey"] = key;
                if (bearer != null) req.Headers[HttpRequestHeader.Authorization] = "Bearer " + bearer;
                byte[] data = Encoding.UTF8.GetBytes(Json.Write(body));
                req.ContentLength = data.Length;
                using (Stream s = req.GetRequestStream()) s.Write(data, 0, data.Length);
                try { resp = (HttpWebResponse)req.GetResponse(); }
                catch (WebException e)
                {
                    resp = e.Response as HttpWebResponse;       // 4xx, 5xx 도 여기로 온다
                    if (resp == null) return 0;
                }
                status = (int)resp.StatusCode;
                string text;
                using (Stream s = resp.GetResponseStream())
                using (var r = new StreamReader(s, Encoding.UTF8)) text = r.ReadToEnd();
                if (!string.IsNullOrWhiteSpace(text))
                {
                    try { json = Json.ParseAny(text); }
                    catch { json = null; }
                }
                return status;
            }
            catch (Exception)
            {
                // 본문을 다 받지 못했으면 닿지 못한 것으로 본다.
                json = null;
                return 0;
            }
            finally
            {
                if (resp != null) resp.Close();
            }
        }

        Session Adopt(object json)
        {
            var j = json as Dictionary<string, object>;
            if (j == null) return null;
            string access = j.ContainsKey("access_token") ? j["access_token"] as string : null;
            string refresh = j.ContainsKey("refresh_token") ? j["refresh_token"] as string : null;
            if (access == null || refresh == null) return null;
            double seconds;
            if (!Json.Number(j, "expires_in", out seconds)) seconds = 3600;
            var s = new Session { Access = access, Refresh = refresh, Expires = DateTime.UtcNow.AddSeconds(seconds) };
            Store(s);
            return s;
        }

        // 쓸 수 있는 로그인 정보를 돌려준다: 있으면 그대로, 곧 끝나면 새로 고치고, 없으면 익명으로 새로 로그인한다.
        Session EnsureSession(bool forceRefresh, out ServerError error)
        {
            error = null;
            object json;
            int status;
            LoadSession();
            if (session != null)
            {
                Session s = session;
                if (!forceRefresh && (s.Expires - DateTime.UtcNow).TotalSeconds > 90) return s;
                status = Post("/auth/v1/token?grant_type=refresh_token", new Dictionary<string, object> { { "refresh_token", s.Refresh } }, null, out json);
                Session renewed = Adopt(json);
                if (renewed != null) return renewed;
                if (status == 0 || status >= 500) { error = new ServerError("offline"); return null; }
                Log.Write("서버: 로그인 정보를 새로 고치지 못해 새로 로그인함 (" + status + ")");
                Store(null);                                   // 더는 쓸 수 없는 토큰이다. 아래에서 새로 로그인한다.
            }
            status = Post("/auth/v1/signup", new Dictionary<string, object>(), null, out json);
            Session fresh = Adopt(json);
            if (fresh != null) return fresh;
            if (status == 0 || status >= 500) { error = new ServerError("offline"); return null; }
            Log.Write("서버: 익명 로그인 실패 (" + status + ")");
            error = new ServerError(status == 422 ? "anonymous_disabled" : "signin_" + status);
            return null;
        }

        /// 서버 함수(public.omogi_*)를 부른다. 결과는 화면 스레드에서 돌려준다.
        public void Call(string function, Dictionary<string, object> args, Action<ServerReply> done)
        {
            var body = args ?? new Dictionary<string, object>();
            queue.Run(() =>
            {
                var outcome = new ServerReply(new ServerError("offline"), null);
                try
                {
                    for (int attempt = 0; attempt < 2; attempt++)
                    {
                        ServerError problem;
                        Session s = EnsureSession(attempt == 1, out problem);
                        if (s == null) { outcome = new ServerReply(problem ?? new ServerError("offline"), null); break; }
                        object json;
                        int status = Post("/rest/v1/rpc/" + function, body, s.Access, out json);
                        if (status == 401 && attempt == 0) continue;          // 토큰이 막 끝났으면 새로 고쳐 한 번 더
                        if (status >= 200 && status < 300) outcome = new ServerReply(null, json);
                        else if (status == 0) outcome = new ServerReply(new ServerError("offline"), null);
                        else
                        {
                            var j = json as Dictionary<string, object>;
                            string msg = (j != null && j.ContainsKey("message") ? j["message"] as string : null) ?? "";
                            outcome = new ServerReply(new ServerError(msg.StartsWith("omogi:", StringComparison.Ordinal) ? msg : "http_" + status), null);
                            Log.Write("서버: " + function + " 실패 (" + status + ")");
                        }
                        break;
                    }
                }
                catch (Exception e)
                {
                    Log.Write("서버: " + function + " 오류 " + e.GetType().Name);
                    outcome = new ServerReply(new ServerError("offline"), null);
                }
                if (done != null) Ui.Post(() => done(outcome));
            });
        }
    }

    /// 서버로 편지를 나르는 길.
    sealed class ServerPost : ILetterTransport
    {
        readonly Server server;
        public ServerPost(Server server) { this.server = server; }

        public void Send(byte[] envelope, Friend to, string fromName, Action<string, ServerError> done)
        {
            var args = new Dictionary<string, object> { { "p_to", to.Id }, { "p_envelope", Convert.ToBase64String(envelope) } };
            server.Call("omogi_send_letter", args, r =>
            {
                if (!r.Ok) { done(null, r.Error); return; }
                string id = r.Value as string;
                if (id != null) done(id, null); else done(null, new ServerError("bad_reply"));
            });
        }

        public void Fetch(Action<List<Arrival>, List<string>> done)
        {
            server.Call("omogi_fetch_mail", null, r =>
            {
                List<Arrival> arrived;
                List<string> lost;
                ParseMail(r.Ok ? r.Value : null, out arrived, out lost);
                done(arrived, lost);
            });
        }

        /// omogi_fetch_mail 의 대답을 읽는다. 읽을 수 없는 것은 건너뛴다.
        internal static void ParseMail(object value, out List<Arrival> arrived, out List<string> lost)
        {
            arrived = new List<Arrival>();
            lost = new List<string>();
            var j = value as Dictionary<string, object>;
            if (j == null) return;
            foreach (var a in LetterFiles.Rows(j.ContainsKey("arrived") ? j["arrived"] : null))
            {
                string id = LetterFiles.Text(a, "id");
                byte[] env = LetterFiles.Base64(LetterFiles.Text(a, "envelope"));
                if (id == null || env == null) continue;
                arrived.Add(new Arrival { Id = id, FromName = LetterFiles.Text(a, "from_name") ?? "친구", Envelope = env });
            }
            object l;
            if (j.TryGetValue("lost", out l) && l is IEnumerable && !(l is string))
            {
                var ids = new List<string>();
                bool allStrings = true;
                foreach (object x in (IEnumerable)l)
                {
                    if (x is string) ids.Add((string)x); else allStrings = false;
                }
                if (allStrings) lost = ids;
            }
        }

        public void Ack(List<string> arrived, List<string> lost)
        {
            if (arrived.Count == 0 && lost.Count == 0) return;
            server.Call("omogi_ack_mail", new Dictionary<string, object> { { "p_arrived", arrived }, { "p_lost", lost } }, null);
        }
    }
}
