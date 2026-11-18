// O/X 퀴즈 (Omogi Windows 판). 문항과 카드 화면은 Loading Dose Windows 판과 같은 방식이다.
// 문제가 뜨는 길은 둘이고, 둘 다 기본은 꺼져 있다:
//   Enter 감지 — Claude·ChatGPT Windows 앱에서 Enter 를 누르고 답을 기다리는 동안 카드가 뜬다.
//                키 입력과 그 앱의 "중지" 버튼 이름을 읽는다. 읽는 것은 어떤 키인지(Enter, Alt+O, Alt+X)뿐이고,
//                친 글자는 보지도 남기지도 않는다.
//   물어 오기   — 컴퓨터를 쓰는 동안 가끔 오모기가 문제를 물고 온다. 누르면 한 문제가 펼쳐진다.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using WinTimer = System.Windows.Forms.Timer;

namespace Omogi
{
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
                "# \"#\" 으로 시작하는 줄은 무시합니다. 저장한 뒤 메뉴의 \"내 문제 다시 읽기\"를 누르세요.\r\n" +
                "# 예) 급성 증상성 저칼슘혈증은 IV calcium gluconate로 치료한다. | O | 저마그네슘혈증이 동반되면 Mg도 보충한다.\r\n",
                new UTF8Encoding(true));
        }

        List<Card> Active()
        {
            var list = own.Concat(builtin.Where(c => !PackOff.Contains(c.Topic))).ToList();
            return list.Count > 0 ? list : builtin;
        }

        public int ActiveCount { get { return Active().Count; } }
        public int PackCount { get { return builtin.Count(c => !PackOff.Contains(c.Topic)); } }

        // 틀린 문제일수록 자주, 많이 맞힌 문제일수록 드물게 (Mac 판과 같은 가중치).
        public Card Pick()
        {
            List<Card> source = Active();
            if (source.Count == 0) return new Card { Q = "문제가 없습니다. 메뉴에서 과목을 켜 주세요.", A = true, Why = "", Topic = "" };
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

    // Enter 와 Alt+O / Alt+X 를 잡는다. 훅은 화면 스레드에 걸리므로 콜백도 화면 스레드에서 돈다.
    // 어떤 키인지만 보고, 친 글자는 보지도 남기지도 않는다.
    sealed class KeyHook : IDisposable
    {
        IntPtr hook = IntPtr.Zero;
        Native.HookProc proc;   // 가비지 수집되지 않게 붙잡아 둔다
        public Func<bool> CanAnswer;
        public Action<bool> OnAnswer;
        public Action OnEnter;

        public bool Installed { get { return hook != IntPtr.Zero; } }

        public bool Install()
        {
            if (hook != IntPtr.Zero) return true;
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
                        return (IntPtr)1;   // 다른 앱으로 넘기지 않는다
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
    // 화면 위 가운데에 뜨는 알약. 질문 카드로 펼쳐졌다가 다시 알약으로 접힌다.
    // 포커스를 뺏지 않는다 (입력 중인 창이 그대로 활성 상태로 남는다).
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
        static readonly Color BtnDim = Color.FromArgb(214, 211, 205);
        static readonly Color BtnO = Color.FromArgb(92, 191, 78);
        static readonly Color BtnX = Color.FromArgb(226, 69, 54);

        readonly Deck deck;
        public Func<bool> IsLoading = () => false;
        /// 카드가 떴을 때 / 답했을 때(맞혔는지) / 사라질 때
        public Action OnShow, OnHide;
        public Action<bool> OnAnswer;
        /// 혼자 푸는 카드의 머리줄에 그릴 얼굴 그림
        public Bitmap Face;

        Mode mode = Mode.Pill;
        bool done;
        int seconds;
        Card card;
        bool correct, picked;
        Rectangle area;
        Rectangle rO, rX, rNext, rClose;
        DateTime? nextAt, collapseAt, hideAt;
        float angle;
        string title = "";
        readonly WinTimer anim = new WinTimer { Interval = 40 };
        readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();

        /// 답변을 기다리는 것과 상관없이 문제 하나를 바로 펼쳤는지 (오모기가 물어 온 문제)
        public bool Standalone { get; private set; }

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
        public bool IsOpen { get { return Visible && mode != Mode.Pill; } }

        void Appear()
        {
            bool was = Visible;
            if (!was) Show();
            Native.RaiseTopmost(Handle);     // 크게 부푼 오모기보다 위에 있게
            anim.Start();
            if (OnShow != null) OnShow();
        }

        // ── 바깥에서 부르는 동작 ──
        /// AI 답변을 기다리는 동안의 카드
        public void StartCard(Rectangle screenArea)
        {
            area = screenArea;
            Standalone = false;
            done = false;
            seconds = 0;
            nextAt = collapseAt = hideAt = null;
            NewCard();
            Appear();
        }

        /// 문제 하나를 바로 펼친다. 답하면 해설을 읽을 시간을 두고 접히고, "다음 문제"를 누르면 이어서 풀 수 있다.
        public void ShowStandalone(string title, Rectangle screenArea)
        {
            area = screenArea;
            this.title = title;
            Standalone = true;
            done = true;
            seconds = 0;
            nextAt = hideAt = null;
            NewCard();
            collapseAt = DateTime.Now.AddSeconds(90);      // 안 풀고 두면 알아서 접힌다
            Appear();
        }

        public void SetProgress(int sec)
        {
            if (done || !Visible) return;
            if (sec != seconds) { seconds = sec; Invalidate(); }
        }

        public void Answer(bool pick)
        {
            if (!CanAnswer) return;
            picked = pick;
            correct = pick == card.A;
            deck.Record(card, correct);
            mode = Mode.Graded;
            collapseAt = null;
            // 답변을 기다리는 중이면 곧 다음 문제로, 아니면 해설을 읽을 시간을 두고 접는다.
            nextAt = DateTime.Now.AddSeconds(IsLoading() ? 4.0 : Standalone ? 12 : 2.5);
            Relayout();
            if (OnAnswer != null) OnAnswer(correct);
        }

        public void MarkDone(int sec)
        {
            if (!Visible) return;
            done = true;
            seconds = sec;
            if (mode == Mode.Ask) collapseAt = DateTime.Now.AddSeconds(6);     // 풀던 문제는 마저 풀 수 있게 잠깐 남겨 둔다
            else if (mode == Mode.Pill) hideAt = DateTime.Now.AddSeconds(2.5);
            else nextAt = DateTime.Now.AddSeconds(2.5);
            Relayout();
        }

        public void HideCard()
        {
            nextAt = collapseAt = hideAt = null;
            anim.Stop();
            if (!Visible) return;
            Hide();
            if (OnHide != null) OnHide();
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
            hideAt = DateTime.Now.AddSeconds(Standalone ? 1.6 : 2.5);
            Relayout();
        }

        // 동작 확인용: 지금 모습을 PNG 로 저장한다.
        public void Snapshot(string path)
        {
            using (var bmp = new Bitmap(Width, Height))
            {
                DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
        }

        public void CollapseNow() { Collapse(); }
        public bool CurrentAnswer { get { return card != null && card.A; } }

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
        /// 화면 배율 (100% 화면에서 1)
        public float UiScale { get { return S; } }

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
                if (Standalone)
                {
                    if (Face != null)
                    {
                        var old = g.InterpolationMode;
                        g.InterpolationMode = InterpolationMode.NearestNeighbor;
                        g.PixelOffsetMode = PixelOffsetMode.Half;
                        int fh = Px(22), fw = fh * Face.Width / Math.Max(1, Face.Height);
                        g.DrawImage(Face, new Rectangle(pad - Px(1), Px(11), fw, fh));
                        g.InterpolationMode = old;
                        g.PixelOffsetMode = PixelOffsetMode.Default;
                    }
                }
                else if (done)
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
                string head = Standalone ? title : done ? "답변 도착 · " + seconds + "초" : "답변 생성 중 · " + seconds + "초";
                Draw(g, head, F(14, FontStyle.Bold), !Standalone && done ? Green : Color.FromArgb(58, 58, 60),
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
                // 채점 뒤: 정답 버튼이 초록으로, 잘못 고른 버튼이 빨강으로 채워진다.
                Color cO = BtnIdle, cX = BtnIdle, tO = Ink, tX = Ink;
                if (graded)
                {
                    cO = card.A ? BtnO : (picked ? BtnX : BtnDim);
                    cX = !card.A ? BtnO : (!picked ? BtnX : BtnDim);
                    tO = cO == BtnDim ? Faint : Color.White;
                    tX = cX == BtnDim ? Faint : Color.White;
                }
                Fill(g, rO, Px(10), cO);
                Fill(g, rX, Px(10), cX);
                Font bf = F(18, FontStyle.Bold);
                Draw(g, "O", bf, tO, rO, StringAlignment.Center, StringAlignment.Center);
                Draw(g, "X", bf, tX, rX, StringAlignment.Center, StringAlignment.Center);
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
            else if (mode == Mode.Graded && rNext.Contains(e.Location)) NextNow();
        }

        /// "다음 문제"를 눌렀을 때
        public void NextNow()
        {
            if (!Visible || mode != Mode.Graded) return;
            nextAt = null;
            if (IsLoading()) NewCard();
            else if (Standalone) { NewCard(); collapseAt = DateTime.Now.AddSeconds(90); }
            else Collapse();
        }
    }

    // ───────────────────── 언제 문제를 띄울지 ─────────────────────
    // 로딩을 판단하는 흐름은 Loading Dose 와 같다: Enter → 대상 앱 창에 "중지" 버튼이 보이는 동안을 생성 중으로 본다.
    sealed class QuizWatcher
    {
        enum Phase { Idle, Pending, Streaming }

        public readonly Deck Deck = new Deck();
        public readonly QuizForm Ui;
        readonly Pet pet;
        readonly KeyHook keys = new KeyHook();
        readonly WinTimer tick = new WinTimer { Interval = 400 };
        readonly WinTimer slow = new WinTimer { Interval = 2000 };

        Phase phase = Phase.Idle;
        IntPtr target = IntPtr.Zero;
        DateTime startedAt, pendingAt, lastSeen;
        DateTime nextBring;
        bool lastFound;
        IntPtr lastTarget = IntPtr.Zero;
        string lastTargetName = "", lastOther = "";
        bool started, hookFailed;

        /// Enter 감지가 실제로 돌고 있는지
        public bool Watching { get { return Settings.QuizEnterOn && keys.Installed; } }
        public bool HookFailed { get { return hookFailed; } }

        public QuizWatcher(Pet pet)
        {
            this.pet = pet;
            Ui = new QuizForm(Deck);
            IntPtr force = Ui.Handle;   // 창 핸들을 미리 만든다
            Ui.IsLoading = () => phase != Phase.Idle;
            Ui.Face = pet.FaceImage(22);
            // 카드가 뜨면 오모기가 카드 왼쪽 위에 와서 앉고, 정답·오답에 반응한다.
            pet.PerchTarget = () =>
            {
                if (!Ui.IsOpen) return null;
                float s = Ui.UiScale;
                return new PointF(Ui.Left - 34 * s, Ui.Top + 60 * s);
            };
            Ui.OnShow = () => { UpdateHook(); pet.GoToCard(); };
            Ui.OnAnswer = correct => pet.React(correct);
            Ui.OnHide = () => { UpdateHook(); pet.GoHome(); };
            pet.OnQuizOpen = SolveOne;
            keys.CanAnswer = () => Ui.CanAnswer;
            keys.OnAnswer = pick => Ui.BeginInvoke((Action)(() => Ui.Answer(pick)));
            keys.OnEnter = () => Ui.BeginInvoke((Action)OnEnterKey);
            nextBring = DateTime.Now.AddMinutes(Config.QuizBringMinutes);
        }

        public void Start()
        {
            if (started) return;
            started = true;
            tick.Tick += (s, e) => Tick();
            tick.Start();
            slow.Tick += (s, e) => Housekeeping();
            slow.Start();
            Housekeeping();
        }

        public void Stop()
        {
            tick.Stop();
            slow.Stop();
            keys.Dispose();
        }

        /// 지금 한 문제를 펼친다 (오모기가 물어 온 문제를 눌렀을 때, 메뉴에서 골랐을 때).
        public void SolveOne()
        {
            if (phase != Phase.Idle) return;       // 답변을 기다리는 카드가 떠 있으면 그대로 둔다
            Ui.ShowStandalone("오모기가 물어 온 문제", Screen.FromPoint(Cursor.Position).WorkingArea);
            nextBring = DateTime.Now.AddMinutes(Config.QuizBringMinutes);
        }

        // 키 감지는 필요할 때만 켠다: Enter 감지를 켜 두었거나, 카드가 떠 있어서 Alt+O / Alt+X 를 받아야 할 때.
        public void UpdateHook()
        {
            bool want = Settings.QuizEnterOn || Ui.Visible;
            if (want && !keys.Installed)
            {
                hookFailed = !keys.Install();
                Log.Write("퀴즈: 키 감지 " + (hookFailed ? "를 켜지 못함" : "켬"));
            }
            else if (!want && keys.Installed)
            {
                keys.Dispose();
                Log.Write("퀴즈: 키 감지 끔");
            }
        }

        // 2초마다: 설정에 맞춰 키 감지를 켜고 끄고, 대상 앱 창을 기억해 두고, 물어 올 때가 됐는지 본다.
        void Housekeeping()
        {
            UpdateHook();
            if (Settings.QuizEnterOn)
            {
                IntPtr hwnd = Native.GetForegroundWindow();
                string name = Native.ProcessName(hwnd);
                if (Config.IsTarget(name))
                {
                    bool first = hwnd != lastTarget;
                    lastTarget = hwnd;
                    lastTargetName = name;
                    if (first && phase == Phase.Idle)
                    {
                        // 화면 요소를 내보내도록 한 번 읽어 깨워 둔다.
                        Log.Write("퀴즈: 대상 앱 창 확인 " + name);
                        Scanner.FindStop(hwnd, (found, label, count, ms) =>
                            Log.Write("퀴즈 준비 판독: " + name + " 버튼 " + count + "개 found=" + found + " ms=" + ms));
                    }
                }
            }
            if (!Settings.QuizBringOn) { nextBring = DateTime.Now.AddMinutes(Config.QuizBringMinutes); return; }
            // 컴퓨터를 쓰고 있고, 카드도 편지도 없을 때만 물어 온다.
            if (DateTime.Now >= nextBring && phase == Phase.Idle && !Ui.Visible && Native.IdleSeconds() < 120 && !pet.IsHoldingMail
                && pet.BringQuiz("O/X 한 문제 풀래요? — 눌러서 풀기"))
            {
                nextBring = DateTime.Now.AddMinutes(Config.QuizBringMinutes);
                Log.Write("퀴즈: 오모기가 문제를 물어 옴");
            }
        }

        // ── 흐름: Enter → 카드 → 중지 버튼이 사라지면 끝 ──
        void OnEnterKey()
        {
            if (!Settings.QuizEnterOn) return;
            IntPtr hwnd = Native.GetForegroundWindow();
            string name = Native.ProcessName(hwnd);
            if (!Config.IsTarget(name))
            {
                if (name != lastOther) { lastOther = name; Log.Write("퀴즈 Enter: 대상 앱이 아님 (" + name + ")"); }
                return;
            }
            lastOther = "";
            lastTarget = hwnd;
            lastTargetName = name;
            if (phase != Phase.Idle) return;
            // Loading Dose 가 같이 켜져 있으면 그쪽 카드가 같은 자리에 뜨므로 양보한다.
            if (Native.AnotherInstance("LoadingDose"))
            {
                Log.Write("퀴즈 Enter: Loading Dose 가 켜져 있어 카드를 띄우지 않음");
                return;
            }
            Log.Write("퀴즈 Enter: " + name + " → 카드 시작");
            phase = Phase.Pending;
            target = hwnd;
            startedAt = pendingAt = lastSeen = DateTime.Now;
            lastFound = false;
            Ui.StartCard(Screen.FromHandle(hwnd).WorkingArea);
        }

        int Elapsed { get { return (int)(DateTime.Now - startedAt).TotalSeconds; } }

        void Tick()
        {
            if (phase == Phase.Idle) return;
            Ui.SetProgress(Elapsed);
            if (target == IntPtr.Zero || !Native.IsWindow(target)) { Finish(); return; }
            string name = lastTargetName;
            Scanner.FindStop(target, (found, label, count, ms) =>
            {
                try
                {
                    Ui.BeginInvoke((Action)(() =>
                    {
                        if (found != lastFound || label.StartsWith("ERR"))
                            Log.Write("퀴즈 판독: " + name + " 버튼 " + count + "개 found=" + found + " ms=" + ms);
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
                if (phase != Phase.Streaming) Log.Write("퀴즈: 생성 중으로 판단 (" + Elapsed + "초째)");
                phase = Phase.Streaming;
                return;
            }
            if (phase == Phase.Streaming && ((now - lastSeen).TotalSeconds > Config.EndGrace || found)) Finish();
            else if (phase == Phase.Pending && (now - pendingAt).TotalSeconds > Config.PendingTimeout) Finish();
        }

        void Finish()
        {
            bool wasStreaming = phase == Phase.Streaming;
            Log.Write(wasStreaming ? "퀴즈 끝: 답변 도착으로 판단 (" + Elapsed + "초)" : "퀴즈 끝: 중지 버튼을 못 찾고 시간 초과 (" + Elapsed + "초)");
            phase = Phase.Idle;
            if (!Ui.Visible) return;
            if (!wasStreaming) { Ui.HideCard(); return; }   // Enter 만 누르고 생성이 시작되지 않은 경우
            Ui.MarkDone(Elapsed);
        }

        /// 진단 정보에 넣을 한 줄
        public string Diagnostics(out IntPtr hwnd)
        {
            hwnd = lastTarget;
            return "키 감지 " + (keys.Installed ? "켜짐" : "꺼짐") + " / 대상 " + string.Join(",", Config.Targets)
                + " / 중지 단어 " + string.Join(",", Config.StopWords) + " / 마지막 대상 창 " + (lastTargetName.Length > 0 ? lastTargetName : "없음");
        }
    }
}
