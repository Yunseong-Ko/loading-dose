// Loading Dose — Windows 판
// Claude·ChatGPT Windows 앱에서 Enter 를 누르면 화면 위에 O/X 카드를 띄우고, 답변이 끝나면 접는다.
// 판단 방식은 Mac 판(mac/main.swift)과 같다: Enter 감지 → 대상 앱 창에서 "중지" 버튼이 보이는 동안을 생성 중으로 본다.
// 화면 요소를 읽는 부분만 Scanner.cs 에 따로 있다.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using WinTimer = System.Windows.Forms.Timer;

namespace LoadingDose
{
    // ───────────────────── 조정값 ─────────────────────
    // %APPDATA%\LoadingDose\config.json 으로 바꿀 수 있다 (없으면 기본값).
    // {"targets": ["claude", "chatgpt"], "stopWords": ["stop"], "stopExclude": [], "pendingTimeout": 6, "endGrace": 1.5}
    static class Config
    {
        public const string Version = "0.1.0";
        public static List<string> Targets = new List<string> { "claude", "chatgpt" };   // 프로세스 이름 (.exe 제외, 소문자)
        public static List<string> StopWords = new List<string> { "stop", "중지", "정지", "중단" };
        public static List<string> StopExclude = new List<string>();
        public static double PendingTimeout = 6;   // Enter 뒤 생성이 시작되지 않으면 접는다
        public static double EndGrace = 1.5;       // 중지 버튼이 사라진 뒤 이만큼 지나면 끝
        public const double HardCap = 300;

