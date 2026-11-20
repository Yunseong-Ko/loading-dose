// 화면 아래 가장자리(작업 표시줄 위)에 사는 작은 펫 (흰오목눈이, 픽셀 스프라이트). Mac 판 omogi/pet.swift 를 옮긴 것.
// 평소에는 앉아 있거나 콩콩 뛰어 옮겨 가거나 졸고, 습관 알림·편지 심부름·문제 물어 오기를 맡는다.
// O/X 카드가 뜨면 카드 옆으로 날아가 정답·오답에 반응하고, 연속으로 맞히면 몸이 커지다가 펑 터진다.
// 그림은 tools/make_pet_sprites.py 가 만든 omogi/pet/sprites.png (36x28 픽셀 프레임을 가로로 이어 붙인 것).
// 좌표는 Windows 화면 좌표(아래로 갈수록 y 가 커진다)이고, 펫의 위치는 발바닥 가운데다.
// Mac 판에 있는 집중 모드 출동과 일정 알림은 이 판에 없다.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;
using WinTimer = System.Windows.Forms.Timer;

namespace Omogi
{
    /// 픽셀마다 투명도가 있는 테두리 없는 창. 투명한 곳은 클릭이 그대로 통과하고, 포커스를 가져가지 않는다.
    class LayerWindow : Form
    {
        readonly bool clickThrough;

        public LayerWindow(bool clickThrough)
        {
            this.clickThrough = clickThrough;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            TopMost = true;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00080000 /* LAYERED */ | 0x00000080 /* TOOLWINDOW */ | 0x08000000 /* NOACTIVATE */ | 0x00000008 /* TOPMOST */;
                if (clickThrough) cp.ExStyle |= 0x00000020 /* TRANSPARENT */;
                return cp;
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x21 /* WM_MOUSEACTIVATE */) { m.Result = (IntPtr)3; return; }   // 눌러도 활성화하지 않는다
            base.WndProc(ref m);
        }

        /// 그림과 위치를 한 번에 바꾼다.
        public void Present(Bitmap image, int x, int y)
        {
            IntPtr screen = Native.GetDC(IntPtr.Zero);
            IntPtr mem = Native.CreateCompatibleDC(screen);
            IntPtr hbmp = IntPtr.Zero, old = IntPtr.Zero;
            try
            {
                hbmp = image.GetHbitmap(Color.FromArgb(0));
                old = Native.SelectObject(mem, hbmp);
                var size = new Native.SIZE(image.Width, image.Height);
                var src = new Native.POINT(0, 0);
                var dst = new Native.POINT(x, y);
                var blend = new Native.BLENDFUNCTION { Op = 0, Flags = 0, Alpha = 255, Format = 1 /* AC_SRC_ALPHA */ };
                Native.UpdateLayeredWindow(Handle, screen, ref dst, ref size, mem, ref src, 0, ref blend, 2 /* ULW_ALPHA */);
            }
            finally
            {
                Native.ReleaseDC(IntPtr.Zero, screen);
                if (hbmp != IntPtr.Zero)
                {
                    Native.SelectObject(mem, old);
                    Native.DeleteObject(hbmp);
                }
                Native.DeleteDC(mem);
            }
        }

        /// 불투명한 곳까지 클릭이 통과하게 할지 (몸이 크게 부풀어 카드를 덮을 때 쓴다).
        public void SetClickThrough(bool on)
        {
            int style = Native.GetWindowLong(Handle, -20 /* GWL_EXSTYLE */);
            int want = on ? style | 0x20 : style & ~0x20;
            if (want != style) Native.SetWindowLong(Handle, -20, want);
        }

