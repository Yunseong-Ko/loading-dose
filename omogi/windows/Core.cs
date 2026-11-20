// Omogi — Windows 판의 공통 부분: 조정값, 켜고 끄는 설정, 기록, Windows API.
// Mac 판(omogi/main.swift)과 같은 값·같은 이름을 쓴다.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace Omogi
{
    static class AppInfo
    {
        public const string Version = "0.3.0";
        public const string Credit = "제작자: @hi20010205";
    }

    // ───────────────────── 조정값 ─────────────────────
    // %APPDATA%\Omogi\config.json 으로 바꿀 수 있다 (없으면 기본값). 키 이름은 Mac 판과 같다.
    static class Config
    {
        public static List<string> Targets = new List<string> { "claude", "chatgpt" };   // 프로세스 이름 (.exe 제외, 소문자)
        public static List<string> StopWords = new List<string> { "stop", "중지", "정지", "중단" };
        public static List<string> StopExclude = new List<string>();
        public static double PendingTimeout = 6;   // Enter 뒤 생성이 시작되지 않으면 접는다
        public static double EndGrace = 1.5;       // 중지 버튼이 사라진 뒤 이만큼 지나면 끝
        public const double HardCap = 300;

        public static double WaterMinutes = 45;    // 이 간격으로 물을 마신다
        public static double EyeMinutes = 20;      // 이 간격으로 눈을 감고 20초 쉰다
        public static double StretchMinutes = 50;  // 이 간격으로 기지개를 켠다
        public static double NestMinutes = 5;      // 이만큼 입력이 없으면 둥지를 짓고 잔다
        public static double QuizBringMinutes = 25;   // 문제를 물어 오는 간격

        // 연습 배달(서버 없이 나에게 보내기)에만 쓰인다. 친구에게 보내는 편지는 서버가 정한다.
        public static double LetterMinMinutes = 30;
        public static double LetterMaxMinutes = 180;
        public static double LetterLossPercent = 8;

        static string dir;
        /// 설정·기록·편지가 들어가는 폴더. 자체 점검 때는 다른 폴더로 바꾼다.
        public static string Dir
        {
            get
            {
                if (dir == null) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Omogi");
                Directory.CreateDirectory(dir);
                return dir;
            }
            set { dir = value; }
        }

        public static bool IsStop(string name)
        {
            if (string.IsNullOrEmpty(name)) return false;
            string l = name.ToLowerInvariant();
            return StopWords.Any(w => l.Contains(w)) && !StopExclude.Any(w => l.Contains(w));
        }

        public static bool IsTarget(string process)
        {
            return !string.IsNullOrEmpty(process) && Targets.Contains(process.ToLowerInvariant());
        }

        public static void Load()
        {
            string path = Path.Combine(Dir, "config.json");
            if (!File.Exists(path)) return;
            try
            {
                var j = Json.Parse(File.ReadAllText(path, Encoding.UTF8));
                var t = Json.Strings(j, "targets");
                if (t != null && t.Count > 0) Targets = t.Select(s => s.ToLowerInvariant().Replace(".exe", "")).ToList();
                var w = Json.Strings(j, "stopWords");
                if (w != null && w.Count > 0) StopWords = w.Select(s => s.ToLowerInvariant()).ToList();
                var x = Json.Strings(j, "stopExclude");
                if (x != null) StopExclude = x.Select(s => s.ToLowerInvariant()).ToList();
                double v;
                if (Json.Number(j, "pendingTimeout", out v) && v > 0) PendingTimeout = v;
                if (Json.Number(j, "endGrace", out v) && v > 0) EndGrace = v;
                if (Json.Number(j, "waterMinutes", out v) && v > 0) WaterMinutes = v;
                if (Json.Number(j, "eyeMinutes", out v) && v > 0) EyeMinutes = v;
                if (Json.Number(j, "stretchMinutes", out v) && v > 0) StretchMinutes = v;
                if (Json.Number(j, "nestMinutes", out v) && v > 0) NestMinutes = v;
                if (Json.Number(j, "quizBringMinutes", out v) && v > 0) QuizBringMinutes = v;
                if (Json.Number(j, "letterMinMinutes", out v) && v > 0) LetterMinMinutes = v;
                if (Json.Number(j, "letterMaxMinutes", out v) && v > 0) LetterMaxMinutes = v;
                if (Json.Number(j, "letterLossPercent", out v) && v >= 0) LetterLossPercent = v;
                Log.Write("config.json 적용");
            }
            catch (Exception e)
            {
                Log.Write("config.json 을 읽지 못함: " + e.Message);
            }
        }
    }

    // 켜고 끄는 설정 (settings.json). 이름은 Mac 판의 UserDefaults 키와 같다.
    static class Settings
    {
        static Dictionary<string, object> data;
        static string FilePath { get { return Path.Combine(Config.Dir, "settings.json"); } }

        static void Load()
        {
            if (data != null) return;
            data = new Dictionary<string, object>();
            try
            {
                if (File.Exists(FilePath)) data = Json.Parse(File.ReadAllText(FilePath, Encoding.UTF8));
            }
            catch (Exception e) { Log.Write("settings.json 을 읽지 못함: " + e.Message); }
        }

        public static bool Get(string key, bool fallback)
        {
            Load();
            object o;
            if (data.TryGetValue(key, out o) && o is bool) return (bool)o;
            return fallback;
        }

        public static void Set(string key, bool value)
        {
            Load();
            data[key] = value;
            try { File.WriteAllText(FilePath, Json.Write(data), new UTF8Encoding(false)); }
            catch (Exception e) { Log.Write("settings.json 을 쓰지 못함: " + e.Message); }
        }

        public static bool PetOn { get { return Get("petOn", true); } set { Set("petOn", value); } }
        public static bool HabitsOn { get { return Get("habitsOn", true); } set { Set("habitsOn", value); } }
        public static bool QuizEnterOn { get { return Get("quizEnterOn", false); } set { Set("quizEnterOn", value); } }
        public static bool QuizBringOn { get { return Get("quizBringOn", false); } set { Set("quizBringOn", value); } }
        public static bool Welcomed { get { return Get("welcomed", false); } set { Set("welcomed", value); } }
    }

    static class Json
    {
        public static Dictionary<string, object> Parse(string text)
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.Deserialize<Dictionary<string, object>>(text)
                ?? new Dictionary<string, object>();
        }

        /// 배열이든 객체든 그대로 읽는다 (Dictionary<string, object>, ArrayList, string, 숫자, bool, null).
        public static object ParseAny(string text)
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(text);
        }

        public static string Write(object o)
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.Serialize(o);
        }

        public static List<string> Strings(Dictionary<string, object> j, string key)
        {
            object o;
            if (!j.TryGetValue(key, out o) || o == null || o is string) return null;
            var e = o as IEnumerable;
            if (e == null) return null;
            var list = new List<string>();
            foreach (object x in e) if (x != null) list.Add(x.ToString());
            return list;
        }

        public static bool Number(Dictionary<string, object> j, string key, out double v)
        {
            v = 0;
            object o;
            if (!j.TryGetValue(key, out o) || o == null) return false;
            try { v = Convert.ToDouble(o); return true; }
            catch { return false; }
        }

        public static string Str(Dictionary<string, object> j, string key)
        {
            object o;
            return j != null && j.TryGetValue(key, out o) && o != null ? o.ToString() : null;
        }
    }

    // 진단 기록. 창 제목·대화·편지 내용은 적지 않는다. 무엇을 했는지만 남긴다.
    static class Log
    {
        static readonly object gate = new object();
        public static string FilePath { get { return Path.Combine(Config.Dir, "debug.log"); } }

        public static void Start()
        {
            try
            {
                var f = new FileInfo(FilePath);
                if (f.Exists && f.Length > 300000) f.Delete();
            }
            catch { }
        }

        public static void Write(string s)
        {
            lock (gate)
            {
                try { File.AppendAllText(FilePath, DateTime.Now.ToString("MM-dd HH:mm:ss.fff") + " " + s + Environment.NewLine, Encoding.UTF8); }
                catch { }
            }
        }
    }

    /// 다른 스레드에서 끝난 일을 화면 스레드로 넘긴다. 앱이 시작할 때 화면 스레드에서 Init() 을 한 번 부른다.
    static class Ui
    {
        static SynchronizationContext context;

        public static void Init()
        {
            if (SynchronizationContext.Current == null)
                SynchronizationContext.SetSynchronizationContext(new System.Windows.Forms.WindowsFormsSynchronizationContext());
            context = SynchronizationContext.Current;
        }

        public static void Post(Action a)
        {
            if (context == null) { a(); return; }
            context.Post(_ => { try { a(); } catch (Exception e) { Log.Write("오류: " + e); } }, null);
        }
    }

    /// 편지 심부름을 하는 쪽(펫). 편지 코드는 펫의 나머지를 몰라도 된다.
    interface ICourier
    {
        /// 편지를 물고 화면 밖으로 날아갔다가 돌아온다. 지금 나설 수 없으면 false.
        bool CarryOut();
        /// 화면 밖에서 편지를 물고 돌아와 누를 때까지 기다린다. 지금 나설 수 없으면 false.
        bool BringMail(string text);
        /// 보낸 편지가 누락됐다고 시무룩하게 알린다. 지금 나설 수 없으면 false.
        bool ReportLost(string text);
        bool IsHoldingMail { get; }
    }

    // ───────────────────── Windows API ─────────────────────
    static class Native
    {
        public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll")]
        public static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetModuleHandle(string lpModuleName);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
        [DllImport("user32.dll")]
        static extern bool SystemParametersInfo(uint action, uint param, ref bool value, uint winIni);

        // 투명한 창(픽셀마다 투명도)에 그림을 올리는 데 쓴다.
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE { public int W, H; public SIZE(int w, int h) { W = w; H = h; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION { public byte Op, Flags, Alpha, Format; }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT dst, ref SIZE size, IntPtr hdcSrc,
                                                      ref POINT src, int key, ref BLENDFUNCTION blend, int flags);
        [DllImport("user32.dll")]
        public static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")]
        public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr obj);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hwnd, int index, int value);

        /// 다른 "항상 위" 창들보다 위로 올린다 (포커스는 가져오지 않는다).
        public static void RaiseTopmost(IntPtr hwnd)
        {
            SetWindowPos(hwnd, (IntPtr)(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
        }

        public static string ProcessName(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return "";
            try
            {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (pid == 0) return "";
                using (Process p = Process.GetProcessById((int)pid)) return p.ProcessName.ToLowerInvariant();
            }
            catch { return ""; }
        }

        /// 마지막 마우스·키보드 입력 뒤로 지난 시간(초)
        public static double IdleSeconds()
        {
            try
            {
                var info = new LASTINPUTINFO();
                info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
                if (!GetLastInputInfo(ref info)) return 0;
                return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
            }
            catch { return 0; }
        }

        /// 자체 점검용: Windows 설정과 상관없이 움직임을 켠다.
        public static bool ForceMotion;

        /// Windows 설정의 "애니메이션 효과"를 꺼 두었으면 true (돌아다니기·던지기·부풀기를 하지 않는다).
        public static bool ReduceMotion()
        {
            if (ForceMotion) return false;
            try
            {
                bool on = true;
                if (SystemParametersInfo(0x1042 /* SPI_GETCLIENTAREAANIMATION */, 0, ref on, 0)) return !on;
            }
            catch { }
            return false;
        }

        public static bool AnotherInstance(string processName)
        {
            try { return Process.GetProcessesByName(processName).Length > 0; }
            catch { return false; }
        }
    }
}