        public static string Dir
        {
            get
            {
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LoadingDose");
                Directory.CreateDirectory(d);
                return d;
            }
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
                Log.Write("config.json 적용: targets=" + string.Join(",", Targets) + " stopWords=" + string.Join(",", StopWords)
                    + " stopExclude=" + string.Join(",", StopExclude) + " pendingTimeout=" + PendingTimeout + " endGrace=" + EndGrace);
            }
            catch (Exception e)
            {
                Log.Write("config.json 을 읽지 못함: " + e.Message);
            }
        }
    }

    static class Json
    {
        public static Dictionary<string, object> Parse(string text)
        {
            return new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.Deserialize<Dictionary<string, object>>(text)
                ?? new Dictionary<string, object>();
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
    }

    // 진단 기록. 대화 내용은 적지 않는다 (프로세스 이름, 버튼 이름, 시간만).
    static class Log
    {
        static readonly object gate = new object();
        public static string FilePath { get { return Path.Combine(Config.Dir, "debug.log"); } }

        public static void Start()
        {
            try
            {
                var f = new FileInfo(FilePath);
                if (f.Exists && f.Length > 1000000) f.Delete();
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

    // ───────────────────── 문제 ─────────────────────
    class Card
    {
        public string Q, Why, Topic;
        public bool A;
        public bool Own;
    }

    class Deck
    {
        public const string OwnTopic = "내 문제";
        List<Card> builtin = new List<Card>();
        List<Card> own = new List<Card>();
        public List<string> Topics = new List<string>();                 // 기본 제공 과목 (파일 순서)
        public HashSet<string> PackOff = new HashSet<string>();          // 꺼 둔 과목
        Dictionary<string, int[]> stats = new Dictionary<string, int[]>();   // 문장 → [맞힘, 틀림]
        string day = "";
        public int DayDone, Streak;
        string lastQ = "";
        readonly Random rng = new Random();

        public static string OwnFile { get { return Path.Combine(Config.Dir, "cards.txt"); } }
        static string StateFile { get { return Path.Combine(Config.Dir, "state.json"); } }

        public int BuiltinCount { get { return builtin.Count; } }
        public int OwnCount { get { return own.Count; } }
        public int CountOf(string topic) { return builtin.Count(c => c.Topic == topic); }

        public Deck()
        {
            LoadBuiltin();
            LoadOwn();
            LoadState();
        }

        // "## 과목" 줄은 과목을 바꾸고, "#" 줄은 무시한다. 형식: 문장 | O 또는 X | 해설
        public static List<Card> Parse(string text, bool isOwn)
        {
            var list = new List<Card>();
            string topic = isOwn ? OwnTopic : "";
            foreach (string raw in text.Replace("\r", "").Split('\n'))
            {
                string line = raw.Trim();
                if (line.Length == 0) continue;
                if (line.StartsWith("##")) { topic = line.TrimStart('#').Trim(); continue; }
                if (line.StartsWith("#")) continue;
                if (line.Contains("{{c")) continue;   // Anki 빈칸 형식은 이 판에서 다루지 않는다
                string[] p = line.Split('|');
                if (p.Length < 2) continue;
                string a = p[1].Trim().ToUpperInvariant();
                if (a != "O" && a != "X") continue;
                string q = p[0].Trim();
                if (q.Length == 0) continue;
                list.Add(new Card
                {
                    Q = q,
                    A = a == "O",
                    Why = p.Length > 2 ? string.Join("|", p.Skip(2)).Trim() : "",
                    Topic = topic,
                    Own = isOwn,
                });
            }
            return list;
        }

        void LoadBuiltin()
        {
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("kmle.txt"))
                {
                    if (s == null) { Log.Write("기본 제공 퀴즈를 찾지 못함"); return; }
                    using (var r = new StreamReader(s, Encoding.UTF8)) builtin = Parse(r.ReadToEnd(), false);
                }
                foreach (Card c in builtin) if (!Topics.Contains(c.Topic)) Topics.Add(c.Topic);
            }
            catch (Exception e) { Log.Write("기본 제공 퀴즈를 읽지 못함: " + e.Message); }
        }

        public void LoadOwn()
        {
            own = new List<Card>();
            try
            {
                if (File.Exists(OwnFile)) own = Parse(File.ReadAllText(OwnFile, Encoding.UTF8), true);
            }
            catch (Exception e) { Log.Write("cards.txt 를 읽지 못함: " + e.Message); }
        }

        public void EnsureOwnFile()
        {
            if (File.Exists(OwnFile)) return;
            File.WriteAllText(OwnFile,
                "# 내 문제를 한 줄에 하나씩 적습니다.  형식: 문장 | O 또는 X | 해설\r\n" +
                "# \"#\" 으로 시작하는 줄은 무시합니다. 저장한 뒤 트레이 메뉴의 \"내 문제 다시 읽기\"를 누르세요.\r\n" +
                "# 예) 급성 증상성 저칼슘혈증은 IV calcium gluconate로 치료한다. | O | 저마그네슘혈증이 동반되면 Mg도 보충한다.\r\n",
                new UTF8Encoding(true));
        }

        List<Card> Active()
        {
            var list = own.Concat(builtin.Where(c => !PackOff.Contains(c.Topic))).ToList();
            return list.Count > 0 ? list : builtin;
        }

        public int ActiveCount { get { return Active().Count; } }

        // 틀린 문제일수록 자주, 많이 맞힌 문제일수록 드물게 (Mac 판과 같은 가중치).
        public Card Pick()
        {
            List<Card> source = Active();
            if (source.Count == 0) return new Card { Q = "문제가 없습니다. 트레이 메뉴에서 과목을 켜 주세요.", A = true, Why = "", Topic = "" };
            List<Card> candidates = source.Count > 1 ? source.Where(c => c.Q != lastQ).ToList() : source;
            var weights = candidates.Select(c =>
            {
                int[] s;
                if (!stats.TryGetValue(c.Q, out s)) s = new[] { 0, 0 };
                return Math.Max(0.25, 1 + 2.0 * s[1] - 0.5 * s[0]);
            }).ToList();
            double r = rng.NextDouble() * weights.Sum();
            Card chosen = candidates[candidates.Count - 1];
            for (int i = 0; i < weights.Count; i++)
            {
                r -= weights[i];
                if (r <= 0) { chosen = candidates[i]; break; }
            }
            lastQ = chosen.Q;
            return chosen;
        }

        void RollDay()
        {
            string today = DateTime.Now.ToString("yyyy-MM-dd");
            if (day != today) { day = today; DayDone = 0; }
        }

        public void Record(Card c, bool correct)
        {
            int[] s;
            if (!stats.TryGetValue(c.Q, out s)) s = new[] { 0, 0 };
            s[correct ? 0 : 1]++;
            stats[c.Q] = s;
            RollDay();
            DayDone++;
            Streak = correct ? Streak + 1 : 0;
            SaveState();
        }

        public int TodayCount { get { RollDay(); return DayDone; } }

        void LoadState()
        {
            try
            {
                if (!File.Exists(StateFile)) return;
                var j = Json.Parse(File.ReadAllText(StateFile, Encoding.UTF8));
                var off = Json.Strings(j, "packOff");
                if (off != null) PackOff = new HashSet<string>(off);
                object o;
                if (j.TryGetValue("day", out o) && o != null) day = o.ToString();
                double v;
                if (Json.Number(j, "dayDone", out v)) DayDone = (int)v;
                if (Json.Number(j, "streak", out v)) Streak = (int)v;
                if (j.TryGetValue("stats", out o))
                {
                    var d = o as IDictionary<string, object>;
                    if (d != null)
                    {
                        foreach (var kv in d)
                        {
                            var e = kv.Value as IEnumerable;
                            if (e == null) continue;
                            var n = new List<int>();
                            foreach (object x in e) n.Add(Convert.ToInt32(x));
                            if (n.Count == 2) stats[kv.Key] = new[] { n[0], n[1] };
                        }
                    }
                }
            }
            catch (Exception e) { Log.Write("state.json 을 읽지 못함: " + e.Message); }
        }

        public void SaveState()
        {
            try
            {
                var j = new Dictionary<string, object>
                {
                    { "packOff", PackOff.ToList() },
                    { "day", day },
                    { "dayDone", DayDone },
                    { "streak", Streak },
                    { "stats", stats },
                };
                File.WriteAllText(StateFile, Json.Write(j), Encoding.UTF8);
            }
            catch (Exception e) { Log.Write("state.json 을 쓰지 못함: " + e.Message); }
        }
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
    }

    // Enter 와 Alt+O / Alt+X 를 잡는다. 훅은 UI 스레드에 걸리므로 콜백도 UI 스레드에서 돈다.
    sealed class KeyHook : IDisposable
    {
        IntPtr hook = IntPtr.Zero;
        Native.HookProc proc;   // 가비지 수집되지 않게 붙잡아 둔다
        public Func<bool> CanAnswer;
        public Action<bool> OnAnswer;
        public Action OnEnter;

        public bool Install()
        {
            proc = Callback;
            hook = Native.SetWindowsHookEx(13 /* WH_KEYBOARD_LL */, proc, Native.GetModuleHandle(null), 0);
            return hook != IntPtr.Zero;
        }

        static bool Down(int vk) { return (Native.GetAsyncKeyState(vk) & 0x8000) != 0; }

        IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                int msg = (int)wParam;
                if (nCode >= 0 && (msg == 0x100 /* WM_KEYDOWN */ || msg == 0x104 /* WM_SYSKEYDOWN */))
                {
                    int vk = Marshal.ReadInt32(lParam);
                    int flags = Marshal.ReadInt32(lParam, 8);
                    bool alt = (flags & 0x20) != 0;
                    if (alt && (vk == 0x4F || vk == 0x58) && !Down(0x11) && CanAnswer != null && CanAnswer())
                    {
                        if (OnAnswer != null) OnAnswer(vk == 0x4F);
                        return (IntPtr)1;   // 대상 앱으로 넘기지 않는다
                    }
                    if (vk == 0x0D && !alt && !Down(0x10) && !Down(0x11) && !Down(0x5B) && !Down(0x5C))
                    {
                        if (OnEnter != null) OnEnter();
                    }
                }
            }
            catch { }
            return Native.CallNextHookEx(hook, nCode, wParam, lParam);
        }

        public void Dispose()
        {
            if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
    }

    // ───────────────────── 카드 창 ─────────────────────
    // 화면 위 가운데에 뜨는 알약. 질문 카드로 펼쳐졌다가 답변이 오면 다시 알약으로 접힌다.
    // 포커스를 뺏지 않는다 (입력 중인 채팅 창이 그대로 활성 상태로 남는다).
    class QuizForm : Form
    {
        enum Mode { Pill, Ask, Graded }

        static readonly Color CardBG = Color.FromArgb(226, 223, 217);
        static readonly Color Ink = Color.FromArgb(28, 28, 30);
        static readonly Color Sub = Color.FromArgb(92, 90, 86);
        static readonly Color Faint = Color.FromArgb(150, 146, 140);
        static readonly Color Blue = Color.FromArgb(52, 120, 246);
        static readonly Color Green = Color.FromArgb(46, 139, 58);
        static readonly Color Bad = Color.FromArgb(190, 50, 40);
        static readonly Color BtnIdle = Color.FromArgb(204, 201, 195);
        static readonly Color BtnO = Color.FromArgb(92, 191, 78);
        static readonly Color BtnX = Color.FromArgb(226, 69, 54);

        readonly Deck deck;
        public Func<bool> IsLoading = () => false;

        Mode mode = Mode.Pill;
        bool done;
        int seconds;
        Card card;
        bool correct;
        Rectangle area;
        Rectangle rO, rX, rNext, rClose;
        DateTime? nextAt, collapseAt, hideAt;
        float angle;
        readonly WinTimer anim = new WinTimer { Interval = 40 };
        readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();

        public QuizForm(Deck deck)
        {
            this.deck = deck;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            BackColor = CardBG;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            area = Screen.PrimaryScreen.WorkingArea;
            anim.Tick += (s, e) => OnAnim();
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 /* NOACTIVATE */ | 0x00000080 /* TOOLWINDOW */ | 0x00000008 /* TOPMOST */;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                int round = 2;   // Windows 11: 둥근 모서리. Windows 10 에서는 무시된다.
                Native.DwmSetWindowAttribute(Handle, 33, ref round, 4);
            }
            catch { }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x21 /* WM_MOUSEACTIVATE */) { m.Result = (IntPtr)3; return; }   // 눌러도 활성화하지 않는다
            if (m.Msg == 0x02E0 /* WM_DPICHANGED */) { ClearFonts(); base.WndProc(ref m); if (Visible) Relayout(); return; }
            base.WndProc(ref m);
        }

        public bool CanAnswer { get { return Visible && mode == Mode.Ask; } }

        // ── 바깥에서 부르는 동작 ──
        public void StartCard(Rectangle screenArea)
        {
            area = screenArea;
            done = false;
            seconds = 0;
            nextAt = collapseAt = hideAt = null;
            NewCard();
            if (!Visible) Show();
            anim.Start();
        }

        public void SetProgress(int sec)
        {
            if (done || !Visible) return;
            if (sec != seconds) { seconds = sec; Invalidate(); }
        }

        public void Answer(bool pick)
        {
            if (!CanAnswer) return;
            correct = pick == card.A;
            deck.Record(card, correct);
            mode = Mode.Graded;
            collapseAt = null;
            nextAt = DateTime.Now.AddSeconds(done ? 2.5 : 4.0);
            Relayout();
        }

        public void MarkDone(int sec)
        {
            if (!Visible) return;
            done = true;
            seconds = sec;
            if (mode == Mode.Ask) collapseAt = DateTime.Now.AddSeconds(5);
            else if (mode == Mode.Pill) hideAt = DateTime.Now.AddSeconds(2.5);
            else if (nextAt == null) nextAt = DateTime.Now.AddSeconds(2.5);
            Relayout();
        }

        public void HideCard()
        {
            nextAt = collapseAt = hideAt = null;
            anim.Stop();
            if (Visible) Hide();
        }

        void NewCard()
        {
            card = deck.Pick();
            mode = Mode.Ask;
            nextAt = null;
            Relayout();
        }

        void Collapse()
        {
            mode = Mode.Pill;
            nextAt = collapseAt = null;
            hideAt = DateTime.Now.AddSeconds(2.5);
            Relayout();
        }

        void NextOrCollapse()
        {
            if (IsLoading()) NewCard(); else Collapse();
        }

        void OnAnim()
        {
            if (!Visible) { anim.Stop(); return; }
            DateTime now = DateTime.Now;
            if (hideAt != null && now >= hideAt) { HideCard(); return; }
            if (nextAt != null && now >= nextAt) { nextAt = null; NextOrCollapse(); return; }
            if (collapseAt != null && now >= collapseAt) { Collapse(); return; }
            if (!done)
            {
                angle = (angle + 14) % 360;
                Invalidate(new Rectangle(0, 0, Px(60), Px(44)));
            }
        }

        // ── 그리기 ──
        float S { get { return DeviceDpi / 96f; } }
        int Px(float v) { return (int)Math.Round(v * S); }

        Font F(float px, FontStyle style)
        {
            string key = px + "/" + (int)style + "/" + DeviceDpi;
            Font f;
            if (!fonts.TryGetValue(key, out f))
            {
                f = new Font("Malgun Gothic", px * S, style, GraphicsUnit.Pixel);
                fonts[key] = f;
            }
            return f;
        }

        void ClearFonts()
        {
            foreach (Font f in fonts.Values) f.Dispose();
            fonts.Clear();
        }

        int CardWidth { get { return Px(mode == Mode.Pill ? 330 : 470); } }

        void Relayout()
        {
            int w = CardWidth, h;
            using (Graphics g = CreateGraphics()) h = Compose(g, false);
            Bounds = new Rectangle(area.Left + (area.Width - w) / 2, area.Top + Px(10), w, h);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(CardBG);
            Compose(e.Graphics, true);
        }

        static StringFormat Fmt(StringAlignment h, StringAlignment v)
        {
            var sf = new StringFormat(StringFormat.GenericTypographic);
            sf.Alignment = h;
            sf.LineAlignment = v;
            sf.Trimming = StringTrimming.EllipsisCharacter;
            return sf;
        }

        static void Fill(Graphics g, Rectangle r, int radius, Color c)
        {
            using (var path = new GraphicsPath())
            using (var b = new SolidBrush(c))
            {
                int d = radius * 2;
                path.AddArc(r.Left, r.Top, d, d, 180, 90);
                path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
                path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
                path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
                path.CloseFigure();
                g.FillPath(b, path);
            }
        }

        static void Draw(Graphics g, string s, Font f, Color c, RectangleF r, StringAlignment h = StringAlignment.Near,
                         StringAlignment v = StringAlignment.Near)
        {
            using (var b = new SolidBrush(c))
            using (StringFormat sf = Fmt(h, v))
                g.DrawString(s, f, b, r, sf);
        }

        static int Measure(Graphics g, string s, Font f, int width)
        {
            using (StringFormat sf = Fmt(StringAlignment.Near, StringAlignment.Near))
                return (int)Math.Ceiling(g.MeasureString(s, f, width, sf).Height);
        }

        // 한 함수가 크기 계산과 그리기를 함께 맡는다 (draw=false 면 높이만 구한다).
        int Compose(Graphics g, bool draw)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            int w = CardWidth, pad = Px(20), headH = Px(44);

            if (draw)
            {
                var icon = new Rectangle(pad, Px(13), Px(18), Px(18));
                if (done)
                {
                    using (var pen = new Pen(BtnO, Px(2.4f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                    {
                        g.DrawEllipse(pen, icon);
                        g.DrawLines(pen, new[]
                        {
                            new PointF(icon.Left + icon.Width * 0.27f, icon.Top + icon.Height * 0.52f),
                            new PointF(icon.Left + icon.Width * 0.44f, icon.Top + icon.Height * 0.69f),
                            new PointF(icon.Left + icon.Width * 0.74f, icon.Top + icon.Height * 0.33f),
                        });
                    }
                }
                else
                {
                    using (var pen = new Pen(Blue, Px(2.8f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                        g.DrawArc(pen, icon, angle, 250);
                }
                string head = done ? "답변 도착 · " + seconds + "초" : "답변 생성 중 · " + seconds + "초";
                Draw(g, head, F(14, FontStyle.Bold), done ? Green : Color.FromArgb(58, 58, 60),
                     new RectangleF(pad + Px(28), 0, w - pad * 2 - Px(28), headH), StringAlignment.Near, StringAlignment.Center);
            }

            if (mode == Mode.Pill)
            {
                if (draw && done)
                    Draw(g, "오늘 " + deck.TodayCount + "문제", F(13, FontStyle.Regular), Faint,
                         new RectangleF(pad, 0, w - pad * 2, headH), StringAlignment.Far, StringAlignment.Center);
                return headH;
            }

            rClose = new Rectangle(w - pad - Px(18), Px(10), Px(24), Px(24));
            if (draw) Draw(g, "×", F(19, FontStyle.Regular), Sub, rClose, StringAlignment.Center, StringAlignment.Center);

            int y = headH + Px(6);
            int cw = w - pad * 2;
            if (!string.IsNullOrEmpty(card.Topic))
            {
                if (draw) Draw(g, card.Topic, F(12, FontStyle.Bold), Sub, new RectangleF(pad, y, cw, Px(18)));
                y += Px(22);
            }

            Font qf = F(18, FontStyle.Bold);
            int qh = Measure(g, card.Q, qf, cw);
            if (draw) Draw(g, card.Q, qf, Ink, new RectangleF(pad, y, cw, qh + Px(4)));
            y += qh + Px(14);

            int bh = Px(44), gap = Px(10), bw = (cw - gap) / 2;
            rO = new Rectangle(pad, y, bw, bh);
            rX = new Rectangle(pad + bw + gap, y, cw - bw - gap, bh);
            if (draw)
            {
                bool graded = mode == Mode.Graded;
                Fill(g, rO, Px(10), graded ? BtnO : BtnIdle);
                Fill(g, rX, Px(10), graded ? BtnX : BtnIdle);
                Font bf = F(18, FontStyle.Bold);
                Draw(g, "O", bf, graded ? Color.White : Ink, rO, StringAlignment.Center, StringAlignment.Center);
                Draw(g, "X", bf, graded ? Color.White : Ink, rX, StringAlignment.Center, StringAlignment.Center);
            }
            y += bh + Px(12);

            string tally = "오늘 " + deck.TodayCount + "문제 · 연속 " + deck.Streak;
            if (mode == Mode.Ask)
            {
                rNext = Rectangle.Empty;
                if (draw)
                {
                    Draw(g, tally, F(12, FontStyle.Regular), Faint, new RectangleF(pad, y, cw, Px(18)));
                    Draw(g, "Alt+O · Alt+X", F(12, FontStyle.Regular), Faint, new RectangleF(pad, y, cw, Px(18)), StringAlignment.Far);
                }
                return y + Px(18) + Px(14);
            }

            // 채점 뒤
            if (draw)
                Draw(g, (correct ? "정답" : "오답") + " — 답은 " + (card.A ? "O" : "X"), F(15, FontStyle.Bold), correct ? Green : Bad,
                     new RectangleF(pad, y, cw, Px(22)));
            y += Px(26);
            if (!string.IsNullOrEmpty(card.Why))
            {
                Font wf = F(13, FontStyle.Regular);
                int wh = Measure(g, card.Why, wf, cw);
                if (draw) Draw(g, card.Why, wf, Sub, new RectangleF(pad, y, cw, wh + Px(4)));
                y += wh + Px(10);
            }
            rNext = new Rectangle(w - pad - Px(110), y - Px(4), Px(110), Px(26));
            if (draw)
            {
                Draw(g, tally, F(12, FontStyle.Regular), Faint, new RectangleF(pad, y, cw, Px(18)));
                Draw(g, "다음 문제 →", F(13, FontStyle.Bold), Blue, new RectangleF(pad, y - Px(1), cw, Px(20)), StringAlignment.Far);
            }
            return y + Px(18) + Px(14);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left || mode == Mode.Pill) return;
            if (rClose.Contains(e.Location)) { HideCard(); return; }
            if (mode == Mode.Ask)
            {
                if (rO.Contains(e.Location)) Answer(true);
                else if (rX.Contains(e.Location)) Answer(false);
            }
            else if (mode == Mode.Graded && rNext.Contains(e.Location))
            {
                nextAt = null;
                NextOrCollapse();
            }
        }
    }

    // ───────────────────── 앱 ─────────────────────
    class TrayApp : ApplicationContext
    {
        enum Phase { Idle, Pending, Streaming }

        readonly Deck deck = new Deck();
        readonly QuizForm ui;
        readonly NotifyIcon tray = new NotifyIcon();
        readonly KeyHook keys = new KeyHook();
        readonly WinTimer tick = new WinTimer { Interval = 400 };
        readonly WinTimer watch = new WinTimer { Interval = 2000 };
        readonly ToolStripMenuItem statusItem = new ToolStripMenuItem("준비 중") { Enabled = false };
        readonly ToolStripMenuItem subjects = new ToolStripMenuItem("과목 선택");
        bool hookOn;

        Phase phase = Phase.Idle;
        IntPtr target = IntPtr.Zero;
        DateTime startedAt, pendingAt, lastSeen;
        DateTime? demoUntil;
        bool lastFound;
        IntPtr lastTarget = IntPtr.Zero;   // 마지막으로 본 대상 앱 창 (진단용)
        string lastTargetName = "";
        string lastScan = "아직 없음";

        public TrayApp(bool demo)
        {
            Log.Start();
            Config.Load();
            ui = new QuizForm(deck);
            IntPtr force = ui.Handle;   // BeginInvoke 를 쓸 수 있게 창 핸들을 미리 만든다
            ui.IsLoading = () => phase != Phase.Idle;

            keys.CanAnswer = () => ui.CanAnswer;
            keys.OnAnswer = pick => ui.BeginInvoke((Action)(() => ui.Answer(pick)));
            keys.OnEnter = () => ui.BeginInvoke((Action)OnEnterKey);
            hookOn = keys.Install();
            Log.Write("──── 실행 v" + Config.Version + " 키 감지=" + hookOn + " 문제=" + deck.BuiltinCount + "+" + deck.OwnCount
                + " OS=" + Environment.OSVersion.Version);

            BuildTray();
            tick.Tick += (s, e) => Tick();
            tick.Start();
            watch.Tick += (s, e) => Watch();
            watch.Start();

            if (demo) StartDemo();
            else tray.ShowBalloonTip(6000, "Loading Dose 실행 중",
                "작업 표시줄 오른쪽의 아이콘을 오른쪽 클릭하면 메뉴가 열립니다. Claude나 ChatGPT 앱에서 Enter 를 누르면 카드가 뜹니다.",
                ToolTipIcon.Info);
        }

        // ── 트레이 메뉴 ──
        void BuildTray()
        {
            Icon icon = null;
            try { icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            tray.Icon = icon ?? SystemIcons.Application;
            tray.Text = "Loading Dose";

            var menu = new ContextMenuStrip();
            menu.Items.Add(statusItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("카드 미리 보기 (8초)", null, (s, e) => StartDemo());
            menu.Items.Add(subjects);
            menu.Items.Add("내 문제 편집…", null, (s, e) => EditOwn());
            menu.Items.Add("내 문제 다시 읽기", null, (s, e) => { deck.LoadOwn(); Notify("내 문제 " + deck.OwnCount + "개를 읽었습니다."); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("진단 정보 복사", null, (s, e) => CopyDiagnostics());
            menu.Items.Add("진단 기록 파일 열기", null, (s, e) => OpenPath(Log.FilePath));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Loading Dose 종료", null, (s, e) => Quit());
            menu.Opening += (s, e) => RefreshMenu();
            subjects.DropDown.Closing += (s, e) =>
            {
                if (e.CloseReason == ToolStripDropDownCloseReason.ItemClicked) e.Cancel = true;   // 여러 과목을 이어서 고를 수 있게
            };
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            RefreshMenu();
        }

        void RefreshMenu()
        {
            statusItem.Text = (hookOn ? "작동 중" : "키 감지를 켜지 못함") + " · 출제 범위 " + deck.ActiveCount + "문제";
            subjects.DropDownItems.Clear();
            subjects.DropDownItems.Add("모두 켜기", null, (s, e) => { deck.PackOff.Clear(); deck.SaveState(); RefreshMenu(); });
            subjects.DropDownItems.Add("모두 끄기", null, (s, e) =>
            {
                deck.PackOff = new HashSet<string>(deck.Topics);
                deck.SaveState();
                RefreshMenu();
            });
            subjects.DropDownItems.Add(new ToolStripSeparator());
            foreach (string topic in deck.Topics)
            {
                string t = topic;
                var item = new ToolStripMenuItem(t + " (" + deck.CountOf(t) + ")") { Checked = !deck.PackOff.Contains(t) };
                item.Click += (s, e) =>
                {
                    if (!deck.PackOff.Remove(t)) deck.PackOff.Add(t);
                    deck.SaveState();
                    item.Checked = !deck.PackOff.Contains(t);
                    statusItem.Text = (hookOn ? "작동 중" : "키 감지를 켜지 못함") + " · 출제 범위 " + deck.ActiveCount + "문제";
                };
                subjects.DropDownItems.Add(item);
            }
        }

        void Notify(string text)
        {
            tray.ShowBalloonTip(4000, "Loading Dose", text, ToolTipIcon.Info);
        }

        void EditOwn()
        {
            try
            {
                deck.EnsureOwnFile();
                Process.Start("notepad.exe", "\"" + Deck.OwnFile + "\"");
            }
            catch (Exception e) { Notify("파일을 열지 못했습니다: " + e.Message); }
        }

        static void OpenPath(string path)
        {
            try
            {
                if (!File.Exists(path)) File.WriteAllText(path, "");
                Process.Start("notepad.exe", "\"" + path + "\"");
            }
            catch { }
        }

        void Quit()
        {
            tray.Visible = false;
            keys.Dispose();
            ExitThread();
        }

        // ── 진단 ──
        void CopyDiagnostics()
        {
            IntPtr hwnd = lastTarget;
            string name = lastTargetName;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var sb = new StringBuilder();
                sb.AppendLine("Loading Dose 진단 정보 (보내기 전에 내용을 한 번 확인하세요. 버튼 이름에 대화 제목이 섞일 수 있습니다.)");
                sb.AppendLine("버전 " + Config.Version + " / Windows " + Environment.OSVersion.Version + " / 64비트 프로세스 " + Environment.Is64BitProcess);
                sb.AppendLine("키 감지 " + (hookOn ? "켜짐" : "꺼짐") + " / 대상 " + string.Join(",", Config.Targets)
                    + " / 중지 단어 " + string.Join(",", Config.StopWords));
                sb.AppendLine("마지막 판독: " + lastScan);
                try
                {
                    var related = Process.GetProcesses().Select(p => p.ProcessName)
                        .Where(n => n.IndexOf("claude", StringComparison.OrdinalIgnoreCase) >= 0
                                 || n.IndexOf("gpt", StringComparison.OrdinalIgnoreCase) >= 0)
                        .Distinct().ToList();
                    sb.AppendLine("실행 중인 관련 프로세스: " + (related.Count > 0 ? string.Join(", ", related) : "없음"));
                }
                catch { }
                if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd))
                    sb.AppendLine("대상 앱 창을 아직 보지 못했습니다. Claude나 ChatGPT 앱 창을 한 번 앞으로 가져온 뒤 다시 눌러 주세요.");
                else
                {
                    sb.AppendLine("대상 창 프로세스: " + name);
                    sb.AppendLine(Scanner.Dump(hwnd));
                }
                string text = sb.ToString();
                try
                {
                    ui.BeginInvoke((Action)(() =>
                    {
                        try { Clipboard.SetText(text); Notify("진단 정보를 복사했습니다. 붙여넣어 보내 주세요."); }
                        catch (Exception e) { Notify("복사하지 못했습니다: " + e.Message); }
                    }));
                }
                catch { }
            });
        }

        // 대상 앱 창이 앞에 있으면 기억해 두고, 화면 요소를 내보내도록 한 번 읽어 깨워 둔다.
        void Watch()
        {
            IntPtr hwnd = Native.GetForegroundWindow();
            string name = Native.ProcessName(hwnd);
            if (!Config.IsTarget(name)) return;
            bool first = hwnd != lastTarget;
            lastTarget = hwnd;
            lastTargetName = name;
            if (first && phase == Phase.Idle)
            {
                Log.Write("대상 앱 창 확인: " + name);
                Scanner.FindStop(hwnd, (found, label, count, ms) =>
                    Log.Write("준비 판독: " + name + " 버튼 " + count + "개 found=" + found + " ms=" + ms));
            }
        }

        // ── 흐름: Enter → 카드 → 중지 버튼이 사라지면 끝 ──
        void OnEnterKey()
        {
            IntPtr hwnd = Native.GetForegroundWindow();
            string name = Native.ProcessName(hwnd);
            if (!Config.IsTarget(name)) return;
            lastTarget = hwnd;
            lastTargetName = name;
            if (phase != Phase.Idle) return;
            Log.Write("Enter: " + name + " → 카드 시작");
            Begin(hwnd, Screen.FromHandle(hwnd).WorkingArea);
        }

        void StartDemo()
        {
            if (phase != Phase.Idle) return;
            demoUntil = DateTime.Now.AddSeconds(8);
            Log.Write("카드 미리 보기");
            Begin(IntPtr.Zero, Screen.PrimaryScreen.WorkingArea);
        }

        void Begin(IntPtr hwnd, Rectangle screenArea)
        {
            phase = Phase.Pending;
            target = hwnd;
            startedAt = pendingAt = lastSeen = DateTime.Now;
            lastFound = false;
            ui.StartCard(screenArea);
        }

        int Elapsed { get { return (int)(DateTime.Now - startedAt).TotalSeconds; } }

        void Tick()
        {
            if (phase == Phase.Idle) return;
            ui.SetProgress(Elapsed);
            if (demoUntil != null) { Handle(DateTime.Now < demoUntil); return; }
            if (target == IntPtr.Zero || !Native.IsWindow(target)) { Finish(); return; }
            string name = lastTargetName;
            Scanner.FindStop(target, (found, label, count, ms) =>
            {
                try
                {
                    ui.BeginInvoke((Action)(() =>
                    {
                        lastScan = name + " 버튼 " + count + "개 found=" + found + (found ? " label=\"" + label + "\"" : "") + " ms=" + ms;
                        if (found != lastFound || label.StartsWith("ERR")) Log.Write("판독: " + lastScan);
                        lastFound = found;
                        Handle(found);
                    }));
                }
                catch { }
            });
        }

        void Handle(bool found)
        {
            if (phase == Phase.Idle) return;
            DateTime now = DateTime.Now;
            if (found && (now - startedAt).TotalSeconds < Config.HardCap)
            {
                lastSeen = now;
                if (phase != Phase.Streaming) Log.Write("생성 중으로 판단 (" + Elapsed + "초째)");
                phase = Phase.Streaming;
                return;
            }
            if (phase == Phase.Streaming && ((now - lastSeen).TotalSeconds > Config.EndGrace || found)) Finish();
            else if (phase == Phase.Pending && (now - pendingAt).TotalSeconds > Config.PendingTimeout) Finish();
        }

        void Finish()
        {
            bool wasStreaming = phase == Phase.Streaming;
            Log.Write(wasStreaming ? "끝: 답변 도착으로 판단 (" + Elapsed + "초)" : "끝: 중지 버튼을 못 찾고 시간 초과 (" + Elapsed + "초)");
            phase = Phase.Idle;
            demoUntil = null;
            if (!ui.Visible) return;
            if (!wasStreaming) { ui.HideCard(); return; }   // Enter 만 누르고 생성이 시작되지 않은 경우
            ui.MarkDone(Elapsed);
        }
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            bool created;
            using (var mutex = new Mutex(true, "LoadingDose.SingleInstance", out created))
            {
                if (!created)
                {
                    MessageBox.Show("Loading Dose 가 이미 실행 중입니다.\n작업 표시줄 오른쪽(숨겨진 아이콘 ^ 안)의 아이콘을 오른쪽 클릭하세요.",
                        "Loading Dose", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (s, e) => Log.Write("오류: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Write("치명적 오류: " + e.ExceptionObject);
                Application.Run(new TrayApp(args.Contains("--demo")));
                GC.KeepAlive(mutex);
            }
        }
    }
}