        public void MoveTo(int x, int y)
        {
            Native.SetWindowPos(Handle, IntPtr.Zero, x, y, 0, 0, 0x0001 /* NOSIZE */ | 0x0004 /* NOZORDER */ | 0x0010 /* NOACTIVATE */);
        }
    }

    /// 펫 창: 몸(불투명한 픽셀)을 누르면 집히고, 오른쪽 클릭하면 메뉴가 뜬다.
    sealed class PetWindow : LayerWindow
    {
        public Action OnDown, OnUp;
        public ContextMenuStrip PopupMenu;

        public PetWindow() : base(false) { }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left)
            {
                Capture = true;
                if (OnDown != null) OnDown();
            }
            else if (e.Button == MouseButtons.Right && PopupMenu != null)
            {
                Native.SetForegroundWindow(Handle);     // 메뉴 밖을 누르면 닫히게
                PopupMenu.Show(Cursor.Position);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button == MouseButtons.Left)
            {
                Capture = false;
                if (OnUp != null) OnUp();
            }
        }
    }

    /// 한 줄짜리 말풍선 (무슨 알림인지 알려 준다). 클릭은 통과한다.
    sealed class Bubble : Form
    {
        string text = "";
        readonly Font font;
        readonly float scale;

        public Bubble(float scale)
        {
            this.scale = scale;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            TopMost = true;
            BackColor = Color.FromArgb(250, 247, 242);
            Opacity = 0.97;
            font = new Font("Malgun Gothic", 12.5f * scale, FontStyle.Bold, GraphicsUnit.Pixel);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080 /* TOOLWINDOW */ | 0x08000000 /* NOACTIVATE */ | 0x00000008 /* TOPMOST */ | 0x00000020 /* TRANSPARENT */;
                return cp;
            }
        }

        static GraphicsPath Round(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            int d = radius * 2;
            path.AddArc(r.Left, r.Top, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public void SetText(string s)
        {
            text = s ?? "";
            int w = TextRenderer.MeasureText(text, font).Width + (int)(22 * scale);
            w = Math.Min((int)(300 * scale), w);
            Size = new Size(w, (int)(27 * scale));
            using (GraphicsPath p = Round(new Rectangle(0, 0, Width, Height), (int)(10 * scale))) Region = new Region(p);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(Color.FromArgb(205, 200, 192), 2))
            using (GraphicsPath p = Round(new Rectangle(0, 0, Width - 1, Height - 1), (int)(10 * scale)))
                e.Graphics.DrawPath(pen, p);
            TextRenderer.DrawText(e.Graphics, text, font, new Rectangle((int)(8 * scale), 0, Width - (int)(16 * scale), Height),
                Color.FromArgb(41, 43, 51), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }

    /// 펑 터졌을 때 잠깐 나타나는 작은 새 한 마리. 튀어 나가 잠시 파닥이다가 화면 밖으로 날아간다.
    sealed class MiniBird
    {
        readonly LayerWindow win;
        bool caught;
        readonly Bitmap[] right, left;       // [hop, fly0, fly1, fly2, fly1] 을 오른쪽·왼쪽 보기로
        PointF pos, vel, from;               // 창의 가운데
        readonly double born, leaveAfter;
        readonly PointF exit;
        bool leaving;
        Bitmap shown;
        readonly float unit;

        /// onCatch 가 있으면 누를 수 있고, 눌리면 그 자리에서 사라진다(잡힘).
        public MiniBird(Bitmap[] right, Bitmap[] left, PointF start, PointF velocity, double now, double leaveAfter, PointF exit, float unit, Action onCatch = null)
        {
            win = new LayerWindow(onCatch == null);
            if (onCatch != null)
                win.MouseDown += (s, e) =>
                {
                    if (caught || e.Button != MouseButtons.Left) return;
                    caught = true;
                    try { win.Hide(); } catch { }
                    onCatch();
                };
            this.right = right;
            this.left = left;
            pos = start;
            vel = velocity;
            born = now;
            this.leaveAfter = leaveAfter;
            this.exit = exit;
            this.unit = unit;
            Place(0, velocity.X >= 0);
            win.Show();
        }

        void Place(int index, bool faceRight)
        {
            Bitmap b = (faceRight ? right : left)[index];
            int x = (int)Math.Round(pos.X - b.Width / 2f), y = (int)Math.Round(pos.Y - b.Height / 2f);
            if (b != shown) { shown = b; win.Present(b, x, y); }
            else win.MoveTo(x, y);
        }

        /// 한 틱 움직인다. 화면 밖으로 다 나갔으면 false.
        public bool Update(float dt, double now)
        {
            if (caught) { Remove(); return false; }
            double t = now - born;
            int wing = 1 + (int)(t * 14) % 4;
            if (t < leaveAfter)
            {
                // 튀어 나간 뒤 속도가 줄면서 그 자리에서 파닥인다.
                float drag = (float)Math.Exp(-3.2 * dt);
                vel = new PointF(vel.X * drag, vel.Y * drag);
                pos = new PointF(pos.X + vel.X * dt, pos.Y + vel.Y * dt - (float)Math.Sin(t * 9) * 0.6f * unit);
                Place(t < 0.3 ? 0 : wing, vel.X >= 0);
                return true;
            }
            if (!leaving) { leaving = true; from = pos; }
            float k = (float)Math.Min(1, (t - leaveAfter) / 1.3);
            float e = k * k;
            pos = new PointF(from.X + (exit.X - from.X) * e, from.Y + (exit.Y - from.Y) * e - (float)Math.Sin(k * Math.PI) * 40 * unit);
            Place(wing, exit.X >= from.X);
            if (k >= 1) { Remove(); return false; }
            return true;
        }

        public void Remove()
        {
            try { win.Hide(); win.Dispose(); } catch { }
        }
    }

    /// 놀러 온 친구의 새: 화면 밖에서 날아와 내 오모기 옆에 앉아 말풍선을 띄우고, 잠깐 좋아하다가 날아간다.
    sealed class Visitor
    {
        readonly LayerWindow win = new LayerWindow(true);
        readonly Bubble note;
        readonly Bitmap[] flyIn, flyOut, happy;      // 올 때, 돌아갈 때, 앉아서 (내 오모기 쪽을 본다)
        readonly PointF from, land;                  // 발바닥 좌표
        readonly PointF feet;                        // 그림 왼쪽 위에서 발바닥까지
        readonly double born, stay;
        readonly float unit;
        readonly Rectangle area;
        Bitmap shown;
        const double Arrive = 1.3, Leave = 1.3;
        static readonly Random rng = new Random();

        // 놀다 가는 손님: 인사한 뒤 바닥을 이리저리 뛰어다니다가 돌아간다.
        readonly bool play;
        readonly Bitmap[] hopRight, hopLeft;         // play 일 때만 있다
        readonly Bitmap sitRight, sitLeft;
        readonly float lo, hi;                       // 뛰어다니는 범위 (발바닥 x)
        float curX;
        float? target;
        double restUntil, last;
        bool facing;                                 // 오른쪽을 보는지

        public Visitor(Bitmap[] flyIn, Bitmap[] flyOut, Bitmap[] happy, PointF feet, PointF from, PointF land, string text,
                       double stay, double now, float unit, Rectangle area,
                       bool play = false, Bitmap[] hopRight = null, Bitmap[] hopLeft = null, Bitmap sitRight = null, Bitmap sitLeft = null,
                       float lo = 0, float hi = 0)
        {
            this.play = play && hopRight != null && hopLeft != null && sitRight != null && sitLeft != null;
            this.hopRight = hopRight;
            this.hopLeft = hopLeft;
            this.sitRight = sitRight;
            this.sitLeft = sitLeft;
            this.lo = lo;
            this.hi = Math.Max(lo, hi);
            curX = land.X;
            facing = from.X >= land.X;                // 처음에는 인사하던 쪽(날아온 쪽의 반대)을 본다
            last = now;
            this.flyIn = flyIn;
            this.flyOut = flyOut;
            this.happy = happy;
            this.feet = feet;
            this.from = from;
            this.land = land;
            this.stay = stay;
            this.unit = unit;
            this.area = area;
            born = now;
            note = new Bubble(unit);
            note.SetText(text);
            Place(flyIn[0], from);
            win.Show();
        }

        void Place(Bitmap b, PointF at)
        {
            int x = (int)Math.Round(at.X - feet.X), y = (int)Math.Round(at.Y - feet.Y);
            if (b != shown) { shown = b; win.Present(b, x, y); }
            else win.MoveTo(x, y);
        }

        /// 한 틱 움직인다. 다 날아갔으면 false.
        public bool Update(double now)
        {
            double t = now - born;
            if (t < Arrive)
            {
                float k = (float)(t / Arrive), e = 1 - (1 - k) * (1 - k);
                Place(flyIn[(int)(t * 14) % flyIn.Length],
                    new PointF(from.X + (land.X - from.X) * e, from.Y + (land.Y - from.Y) * e - (float)Math.Sin(k * Math.PI) * 30 * unit));
            }
            else if (play && t < Arrive + stay && t - Arrive > 4)
            {
                if (note.Visible) note.Hide();
                float dt = (float)Math.Min(0.2, Math.Max(0, now - last));
                if (target != null)
                {
                    float step = dt * 70 * unit, dx = target.Value - curX;
                    facing = dx > 0;
                    if (Math.Abs(dx) <= step) { curX = target.Value; target = null; restUntil = now + 1.2 + rng.NextDouble() * 2.3; }
                    else curX += dx > 0 ? step : -step;
                    double ph = (now * 3) % 1;
                    Bitmap[] hop = facing ? hopRight : hopLeft;
                    Place(hop[Math.Min(hop.Length - 1, (int)(ph * hop.Length))], new PointF(curX, land.Y - (float)Math.Sin(ph * Math.PI) * 10 * unit));
                }
                else
                {
                    Place(facing ? sitRight : sitLeft, new PointF(curX, land.Y));
                    if (now >= restUntil && !Native.ReduceMotion()) target = lo + (float)rng.NextDouble() * (hi - lo);
                }
            }
            else if (t < Arrive + stay)
            {
                double u = t - Arrive;
                float hop = (float)Math.Abs(Math.Sin(u * 6)) * 8 * unit;
                Place(happy[(int)(u * 5) % happy.Length], new PointF(land.X, land.Y - hop));
                if (!note.Visible)
                {
                    float x = Math.Min(area.Right - note.Width - 6, Math.Max(area.Left + 6, land.X - note.Width / 2f));
                    note.Location = new Point((int)Math.Round(x), Math.Max(area.Top + 2, (int)Math.Round(land.Y - 66 * unit - note.Height)));
                    note.Show();
                }
            }
            else if (t < Arrive + stay + Leave)
            {
                if (note.Visible) note.Hide();
                float k = (float)((t - Arrive - stay) / Leave), e = k * k;
                Place(flyOut[(int)(t * 14) % flyOut.Length],
                    new PointF(curX + (from.X - curX) * e, land.Y + (from.Y - land.Y) * e - (float)Math.Sin(k * Math.PI) * 30 * unit));
            }
            else
            {
                Remove();
                return false;
            }
            last = now;
            return true;
        }

        public void Remove()
        {
            try { note.Hide(); note.Dispose(); } catch { }
            try { win.Hide(); win.Dispose(); } catch { }
            IEnumerable<Bitmap> all = flyIn.Concat(flyOut).Concat(happy);
            if (hopRight != null) all = all.Concat(hopRight);
            if (hopLeft != null) all = all.Concat(hopLeft);
            foreach (Bitmap b in all.Concat(new[] { sitRight, sitLeft }).Where(x => x != null).Distinct().ToList()) b.Dispose();
        }
    }

    /// 마을 마당에 그릴 그림들 (주어진 옷을 입힌 채로, 본래 크기 그대로 오른쪽 보기).
    sealed class YardSprites : IDisposable
    {
        public Bitmap Sit, Blink;
        public Bitmap[] Hop, Read, Sleep;
        public int W, H;

        public void Dispose()
        {
            foreach (Bitmap b in new[] { Sit, Blink }.Concat(Hop).Concat(Read).Concat(Sleep)) if (b != null) b.Dispose();
        }
    }

    sealed class Pet : ICourier
    {
        // 순서는 tools/make_pet_sprites.py 의 FRAMES 와 같아야 한다.
        enum F
        {
            Sit0, Sit1, Blink, Hop0, Hop1, Hop2, Fly0, Fly1, Fly2, Happy0, Happy1, Sad, Sleep0, Sleep1,
            Front, FrontBlink, Tilt,
            Nod1, Nod2, Roll1, Roll2, Roll3,
            Build1, Build2, Nest0, Nest1, Drink0, Drink1, Drink2,
            Stretch, Cal0, Cal1,
            MailFly0, MailFly1, MailFly2, Mail0, Mail1,
            Read0, Read1,
            Count
        }

        enum Mode
        {
            Sit, Hop, Sleep, FlyOut, Perch, FlyHome, Roam, Roll, Held, Fall, Nest, Drink, Eyes, Stretch,
            Tumble,                                  // 던져져서 바닥을 구르는 중
            Depart, Away, Arrive, Mail, Lost         // 편지 심부름: 화면 밖으로 나감 → 밖에 있음 → 돌아옴 → 물고 기다림 / 잃어버림
        }

        enum Errand { Send, Receive }

        const int FrameW = 36, FrameH = 28;
        const float FeetPx = 18;                     // 스프라이트 안에서 발 가운데의 x (한가운데라 뒤집어도 제자리)
        const float FloorInset = 1;                  // 스프라이트 아래 끝에서 발바닥까지 (스프라이트 픽셀)
        const double HopPeriod = 0.54;               // 웅크림 → 공중 → 착지 → 잠깐 멈춤
        const double NodPeriod = 3.4;                // 꾸벅 한 번: 버팀 → 고개가 떨어짐 → 푹 숙임 → 화들짝
        const double RollTime = 0.9;
        const int PopStreak = 5;

        readonly int zoom;                           // 스프라이트 1픽셀 = 화면 몇 픽셀 (배율 100% 화면에서 3)
        readonly float U;                            // Mac 판의 1포인트에 해당하는 화면 픽셀 수
        float HopStep { get { return 16 * U; } }
        float RollDistance { get { return 130 * U; } }

        readonly PetWindow win = new PetWindow();
        readonly Bubble bubble;
        readonly List<Bitmap> frames = new List<Bitmap>();
        readonly Dictionary<int, Bitmap> cache = new Dictionary<int, Bitmap>();   // 본래 크기로 키운 프레임 (프레임*2 + 왼쪽 보기)
        readonly WinTimer timer = new WinTimer();
        readonly Stopwatch clock = Stopwatch.StartNew();
        static readonly Random rng = new Random();

        double Now { get { return clock.Elapsed.TotalSeconds; } }
        static double Rand(double lo, double hi) { return lo + rng.NextDouble() * (hi - lo); }
        static bool Coin() { return rng.Next(2) == 0; }

        Mode mode = Mode.Sit;
        PointF pos;                                  // 발바닥 가운데의 화면 좌표
        bool faceRight = true;
        double modeStart;
        PointF from, to;
        double duration = 1;
        int hops;
        float arc;                                   // 날 때 솟는 높이
        double lookUntil, tiltAt;                    // 정면을 보는 동안, 그중 고개를 기우뚱하는 때
        double rollAt = double.PositiveInfinity;     // 졸다가 구르는 때 (잠든 뒤 몇 초째)
        double nextAction, nextBlink, blinkUntil;
        double reactStart, reactUntil;
        bool reactHappy;
        float homeX;
        int sitsInARow;
        bool shown;
        PointF grab;                                 // 집었을 때 마우스와 발 사이의 거리
        float fallSpeed;                             // 아래로 떨어지는 속도 (픽셀/초)
        double lastTick;
        double nextDrink, nextEye, nextStretch, lastNudge, nestHold;
        double bubbleUntil;

        // 편지 심부름
        Errand errand = Errand.Send;
        bool carrying;                               // 지금 부리에 편지가 있는지
        Screen errandScreen;
        string mailText = "";                        // 물고 기다리는 동안의 말풍선
        bool heldFromMail;                           // 물고 있다가 집힌 경우
        double downAt;
        Point downPos;
        bool holdingQuiz;                            // 물고 있는 것이 편지가 아니라 문제인지

        /// 편지를 물고 기다리는 펫을 눌렀을 때
        public Action OnMailOpen;
        /// 문제를 물고 기다리는 펫을 눌렀을 때
        public Action OnQuizOpen;
        /// 카드 옆에 앉을 자리(발바닥 좌표). 카드가 없으면 null.
        public Func<PointF?> PerchTarget;
        /// 연속 정답에 몸이 커지다가 터지는 동작을 할지
        public bool ComboGrowth = true;

        // 던지기: 집은 채로 빠르게 움직이다 놓으면 그 속도로 날아가 바닥을 구른다.
        PointF heldVel;                              // 집힌 동안의 속도 (픽셀/초, 부드럽게 평균 낸 값)
        float throwVX;                               // 던져진 뒤의 가로 속도
        float rollPhase;                             // 구른 거리(자세를 고르는 데 쓴다)

        // 연속 정답: 맞힐수록 몸이 커지다가 다섯 번째에 펑 터져 여러 마리가 되고, 곧 한 마리만 남는다.
        int streak;
        float growth = 1, growthTarget = 1;
        double popAt;                                // 터질 때 (0 이면 예정 없음)
        readonly List<MiniBird> minis = new List<MiniBird>();
        Bitmap[] miniRight, miniLeft;
        readonly List<Visitor> visitors = new List<Visitor>();
        bool studying;

        /// 공부 중: 앉아 있을 때 책을 보고, 혼자 돌아다니지 않는다.
        public bool Studying
        {
            get { return studying; }
            set { if (studying != value) { studying = value; Retime(); } }
        }
        public int VisitorCount { get { return visitors.Count; } }

        // 지금 창에 올라가 있는 그림과 자리
        int shownKey = -1;
        Size shownSize;
        Point shownAt = new Point(int.MinValue, int.MinValue);
        Rectangle winRect;

        public bool IsShown { get { return shown; } }
        public ContextMenuStrip Menu { get { return win.PopupMenu; } set { win.PopupMenu = value; } }
        public bool IsHoldingMail
        {
            get { return mode == Mode.Mail || heldFromMail || (errand == Errand.Receive && (mode == Mode.Depart || mode == Mode.Away || mode == Mode.Arrive)); }
        }

        public Pet()
        {
            float dpi = 96;
            try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX; } catch { }
            zoom = Math.Max(2, (int)Math.Round(3 * dpi / 96f));
            U = zoom / 3f;
            bubble = new Bubble(U);
            LoadFrames();
            LoadWear();
            win.OnDown = PickUp;
            win.OnUp = Drop;
            timer.Tick += (s, e) => { try { Tick(); } catch (Exception ex) { Log.Write("펫 오류: " + ex); } };
            double now = Now;
            nextDrink = now + Config.WaterMinutes * 60;
            nextEye = now + Config.EyeMinutes * 60;
            nextStretch = now + Config.StretchMinutes * 60;
        }

        void LoadFrames()
        {
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("sprites.png"))
                {
                    if (s == null) { Log.Write("펫 그림을 찾지 못함"); return; }
                    using (var sheet = new Bitmap(s))
                    {
                        int n = Math.Min((int)F.Count, sheet.Width / FrameW);
                        for (int i = 0; i < n; i++)
                            frames.Add(sheet.Clone(new Rectangle(i * FrameW, 0, FrameW, FrameH), PixelFormat.Format32bppArgb));
                    }
                }
            }
            catch (Exception e) { Log.Write("펫 그림을 읽지 못함: " + e.Message); }
        }

        public int FrameCount { get { return frames.Count; } }

        // ── 옷 ──
        // wear.png: 줄 = 물건, 칸 = 프레임. 맨몸 그림(bare) 위에 겹쳐 frames 를 다시 만든다.
        readonly List<Bitmap> bare = new List<Bitmap>();
        readonly List<Bitmap[]> wearRows = new List<Bitmap[]>();
        int[] worn = new int[0];
        /// 터져 나온 꼬마 뱁새를 눌러 잡았을 때 (있으면 꼬마들을 누를 수 있고, 조금 더 오래 머문다)
        public Action OnMiniCaught;
        public int WearCount { get { return wearRows.Count; } }
        public int[] Worn { get { return worn; } }

        void LoadWear()
        {
            bare.AddRange(frames);
            try
            {
                using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("wear.png"))
                {
                    if (s == null || bare.Count < (int)F.Count) return;
                    using (var sheet = new Bitmap(s))
                    {
                        for (int row = 0; row < sheet.Height / FrameH; row++)
                        {
                            var line = new Bitmap[(int)F.Count];
                            for (int i = 0; i < line.Length; i++)
                                line[i] = sheet.Clone(new Rectangle(i * FrameW, row * FrameH, FrameW, FrameH), PixelFormat.Format32bppArgb);
                            wearRows.Add(line);
                        }
                    }
                }
            }
            catch (Exception e) { Log.Write("옷 그림을 읽지 못함: " + e.Message); }
        }

        Bitmap Dressed(int i, int[] rows)
        {
            var b = new Bitmap(bare[i]);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.CompositingMode = CompositingMode.SourceOver;
                foreach (int row in rows)
                    if (row >= 0 && row < wearRows.Count) g.DrawImageUnscaled(wearRows[row][i], 0, 0);
            }
            return b;
        }

        /// 옷을 갈아입힌다 (wear.png 의 줄 번호들, 겹치는 순서대로).
        public void SetWear(int[] rows)
        {
            if (bare.Count == 0) return;
            worn = rows.Where(r => r >= 0 && r < wearRows.Count).ToArray();
            for (int i = 0; i < bare.Count; i++) frames[i] = worn.Length == 0 ? bare[i] : Dressed(i, worn);
            cache.Clear();
            shownKey = -1;                                   // 다음 틱에 새 그림으로 다시 올린다
        }

        /// 옷장 창에 보여 줄 앞모습 (주어진 옷을 입힌 채로, 한 픽셀을 scale 픽셀로)
        public Bitmap PreviewImage(int[] rows, int scale)
        {
            if ((int)F.Front >= bare.Count) return null;
            using (Bitmap small = Dressed((int)F.Front, rows))
            {
                var b = new Bitmap(FrameW * scale, FrameH * scale, PixelFormat.Format32bppArgb);
                using (Graphics g = Graphics.FromImage(b))
                using (var attr = new ImageAttributes())
                {
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    attr.SetWrapMode(WrapMode.TileFlipXY);
                    g.DrawImage(small, new Rectangle(0, 0, b.Width, b.Height), 0, 0, FrameW, FrameH, GraphicsUnit.Pixel, attr);
                }
                return b;
            }
        }

        /// 친구의 새가 놀러 온다: 그 친구가 입은 옷 그대로 날아와 옆에 앉고, 말풍선을 띄웠다가 돌아간다.
        /// play: 인사한 뒤 30초쯤 바닥을 뛰어다니다가 돌아간다.
        public void Visit(int[] rows, string text, bool play = false)
        {
            if (!shown || bare.Count < (int)F.Count || visitors.Count >= 3) return;      // 오모기를 숨겨 두었으면 손님도 오지 않는다
            Screen screen = CurrentScreen();
            Rectangle wa = screen.WorkingArea;
            // 내 오모기 옆자리 (화면 가운데 쪽), 이미 온 친구가 있으면 그만큼 더 옆으로
            float side = pos.X > wa.Left + wa.Width / 2f ? -1 : 1;
            var land = new PointF(Math.Min(wa.Right - 60 * U, Math.Max(wa.Left + 60 * U, pos.X + side * (76 + visitors.Count * 64) * U)), FloorY(screen));
            var from = new PointF(side < 0 ? wa.Left - 80 * U : wa.Right + 80 * U, wa.Bottom - wa.Height * 0.55f);
            int[] valid = (rows ?? new int[0]).Where(r => r >= 0 && r < wearRows.Count).ToArray();
            bool right = land.X >= from.X;
            int w = FrameW * zoom, h = FrameH * zoom;
            Func<F, bool, Bitmap> img = (f, r) =>
            {
                using (Bitmap small = Dressed((int)f, valid)) return ScaledImage(small, r, w, h);
            };
            Func<bool, Bitmap[]> fly = r =>
            {
                Bitmap a = img(F.Fly0, r), b = img(F.Fly1, r), c = img(F.Fly2, r);
                return new[] { a, b, c, b };
            };
            var feet = new PointF(FeetPx * zoom, h - FloorInset * zoom);
            if (play)
            {
                float lo = Math.Max(wa.Left + 60 * U, land.X - 200 * U), hi = Math.Max(lo, Math.Min(wa.Right - 60 * U, land.X + 200 * U));
                Func<bool, Bitmap[]> hop = r => new[] { img(F.Hop0, r), img(F.Hop1, r), img(F.Hop2, r) };
                visitors.Add(new Visitor(fly(right), fly(!right), new[] { img(F.Happy0, !right), img(F.Happy1, !right) },
                    feet, from, land, text ?? "", Rand(28, 40), Now, U, wa,
                    true, hop(true), hop(false), img(F.Sit0, true), img(F.Sit0, false), lo, hi));
            }
            else
                visitors.Add(new Visitor(fly(right), fly(!right), new[] { img(F.Happy0, !right), img(F.Happy1, !right) },
                    feet, from, land, text ?? "", Native.ReduceMotion() ? 5 : 4, Now, U, wa));
            Retime();
        }

        /// 마을 마당에 그릴 그림들 (주어진 옷을 입힌 채로). 그림을 아직 못 읽었으면 null. 쓰고 나면 Dispose 한다.
        public YardSprites MakeYardSprites(int[] rows)
        {
            if (bare.Count < (int)F.Count) return null;
            int[] valid = (rows ?? new int[0]).Where(r => r >= 0 && r < wearRows.Count).ToArray();
            Func<F, Bitmap> img = f => Dressed((int)f, valid);
            return new YardSprites
            {
                Sit = img(F.Sit0), Blink = img(F.Blink), Hop = new[] { img(F.Hop0), img(F.Hop1), img(F.Hop2) },
                Read = new[] { img(F.Read0), img(F.Read1) }, Sleep = new[] { img(F.Sleep0), img(F.Sleep1) },
                W = FrameW, H = FrameH,
            };
        }

        /// 짧은 말풍선 (꼬마 뱁새를 얻었을 때 등)
        public void Cheer(string text) { if (shown) Say(text, 2.2); }

        // 프레임 하나를 픽셀이 뭉개지지 않게 키운다.
        Bitmap Scaled(F f, bool right, int w, int h, bool naked = false)
        {
            return ScaledImage((naked ? bare : frames)[(int)f], right, w, h);
        }

        static Bitmap ScaledImage(Bitmap source, bool right, int w, int h)
        {
            var b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b))
            {
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.CompositingMode = CompositingMode.SourceCopy;
                Point[] dest = right ? new[] { new Point(0, 0), new Point(w, 0), new Point(0, h) }
                                     : new[] { new Point(w, 0), new Point(0, 0), new Point(w, h) };
                using (var attr = new ImageAttributes())
                {
                    attr.SetWrapMode(WrapMode.TileFlipXY);       // 가장자리 픽셀이 옅어지지 않게
                    g.DrawImage(source, dest, new Rectangle(0, 0, FrameW, FrameH), GraphicsUnit.Pixel, attr);
                }
            }
            return b;
        }

        // ── 말풍선 ──
        void Say(string text, double seconds)
        {
            bubble.SetText(text);
            bubbleUntil = Now + seconds;
            PlaceBubble();
            if (!bubble.Visible) bubble.Show();
        }

        void PlaceBubble()
        {
            Rectangle wa = CurrentScreen().WorkingArea;
            float x = Math.Min(wa.Right - bubble.Width - 6, Math.Max(wa.Left + 6, pos.X - bubble.Width / 2f));
            int y = (int)Math.Round(pos.Y - 62 * U - bubble.Height);
            var p = new Point((int)Math.Round(x), Math.Max(wa.Top + 2, y));
            if (bubble.Location != p) bubble.Location = p;
        }

        void HideBubble()
        {
            if (bubble.Visible) bubble.Hide();
        }

        void UpdateBubble(double now)
        {
            if (!bubble.Visible) return;
            bool talking = mode == Mode.Drink || mode == Mode.Eyes || mode == Mode.Stretch || mode == Mode.Mail || mode == Mode.Lost;
            if (now > bubbleUntil || !talking) HideBubble(); else PlaceBubble();
        }

        // ── 편지 심부름 ──
        bool CanRunErrand
        {
            get
            {
                return shown && (mode == Mode.Sit || mode == Mode.Hop || mode == Mode.Sleep || mode == Mode.Nest || mode == Mode.Drink
                                 || mode == Mode.Eyes || mode == Mode.Stretch);
            }
        }

        void StartErrand(Errand e)
        {
            Screen screen = CurrentScreen();
            Rectangle wa = screen.WorkingArea;
            errand = e;
            errandScreen = screen;
            carrying = e == Errand.Send;
            homeX = pos.X;
            lookUntil = 0;
            HideBubble();
            // 화면 위쪽 바깥으로 비스듬히 날아 나간다.
            float mid = wa.Left + wa.Width / 2f;
            float x = pos.X < mid ? Math.Min(wa.Right - 60 * U, pos.X + 280 * U) : Math.Max(wa.Left + 60 * U, pos.X - 280 * U);
            Fly(new PointF(x, screen.Bounds.Top - 10 * U), Mode.Depart);
        }

        /// 편지를 보낼 때: 편지를 물고 화면 밖으로 날아갔다가 빈 부리로 돌아온다.
        public bool CarryOut()
        {
            if (!CanRunErrand) return false;
            StartErrand(Errand.Send);
            return true;
        }

        /// 편지가 왔을 때: 화면 밖으로 나갔다가 편지를 물고 돌아와, 누를 때까지 기다린다.
        public bool BringMail(string text)
        {
            if (!CanRunErrand) return false;
            holdingQuiz = false;
            mailText = text;
            StartErrand(Errand.Receive);
            return true;
        }

        /// 문제를 물어 온다: 편지처럼 나갔다가 물고 돌아와 기다린다. 누르면 OnQuizOpen. 한참 안 누르면 그만둔다.
        public bool BringQuiz(string text)
        {
            if (!CanRunErrand) return false;
            holdingQuiz = true;
            mailText = text;
            StartErrand(Errand.Receive);
            return true;
        }

        /// 보낸 편지가 누락됐을 때: 시무룩하게 한 줄로 알린다.
        public bool ReportLost(string text)
        {
            if (!CanRunErrand) return false;
            lookUntil = 0;
            SetMode(Mode.Lost);
            Say(text, 7);
            return true;
        }

        // 습관 알림 가운데 지금 할 것을 시작한다. 하나도 때가 아니면 false.
        bool StartNudge(double now)
        {
            if (now >= nextStretch)
            {
                nextStretch = now + Config.StretchMinutes * 60;
                SetMode(Mode.Stretch);
                Say("기지개 한번 켜요", 7);
            }
            else if (now >= nextDrink)
            {
                nextDrink = now + Config.WaterMinutes * 60;
                SetMode(Mode.Drink);
                Say("물 한 잔 마실 시간이에요", 6);
            }
            else if (now >= nextEye)
            {
                nextEye = now + Config.EyeMinutes * 60;
                SetMode(Mode.Eyes);
                Say("눈을 20초만 쉬어요", 20);
            }
            else return false;
            lookUntil = 0;
            lastNudge = now;
            return true;
        }

        // ── 켜고 끄기 ──
        public void Start()
        {
            if (!Settings.PetOn || shown || frames.Count < (int)F.Count) return;
            Screen screen = Screen.PrimaryScreen;
            pos = new PointF(screen.WorkingArea.Right - 170 * U, FloorY(screen));
            homeX = pos.X;
            faceRight = false;
            shown = true;
            growth = growthTarget = 1;
            lastTick = Now;
            shownKey = -1;
            SetMode(Mode.Sit);
            Render(F.Sit0, 0);
            if (!win.Visible) win.Show();
        }

        public void Stop()
        {
            foreach (MiniBird m in minis) m.Remove();
            minis.Clear();
            foreach (Visitor v in visitors) v.Remove();
            visitors.Clear();
            popAt = 0;
            HideBubble();
            shown = false;
            timer.Stop();
            if (win.Visible) win.Hide();
        }

        public void SetEnabled(bool on)
        {
            Settings.PetOn = on;
            if (on) Start(); else Stop();
        }

        // ── 메뉴에서 동작 미리 보기 ──
        public void Preview(string what)
        {
            if (!shown || !(mode == Mode.Sit || mode == Mode.Hop || mode == Mode.Sleep || mode == Mode.Nest || mode == Mode.Drink
                            || mode == Mode.Eyes || mode == Mode.Stretch)) return;
            double now = Now;
            lookUntil = 0;
            switch (what)
            {
                case "drink": SetMode(Mode.Drink); Say("물 한 잔 마실 시간이에요", 6); break;
                case "eyes": SetMode(Mode.Eyes); Say("눈을 20초만 쉬어요", 20); break;
                case "stretch": SetMode(Mode.Stretch); Say("기지개 한번 켜요", 7); break;
                case "quizIn": BringQuiz("O/X 한 문제 풀래요? — 눌러서 풀기"); break;
                case "mailOut": CarryOut(); break;
                case "mailIn": BringMail("편지가 왔어요 (예시) — 눌러서 열기"); break;
                case "lost": ReportLost("편지를 잃어버렸어요… (예시)"); break;
                case "nest": nestHold = now + 12; SetMode(Mode.Nest); break;
                case "nod": SetMode(Mode.Sleep); rollAt = double.PositiveInfinity; nextAction = now + 11; break;
                case "roll": SetMode(Mode.Sleep); rollAt = 0; break;
                case "fly":
                    {
                        Rectangle wa = CurrentScreen().WorkingArea;
                        float mid = wa.Left + wa.Width / 2f;
                        float x = pos.X < mid ? Math.Min(wa.Right - 60 * U, pos.X + 480 * U) : Math.Max(wa.Left + 60 * U, pos.X - 480 * U);
                        Fly(new PointF(x, FloorY(CurrentScreen())), Mode.Roam);
                        break;
                    }
                case "tilt":
                    SetMode(Mode.Sit);
                    lookUntil = now + 3;
                    tiltAt = now + 0.6;
                    nextAction = now + 6;
                    break;
            }
        }

        // ── 집어서 옮기기 ──
        void PickUp()
        {
            if (!shown || mode == Mode.Away) return;
            heldFromMail = mode == Mode.Mail;
            Point m = Cursor.Position;
            downAt = Now;
            downPos = m;
            heldVel = PointF.Empty;
            grab = new PointF(m.X - pos.X, m.Y - pos.Y);
            lookUntil = 0;
            reactUntil = 0;
            SetMode(Mode.Held);
        }

        void Drop()
        {
            if (!shown || mode != Mode.Held) return;
            // 놓는 순간의 속도를 이어받는다 (위로 던지면 잠깐 솟았다가 떨어진다).
            double speed = Math.Sqrt(heldVel.X * heldVel.X + heldVel.Y * heldVel.Y);
            bool fast = speed > 320 * U && !Native.ReduceMotion();
            throwVX = fast ? Math.Max(-1700 * U, Math.Min(1700 * U, heldVel.X)) : 0;
            fallSpeed = fast ? Math.Max(-1000 * U, Math.Min(300 * U, heldVel.Y)) : 0;
            rollPhase = 0;
            // 편지(문제)를 물고 있을 때 옮기지 않고 살짝 누르기만 했으면 연다.
            Point m = Cursor.Position;
            double moved = Math.Sqrt(Math.Pow(m.X - downPos.X, 2) + Math.Pow(m.Y - downPos.Y, 2));
            if (heldFromMail && Now - downAt < 0.4 && moved < 6 * U)
            {
                heldFromMail = false;
                HideBubble();
                throwVX = 0;
                fallSpeed = 0;
                SetMode(Mode.Fall);
                if (holdingQuiz) { holdingQuiz = false; if (OnQuizOpen != null) OnQuizOpen(); }
                else if (OnMailOpen != null) OnMailOpen();
                return;
            }
            SetMode(Mode.Fall);
        }

        // ── 카드와 이어지는 동작 ──
        public void GoToCard()
        {
            if (!shown || PerchTarget == null) return;
            if (mode == Mode.FlyOut || mode == Mode.Perch || mode == Mode.Held || mode == Mode.Fall || mode == Mode.Tumble
                || mode == Mode.Depart || mode == Mode.Away || mode == Mode.Arrive || mode == Mode.Mail) return;
            PointF? target = PerchTarget();
            if (target == null) return;
            if (mode != Mode.FlyHome) homeX = pos.X;
            lookUntil = 0;
            HideBubble();
            if (ComboGrowth) growthTarget = GrowthFor(streak);      // 지난 카드까지의 연속 정답만큼 커진 채로 간다
            Fly(target.Value, Mode.FlyOut);
        }

        public void React(bool correct)
        {
            if (!shown || !(mode == Mode.Perch || mode == Mode.FlyOut)) return;
            reactHappy = correct;
            reactStart = Now;
            reactUntil = reactStart + (correct ? 0.8 : 1.1);
            if (ComboGrowth && !Native.ReduceMotion())
            {
                if (correct)
                {
                    streak++;
                    growthTarget = GrowthFor(streak);
                    if (streak >= PopStreak)                     // 화면을 가릴 만큼 부풀었다가 펑
                    {
                        popAt = reactStart + 0.9;
                        reactUntil = reactStart + 2.0;
                    }
                }
                else
                {
                    streak = 0;
                    growthTarget = 1;
                }
            }
            Retime();
        }

        public void GoHome()
        {
            if (!shown || !(mode == Mode.Perch || mode == Mode.FlyOut)) return;
            growthTarget = 1;                                    // 카드를 떠나 돌아다닐 때는 원래 크기로
            Fly(new PointF(homeX, FloorY(CurrentScreen())), Mode.FlyHome);
        }

        // 화면 옆 끝에 닿으면 튕겨 나온다.
        void BounceOffWalls()
        {
            Rectangle wa = CurrentScreen().WorkingArea;
            if (pos.X < wa.Left + 30 * U) { pos.X = wa.Left + 30 * U; throwVX = Math.Abs(throwVX) * 0.55f; }
            else if (pos.X > wa.Right - 30 * U) { pos.X = wa.Right - 30 * U; throwVX = -Math.Abs(throwVX) * 0.55f; }
        }

        // 떨어지거나 구르기를 마치고 그 자리에 자리 잡는다.
        void Settle(double now, bool dizzy)
        {
            homeX = pos.X;
            sitsInARow = 0;
            SetMode(Mode.Sit);
            if (heldFromMail)                                    // 편지를 문 채로 옮겨졌으면 계속 물고 기다린다
            {
                heldFromMail = false;
                SetMode(Mode.Mail);
                Say(mailText, 3600);
            }
            else if (PerchTarget != null && PerchTarget() != null) GoToCard();
            else
            {
                lookUntil = now + (dizzy ? 2.8 : 1.6);
                tiltAt = now + 0.5;
                if (dizzy) nextAction = lookUntil + Rand(2, 5);
            }
        }

        void Fly(PointF target, Mode m)
        {
            from = pos;
            to = target;
            double dist = Math.Sqrt(Math.Pow(to.X - from.X, 2) + Math.Pow(to.Y - from.Y, 2)) / U;
            if (m == Mode.Roam)                                  // 혼자 날 때는 느긋하고 높게
            {
                duration = Math.Min(2.4, Math.Max(1.0, dist / 330));
                arc = (float)Math.Min(170, Math.Max(70, dist * 0.35)) * U;
            }
            else
            {
                duration = Math.Min(1.4, Math.Max(0.7, dist / 700));
                arc = 36 * U;
            }
            faceRight = to.X >= from.X;
            SetMode(m);
        }

        // ── 상태 ──
        void SetMode(Mode m)
        {
            double now = Now;
            mode = m;
            modeStart = now;
            switch (m)
            {
                case Mode.Sit: nextAction = now + Rand(5, 14); break;
                case Mode.Sleep:
                    nextAction = now + Rand(20, 45);
                    // 절반쯤은 두세 번 꾸벅인 뒤, 푹 숙였을 때 데굴 구른다.
                    rollAt = Coin() ? NodPeriod * rng.Next(2, 4) + 2.0 : double.PositiveInfinity;
                    break;
                case Mode.Perch: faceRight = true; break;        // 카드 쪽을 본다
            }
            if (nextBlink < now) nextBlink = now + Rand(1.5, 4);
            Retime();
        }

        // 움직일 때만 자주, 가만히 있을 때는 드물게 그린다.
        void Retime()
        {
            bool moving = mode == Mode.Hop || mode == Mode.FlyOut || mode == Mode.FlyHome || mode == Mode.Roam || mode == Mode.Roll
                || mode == Mode.Held || mode == Mode.Fall || mode == Mode.Depart || mode == Mode.Arrive || mode == Mode.Tumble
                || minis.Count > 0 || visitors.Count > 0 || popAt > 0 || Math.Abs(growthTarget - growth) > 0.004 || Now < reactUntil;
            int want = moving ? 16 : 80;
            if (timer.Interval != want) timer.Interval = want;
            if (shown && !timer.Enabled) timer.Start();
        }

        Screen CurrentScreen()
        {
            return Screen.FromPoint(new Point((int)pos.X, (int)(pos.Y - 6 * U)));
        }

        // 다니는 바닥: 작업 표시줄 위쪽 끝 (작업 표시줄이 숨어 있으면 화면 아래 끝).
        float FloorY(Screen screen)
        {
            return Math.Min(screen.WorkingArea.Bottom, screen.Bounds.Bottom - FloorInset * zoom);
        }

        void ChooseNext(double now)
        {
            sitsInARow++;
            if (Calm || Native.ReduceMotion()) { nextAction = now + 20; return; }
            if (sitsInARow >= 4 && Coin())
            {
                sitsInARow = 0;
                SetMode(Mode.Sleep);
                return;
            }
            Screen screen = CurrentScreen();
            Rectangle wa = screen.WorkingArea;
            float lo = wa.Left + 60 * U, hi = wa.Right - 60 * U;
            int roll = rng.Next(100);
            if (roll < 35)                                       // 정면을 보고 고개를 한 번 기우뚱
            {
                lookUntil = now + Rand(2.6, 4.2);
                tiltAt = now + Rand(0.7, 1.4);
                faceRight = Coin();                              // 기우는 방향
                nextAction = lookUntil + Rand(2, 6);
                return;
            }
            if (roll < 55)                                       // 멀리 날아서 자리를 옮긴다
            {
                float x = (float)Rand(lo, hi);
                if (Math.Abs(x - pos.X) < 220 * U) x = pos.X < (lo + hi) / 2 ? Math.Min(hi, pos.X + 420 * U) : Math.Max(lo, pos.X - 420 * U);
                sitsInARow = 0;
                Fly(new PointF(x, FloorY(screen)), Mode.Roam);
                return;
            }
            float dx = rng.Next(3, 13) * HopStep * (Coin() ? 1 : -1);
            if (pos.X + dx < lo || pos.X + dx > hi) dx = -dx;    // 화면 끝이면 반대쪽으로
            float nx = Math.Min(hi, Math.Max(lo, pos.X + dx));
            hops = (int)Math.Floor(Math.Abs(nx - pos.X) / HopStep);
            if (hops < 1) { nextAction = now + 6; return; }
            faceRight = nx >= pos.X;
            from = new PointF(pos.X, FloorY(screen));
            SetMode(Mode.Hop);
        }

        static readonly F[] RollFrames = { F.Nod2, F.Roll1, F.Roll2, F.Roll3 };
        static readonly F[] FlyFrames = { F.Fly0, F.Fly1, F.Fly2, F.Fly1 };
        static readonly F[] MailFlyFrames = { F.MailFly0, F.MailFly1, F.MailFly2, F.MailFly1 };

        void Tick()
        {
            if (!shown) return;
            double now = Now;
            float dt = (float)Math.Min(0.1, now - lastTick);
            lastTick = now;
            double t = now - modeStart;
            F frame = F.Sit0;
            float lift = 0;
            float dir = faceRight ? 1 : -1;
            switch (mode)
            {
                case Mode.Nest:
                    // 가지를 물어다 놓고(2.4초) 둥지에 들어가 잔다. 다시 컴퓨터를 쓰기 시작하면 깬다.
                    if (t < 1.2) frame = (int)(t / 0.2) % 2 == 0 ? F.Build1 : F.Sit0;
                    else if (t < 2.4) frame = (int)(t / 0.2) % 2 == 0 ? F.Build2 : F.Build1;
                    else frame = (int)(t / 1.8) % 2 == 0 ? F.Nest0 : F.Nest1;
                    if (now > nestHold && t > 3 && Native.IdleSeconds() < 3)
                    {
                        if (t > 240)                             // 한참 쉬고 왔으면 습관 알림을 처음부터 다시 센다
                        {
                            nextDrink = now + Config.WaterMinutes * 60;
                            nextEye = now + Config.EyeMinutes * 60;
                            nextStretch = now + Config.StretchMinutes * 60;
                        }
                        SetMode(Mode.Sit);
                        lookUntil = now + 2.2;
                        tiltAt = now + 0.5;
                        nextAction = lookUntil + Rand(3, 7);
                        frame = F.Front;
                    }
                    break;
                case Mode.Eyes:
                    // 눈 쉬기: 정면을 보고 20초 동안 눈을 감고 있는다.
                    frame = t < 19.2 ? F.FrontBlink : F.Front;
                    if (t >= 20) { SetMode(Mode.Sit); frame = F.Sit0; }
                    break;
                case Mode.Stretch:
                    // 기지개: 날개를 쭉 펴고, 좌우로 한 번씩 몸을 기울인다.
                    if (t < 1.3) frame = F.Stretch;
                    else if (t < 2.3) { frame = F.Tilt; faceRight = true; }
                    else if (t < 3.3) frame = F.Stretch;
                    else if (t < 4.3) { frame = F.Tilt; faceRight = false; }
                    else if (t < 5.6) frame = F.Stretch;
                    else if (t < 6.4) frame = F.Front;
                    else { SetMode(Mode.Sit); frame = F.Sit0; }
                    break;
                case Mode.Drink:
                    // 컵을 보고(0.8초) 세 모금 마신 뒤 개운해한다.
                    if (t < 0.8) frame = F.Drink0;
                    else if (t < 4.4) frame = (int)((t - 0.8) / 0.6) % 2 == 0 ? F.Drink1 : F.Drink0;
                    else if (t < 5.8) frame = F.Drink2;
                    else { SetMode(Mode.Sit); frame = F.Sit0; }
                    break;
                case Mode.Sit:
                    {
                        if (now < lookUntil) frame = (now >= tiltAt && now < tiltAt + 0.8) ? F.Tilt : F.Front;
                        else if (studying) frame = now % 6.5 < 0.35 ? F.Read1 : F.Read0;      // 가끔 한 장 넘긴다
                        else frame = (int)(now / 0.9) % 2 == 0 ? F.Sit0 : F.Sit1;
                        // 생활 습관: 오래 손을 놓으면 둥지를 짓고, 계속 쓰고 있으면 가끔 물을 마신다.
                        double idle = Native.IdleSeconds();
                        if (idle > Config.NestMinutes * 60) { lookUntil = 0; SetMode(Mode.Nest); }
                        else if (Settings.HabitsOn && idle < 120 && now - lastNudge > 90 && StartNudge(now)) { }
                        else if (now >= nextAction && !studying) ChooseNext(now);
                        break;
                    }
                case Mode.Sleep:
                    {
                        // 꾸벅꾸벅: 눈 감고 버티다가 고개가 천천히 떨어지고, 푹 숙였다가 화들짝 든다.
                        double u = t % NodPeriod;
                        if (u < 1.1) frame = (int)(u / 0.55) % 2 == 0 ? F.Blink : F.Sleep1;
                        else if (u < 1.7) frame = F.Nod1;
                        else if (u < 2.6) frame = F.Nod2;
                        else if (u < 2.75) frame = F.Nod1;
                        else frame = F.Blink;
                        if (t >= rollAt && frame == F.Nod2)      // 너무 숙여서 그대로 앞으로 구른다
                        {
                            rollAt = double.PositiveInfinity;
                            Rectangle wa = CurrentScreen().WorkingArea;
                            if (faceRight && pos.X + RollDistance > wa.Right - 60 * U) faceRight = false;
                            else if (!faceRight && pos.X - RollDistance < wa.Left + 60 * U) faceRight = true;
                            from = pos;
                            SetMode(Mode.Roll);
                        }
                        else if (now >= nextAction) SetMode(Mode.Sit);
                        break;
                    }
                case Mode.Roll:
                    {
                        float k = (float)Math.Min(1, t / RollTime);
                        pos = new PointF(from.X + dir * RollDistance * k, from.Y);
                        frame = RollFrames[Math.Min(3, (int)(k * 4))];
                        if (k >= 1)                              // 굴러서 깼다: 어리둥절하게 앞을 보고 갸웃
                        {
                            sitsInARow = 0;
                            SetMode(Mode.Sit);
                            lookUntil = now + 2.4;
                            tiltAt = now + 0.6;
                            nextAction = lookUntil + Rand(3, 7);
                            frame = F.Front;
                        }
                        break;
                    }
                case Mode.Hop:
                    {
                        // 한 번의 뜀: 웅크림(0.08초) → 공중(0.24초, 이때만 앞으로 간다) → 착지(0.10초) → 멈춤
                        int n = (int)(t / HopPeriod);
                        if (n >= hops)
                        {
                            pos = new PointF(from.X + dir * HopStep * hops, from.Y);
                            sitsInARow = 0;
                            SetMode(Mode.Sit);
                            frame = F.Sit0;
                        }
                        else
                        {
                            double u = t - n * HopPeriod;
                            float air = 0;
                            if (u < 0.08) frame = F.Hop0;
                            else if (u < 0.32) { frame = F.Hop1; air = (float)((u - 0.08) / 0.24); }
                            else if (u < 0.42) { frame = F.Hop2; air = 1; }
                            else { frame = F.Sit0; air = 1; }
                            pos = new PointF(from.X + dir * HopStep * (n + air), from.Y);
                            if (frame == F.Hop1) lift = (float)Math.Sin(air * Math.PI) * 9 * U;
                        }
                        break;
                    }
                case Mode.Away:
                    // 화면 밖에서 잠깐 머문 뒤(편지를 건네거나 받아 오는 시간) 제자리로 돌아온다.
                    frame = F.Fly1;
                    if (t >= 2.2)
                    {
                        carrying = errand == Errand.Receive;
                        Fly(new PointF(homeX, FloorY(errandScreen ?? Screen.PrimaryScreen)), Mode.Arrive);
                    }
                    break;
                case Mode.Mail:
                    // 편지를 물고 기다린다. 가끔 들썩여서 눈에 띄게 한다.
                    faceRight = true;
                    frame = (int)(t / 0.45) % 7 == 0 ? F.Mail1 : F.Mail0;
                    if (!bubble.Visible) Say(mailText, 3600);
                    if (holdingQuiz && t > 90)                   // 문제는 한참 안 누르면 내려놓는다
                    {
                        holdingQuiz = false;
                        HideBubble();
                        SetMode(Mode.Sit);
                        frame = F.Sit0;
                    }
                    break;
                case Mode.Lost:
                    frame = F.Sad;
                    if (t >= 7) { SetMode(Mode.Sit); frame = F.Sit0; }
                    break;
                case Mode.FlyOut:
                case Mode.FlyHome:
                case Mode.Roam:
                case Mode.Depart:
                case Mode.Arrive:
                    {
                        if (mode == Mode.FlyOut && PerchTarget != null)
                        {
                            PointF? target = PerchTarget();      // 카드 크기가 바뀌면 따라간다
                            if (target != null) to = target.Value;
                        }
                        float raw = (float)Math.Min(1, t / duration);
                        float k = raw * raw * (3 - 2 * raw);
                        pos = new PointF(from.X + (to.X - from.X) * k, from.Y + (to.Y - from.Y) * k - (float)Math.Sin(k * Math.PI) * arc);
                        frame = (carrying ? MailFlyFrames : FlyFrames)[(int)(t * 14) % 4];
                        if (raw >= 1)
                        {
                            pos = to;
                            if (mode == Mode.FlyOut) SetMode(Mode.Perch);
                            else if (mode == Mode.Depart) SetMode(Mode.Away);
                            else if (mode == Mode.Arrive && errand == Errand.Receive)
                            {
                                carrying = false;
                                SetMode(Mode.Mail);
                                Say(mailText, 3600);
                            }
                            else
                            {
                                carrying = false;
                                SetMode(Mode.Sit);
                                faceRight = false;
                            }
                            frame = mode == Mode.Mail ? F.Mail0 : mode == Mode.Away ? F.Fly1 : F.Sit0;
                        }
                        break;
                    }
                case Mode.Held:
                    {
                        // 집힌 동안: 마우스를 따라가며 대롱대롱
                        Point m = Cursor.Position;
                        var next = new PointF(m.X - grab.X, m.Y - grab.Y);
                        if (dt > 0.001f)
                            heldVel = new PointF(heldVel.X * 0.55f + (next.X - pos.X) / dt * 0.45f, heldVel.Y * 0.55f + (next.Y - pos.Y) / dt * 0.45f);
                        pos = next;
                        frame = (int)(now / 0.28) % 2 == 0 ? F.Front : F.Tilt;
                        if ((Control.MouseButtons & MouseButtons.Left) == 0 && now - downAt > 0.15) Drop();   // 놓는 신호를 놓쳤을 때
                        break;
                    }
                case Mode.Fall:
                    {
                        // 놓으면 그 자리 아래 바닥으로 떨어져 앉는다. 카드가 떠 있으면 다시 카드로 간다.
                        float floor = FloorY(CurrentScreen());
                        fallSpeed += 1800 * U * dt;
                        pos.Y += fallSpeed * dt;
                        pos.X += throwVX * dt;
                        BounceOffWalls();
                        bool thrown = Math.Abs(throwVX) > 220 * U;
                        if (thrown)                              // 던져졌으면 공중에서 빙글빙글
                        {
                            faceRight = throwVX > 0;
                            rollPhase += dt * 11;
                            frame = RollFrames[(int)rollPhase % 4];
                        }
                        else frame = F.Hop1;
                        if (pos.Y >= floor)
                        {
                            pos.Y = floor;
                            if (thrown) SetMode(Mode.Tumble);    // 그대로 바닥을 데굴데굴
                            else
                            {
                                Settle(now, false);
                                frame = F.Hop2;
                            }
                        }
                        break;
                    }
                case Mode.Tumble:
                    // 바닥에 닿은 뒤: 마찰로 느려지면서 구르다가 멈추면 어리둥절해한다.
                    throwVX *= (float)Math.Exp(-2.4 * dt);
                    pos.X += throwVX * dt;
                    BounceOffWalls();
                    faceRight = throwVX > 0;
                    rollPhase += Math.Abs(throwVX) * dt / (34 * U);      // 34포인트마다 사분의 일 바퀴
                    frame = RollFrames[(int)rollPhase % 4];
                    if (Math.Abs(throwVX) < 55 * U)
                    {
                        throwVX = 0;
                        Settle(now, true);
                        frame = F.Front;
                    }
                    break;
                case Mode.Perch:
                    {
                        // 몸이 커져도 카드를 가리지 않게, 커진 만큼 왼쪽으로 물러난다.
                        PointF? target = PerchTarget != null ? PerchTarget() : null;
                        if (target != null) pos = new PointF(target.Value.X - (growth - 1) * 26 * U, target.Value.Y);
                        else GoHome();
                        frame = (int)(now / 0.9) % 2 == 0 ? F.Sit0 : F.Sit1;
                        break;
                    }
            }

            // 정답·오답 반응 (카드 옆에 앉아 있을 때)
            if (now < reactUntil)
            {
                if (mode == Mode.Perch)
                {
                    if (reactHappy) frame = (int)((now - reactStart) * 9) % 2 == 0 ? F.Happy0 : F.Happy1;
                    else frame = now - reactStart < 0.55 ? F.Tilt : F.Sad;     // 갸웃한 뒤 시무룩
                }
            }
            else if (reactUntil != 0)
            {
                reactUntil = 0;
                Retime();
            }

            // 눈 깜빡임 (앉아 있을 때만)
            if (now >= nextBlink)
            {
                blinkUntil = now + 0.18;
                nextBlink = now + Rand(2.5, 6);
            }
            if (now < blinkUntil)
            {
                if (frame == F.Sit0 || frame == F.Sit1) frame = F.Blink;
                else if (frame == F.Front) frame = F.FrontBlink;
            }

            // 연속 정답: 배율을 부드럽게 따라가고, 때가 되면 터뜨린다.
            if (Math.Abs(growthTarget - growth) > 0.004f) growth += (growthTarget - growth) * Math.Min(1, dt * 9);
            else if (growth != growthTarget) { growth = growthTarget; Retime(); }
            if (popAt > 0 && now >= popAt) Pop();
            if (minis.Count > 0)
            {
                minis.RemoveAll(m => !m.Update(dt, now));
                if (minis.Count == 0) Retime();
            }
            if (visitors.Count > 0)
            {
                visitors.RemoveAll(v => !v.Update(now));
                if (visitors.Count == 0) Retime();
            }

            Render(frame, lift);
            UpdateBubble(now);
        }

        // 연속 정답 수에 따른 배율. 한 번 맞힐 때마다 같은 비율로 커져서, 다섯 번째에는 몸이 화면 높이의 절반 가까이 된다.
        float GrowthFor(int n)
        {
            if (n <= 0) return 1;
            float screenH = Screen.FromPoint(Point.Round(pos)).Bounds.Height;
            double full = Math.Max(3, screenH * 0.46 / (17 * zoom));     // 몸 높이는 스프라이트 17픽셀
            return (float)Math.Pow(full, Math.Min(n, PopStreak) / (double)PopStreak);
        }

        // 펑: 큰 몸이 사라지고 작은 새 여럿이 튀어 나갔다가, 잠시 뒤 하나씩 날아가고 원래 한 마리만 남는다.
        void Pop()
        {
            popAt = 0;
            streak = 0;
            var center = new PointF(winRect.Left + winRect.Width / 2f, winRect.Top + winRect.Height / 2f);
            growth = 1;
            growthTarget = 1;
            Rectangle screen = CurrentScreen().Bounds;
            if (miniRight == null)
            {
                int z = Math.Max(1, zoom * 2 / 3);               // 본래 크기의 3분의 2
                F[] set = { F.Hop1, F.Fly0, F.Fly1, F.Fly2, F.Fly1 };
                miniRight = set.Select(f => Scaled(f, true, FrameW * z, FrameH * z, true)).ToArray();      // 꼬마들은 옷을 안 입는다
                miniLeft = set.Select(f => Scaled(f, false, FrameW * z, FrameH * z, true)).ToArray();
            }
            const int n = 14;
            bool catchable = OnMiniCaught != null;
            float up = center.Y < screen.Top + screen.Height / 2f ? -0.8f : 1;   // 화면 위쪽에 있으면 아래로, 아래쪽에 있으면 위로 퍼진다
            double now = Now;
            for (int i = 0; i < n; i++)
            {
                double angle = Math.PI * (0.12 + 0.76 * i / (n - 1)) + Rand(-0.12, 0.12);     // 반원으로 퍼진다
                float speed = (float)Rand(380, 900) * U;
                bool goRight = Math.Cos(angle) > 0;
                var exit = new PointF(goRight ? screen.Right + 80 * U : screen.Left - 80 * U, center.Y - (float)Rand(-160, 220) * U);
                minis.Add(new MiniBird(miniRight, miniLeft, center,
                    new PointF((float)Math.Cos(angle) * speed, -(float)Math.Sin(angle) * speed * up),
                    now, catchable ? 3.0 + i * 0.4 : 1.6 + i * 0.22, exit, U,
                    catchable ? (Action)(() => { if (OnMiniCaught != null) OnMiniCaught(); }) : null));
            }
            Retime();
        }

        // 지금 자세를 창에 올리고 발 위치에 맞춰 창을 놓는다. 연속 정답으로 커졌으면 창도 그만큼 키운다.
        void Render(F frame, float lift)
        {
            if ((int)frame >= frames.Count) return;
            int w = (int)Math.Round(FrameW * zoom * growth), h = (int)Math.Round(FrameH * zoom * growth);
            float feetX = FeetPx * zoom * growth;
            int x = (int)Math.Round(pos.X - feetX);
            int y = (int)Math.Round(pos.Y + FloorInset * zoom * growth - lift - h);
            if (growth > 1.01f)
            {
                // 크게 부풀었을 때 화면 위로 넘치지 않게 아래로 내린다.
                Rectangle wa = Screen.FromPoint(Point.Round(pos)).WorkingArea;
                y = Math.Max(y, wa.Top);
            }
            int key = (int)frame * 2 + (faceRight ? 0 : 1);
            var size = new Size(w, h);
            var at = new Point(x, y);
            if (key != shownKey || size != shownSize)
            {
                bool plain = Math.Abs(growth - 1) < 0.0005f;
                Bitmap image;
                if (plain)
                {
                    if (!cache.TryGetValue(key, out image)) cache[key] = image = Scaled(frame, faceRight, w, h);
                    win.Present(image, x, y);
                }
                else
                {
                    using (image = Scaled(frame, faceRight, w, h)) win.Present(image, x, y);
                }
                shownKey = key;
                shownSize = size;
                shownAt = at;
            }
            else if (at != shownAt)
            {
                win.MoveTo(x, y);
                shownAt = at;
            }
            winRect = new Rectangle(at, size);
            bool big = growth > 1.25f;                           // 크게 부푼 동안에는 카드를 누를 수 있게 클릭을 통과시킨다
            if (big != passing) { passing = big; win.SetClickThrough(big); }
        }
        bool passing;

        /// 트레이 아이콘·설정 창에 쓸 얼굴 그림 (정면 프레임에서 몸만 잘라 낸 것).
        public Bitmap FaceImage(int height)
        {
            if ((int)F.Front >= bare.Count) return null;
            int width = (int)Math.Round(height * 20 / 23.0);
            var b = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b))
            using (var attr = new ImageAttributes())
            {
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                attr.SetWrapMode(WrapMode.TileFlipXY);
                g.DrawImage(bare[(int)F.Front], new Rectangle(0, 0, width, height), 8, 5, 20, 23, GraphicsUnit.Pixel, attr);
            }
            return b;
        }

        // ── 동작 확인용 ──
        /// 읽은 프레임을 전부(오른쪽 보기 + 왼쪽 보기) 한 장의 PNG 로 저장한다.
        public void SnapshotPoses(string path)
        {
            const int k = 2;
            int n = frames.Count, w = FrameW * k, h = FrameH * k;
            using (var sheet = new Bitmap(Math.Max(1, w * n), h * 2, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(sheet))
                {
                    g.Clear(Color.FromArgb(219, 219, 219));
                    for (int row = 0; row < 2; row++)
                        for (int i = 0; i < n; i++)
                            using (Bitmap b = Scaled((F)i, row == 0, w, h)) g.DrawImage(b, i * w, row * h, w, h);
                }
                sheet.Save(path, ImageFormat.Png);
            }
        }

        /// 지금 상태를 한 줄로 (자체 점검이 읽는다).
        public string DebugState
        {
            get
            {
                return "mode=" + mode + " growth=" + growth.ToString("0.00") + " streak=" + streak + " minis=" + minis.Count + " visitors=" + visitors.Count + (studying ? " studying" : "")
                    + " window=" + winRect.Width + "x" + winRect.Height + "@" + winRect.Left + "," + winRect.Top
                    + " feet=" + (int)pos.X + "," + (int)pos.Y + " bubble=" + bubble.Visible;
            }
        }

        /// 자체 점검용: 혼자 돌아다니지 않고 가만히 있는다.
        public bool Calm;
        public string ModeName { get { return mode.ToString(); } }
        public float Growth { get { return growth; } }
        public int MiniCount { get { return minis.Count; } }
        /// 자체 점검용: 떠 있는 꼬마를 하나 잡은 것처럼 한다.
        /// 자체 점검용: 와 있는 손님을 바로 돌려보낸다 (놀다 가는 손님은 30초 넘게 머문다).
        public void TestClearVisitors()
        {
            foreach (Visitor v in visitors) v.Remove();
            visitors.Clear();
            Retime();
        }

        public bool TestCatchMini()
        {
            if (minis.Count == 0 || OnMiniCaught == null) return false;
            minis[0].Remove();
            minis.RemoveAt(0);
            OnMiniCaught();
            return true;
        }
        public Rectangle WindowRect { get { return winRect; } }
        public PointF Feet { get { return pos; } }

        /// 자체 점검용: 집어서 주어진 속도로 던진 것처럼 만든다.
        public void TestThrow(float vx, float vy)
        {
            if (!shown) return;
            heldFromMail = false;
            pos = new PointF(pos.X, pos.Y - 200 * U);
            throwVX = vx * U;
            fallSpeed = vy * U;
            rollPhase = 0;
            SetMode(Mode.Fall);
        }

        /// 자체 점검용: 물고 기다리는 펫을 살짝 누른 것처럼 연다.
        public bool TestOpenHeld()
        {
            if (mode != Mode.Mail) return false;
            HideBubble();
            SetMode(Mode.Sit);
            if (holdingQuiz) { holdingQuiz = false; if (OnQuizOpen != null) OnQuizOpen(); }
            else if (OnMailOpen != null) OnMailOpen();
            return true;
        }
    }
}
