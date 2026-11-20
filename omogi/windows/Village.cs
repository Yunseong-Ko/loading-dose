// 마을: 친구들의 오모기를 한 창에서 본다. Mac 판의 village.swift 와 같은 규칙이다.
// 친구에게 보이는 것은 입은 옷, 오늘 맞힌 문제 수(끌 수 있다), 오늘 공부한 시간, 지금 공부 중인지다.
// 편지와 달리 이 정보는 잠그지 않고 서버에 올라간다.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using WinTimer = System.Windows.Forms.Timer;

namespace Omogi
{
    /// 공부 시작 / 끝. 켜 둔 동안의 시간을 오늘 공부 시간으로 센다. 5분 넘게 손을 놓으면 저절로 멈춘다.
    /// 오늘 센 시간은 %APPDATA%\Omogi\study.json 에 둔다.
    static class Study
    {
        public const double IdleLimit = 300;
        public static event Action Changed;

        static bool loaded;
        static string day = "";
        static int secs;
        static DateTime? since;                 // UTC
        static WinTimer timer;

        static string FilePath { get { return Path.Combine(Config.Dir, "study.json"); } }

        /// 저장한 것을 다시 읽는다 (자체 점검에서 폴더를 바꾼 뒤에도 쓴다).
        public static void Reload()
        {
            loaded = true;
            day = "";
            secs = 0;
            try
            {
                if (!File.Exists(FilePath)) return;
                var j = Json.Parse(File.ReadAllText(FilePath, Encoding.UTF8));
                double v;
                if (Json.Number(j, "secs", out v)) secs = Math.Max(0, (int)v);
                day = Json.Str(j, "day") ?? "";
            }
            catch (Exception e) { Log.Write("study.json 을 읽지 못함: " + e.Message); }
        }

        static int Stored
        {
            get
            {
                if (!loaded) Reload();
                return day == Wardrobe.TodayKey ? secs : 0;
            }
        }

        public static bool Studying { get { return since != null; } }

        /// 오늘 공부한 시간(초). 지금 공부 중이면 지금까지를 더한다.
        public static int SecondsToday
        {
            get { return Stored + (since != null ? Math.Max(0, (int)(DateTime.UtcNow - since.Value).TotalSeconds) : 0); }
        }

        public static void Start()
        {
            if (since != null) return;
            since = DateTime.UtcNow;
            if (timer == null)
            {
                timer = new WinTimer { Interval = 20000 };
                timer.Tick += (s, e) => Watch();
            }
            timer.Start();
            if (Changed != null) Changed();
        }

        /// idleCut: 손을 놓고 있던 시간은 빼고 멈춘다.
        public static void Stop(double idleCut = 0)
        {
            if (since == null) return;
            int add = Math.Max(0, (int)((DateTime.UtcNow - since.Value).TotalSeconds - idleCut));
            secs = Math.Min(86400, Stored + add);
            day = Wardrobe.TodayKey;
            since = null;
            if (timer != null) timer.Stop();
            try
            {
                var j = new Dictionary<string, object> { { "day", day }, { "secs", secs } };
                File.WriteAllText(FilePath, Json.Write(j), new UTF8Encoding(false));
            }
            catch (Exception e) { Log.Write("study.json 을 쓰지 못함: " + e.Message); }
            if (Changed != null) Changed();
        }

        static void Watch()
        {
            double idle = Native.IdleSeconds();
            if (idle >= IdleLimit) Stop(idle);
        }

        public static string Clock(int secs)
        {
            int m = secs / 60;
            return m >= 60 ? (m / 60) + "시간 " + (m % 60) + "분" : m + "분";
        }
    }

    sealed class Villager
    {
        public string Id, Name, Handle, Wear = "", Day = "";      // Handle 은 없을 수 있다
        public int? Correct;                                      // null 이면 친구가 숨겼다
        public int StudySecs;
        public bool Studying;
        public int? SeenSecs;
    }

    sealed class Village
    {
        /// 친구 소식이 바뀌면 화면 스레드에서 알린다.
        public event Action Changed;

        readonly Server server = Server.Shared;
        readonly LetterBox letters;
        readonly Pet pet;
        WinTimer timer;
        string lastPushed = "";
        DateTime lastPushAt = DateTime.MinValue, lastPokeCheck = DateTime.MinValue;
        List<Villager> villagers = new List<Villager>();

        public IList<Villager> Villagers { get { return villagers; } }
        /// 서버가 아직 마을을 모른다 (schema.sql 을 다시 실행하지 않았다)
        public bool Unsupported { get; private set; }
        public string Note { get; private set; }

        /// 오늘 맞힌 문제 수를 친구에게 보일지
        public static bool ShareCorrect
        {
            get { return Settings.Get("villageShareCorrect", true); }
            set { Settings.Set("villageShareCorrect", value); }
        }

        public bool Online { get { return letters.Online && server != null && !Unsupported; } }

        public Village(LetterBox letters, Pet pet)
        {
            this.letters = letters;
            this.pet = pet;
            Note = "";
        }

        public void Start()
        {
            if (timer != null) return;
            timer = new WinTimer { Interval = 20000 };
            timer.Tick += (s, e) => Tick();
            timer.Start();
            Wardrobe.Changed += () => Push();
            Study.Changed += () => Push();
            var first = new WinTimer { Interval = 8000 };
            first.Tick += (s, e) => { first.Stop(); first.Dispose(); Tick(); };
            first.Start();
        }

        void Tick()
        {
            try
            {
                Push();
                if (Online && (DateTime.UtcNow - lastPokeCheck).TotalSeconds >= 60) FetchPokes();
            }
            catch (Exception e) { Log.Write("마을: 오류 " + e.GetType().Name); }
        }

        // 서버에 그 함수가 없다 (HTTP 404)
        static bool Missing(ServerError e)
        {
            return e != null && (e.Code.Contains("404") || e.Code.Contains("PGRST202") || e.Code.Contains("not_found"));
        }

        /// 내 상태가 바뀌었거나, 공부 중이라 소식을 이어 줘야 할 때 서버에 올린다.
        public void Push(bool force = false)
        {
            if (!Online) return;
            object correct = ShareCorrect ? (object)Wardrobe.CorrectToday : null;
            string wear = Wardrobe.WornNames, today = Wardrobe.TodayKey;
            bool studying = Study.Studying;
            int secs = Study.SecondsToday;
            string sig = wear + "|" + today + "|" + (correct ?? "-") + "|" + studying + "|" + (secs / 300);
            bool heartbeat = studying && (DateTime.UtcNow - lastPushAt).TotalSeconds >= 240;
            if (!force && sig == lastPushed && !heartbeat) return;
            lastPushed = sig;
            lastPushAt = DateTime.UtcNow;
            var args = new Dictionary<string, object>
            {
                { "p_wear", wear }, { "p_day", today }, { "p_correct", correct }, { "p_study_secs", secs }, { "p_studying", studying },
            };
            server.Call("omogi_set_status", args, r =>
            {
                if (r.Ok) return;
                if (Missing(r.Error)) Unsupported = true;
                Log.Write("마을: 상태 올리기 실패 " + r.Error.Code);
            });
        }

        static int? Int(Dictionary<string, object> j, string key)
        {
            object o;
            if (j == null || !j.TryGetValue(key, out o) || o == null || o is string || o is bool) return null;
            try { return (int)Math.Max(int.MinValue, Math.Min(int.MaxValue, Convert.ToDouble(o))); }
            catch { return null; }
        }

        /// omogi_village 의 대답을 읽는다. 읽을 수 없는 것은 건너뛴다.
        internal static List<Villager> ParseVillage(object value)
        {
            var list = new List<Villager>();
            foreach (var j in LetterFiles.Rows(value))
            {
                string id = LetterFiles.Text(j, "id"), name = LetterFiles.Text(j, "name");
                if (id == null || name == null) continue;
                list.Add(new Villager
                {
                    Id = id, Name = name, Handle = LetterFiles.Text(j, "handle"), Wear = LetterFiles.Text(j, "wear") ?? "",
                    Day = LetterFiles.Text(j, "day") ?? "", Correct = Int(j, "correct"), StudySecs = Int(j, "study_secs") ?? 0,
                    Studying = LetterFiles.Flag(j, "studying"), SeenSecs = Int(j, "seen_secs"),
                });
            }
            return list;
        }

        /// 친구들의 상태를 받아 온다.
        public void Refresh(Action done = null)
        {
            if (!letters.Online || server == null)
            {
                Note = "친구를 맺으면 여기에 모여요. 설정 창의 \"친구…\"에서 시작하세요.";
                if (done != null) done();
                return;
            }
            server.Call("omogi_village", null, r =>
            {
                if (r.Ok)
                {
                    Unsupported = false;
                    Note = "";
                    villagers = ParseVillage(r.Value);
                }
                else if (Missing(r.Error))
                {
                    Unsupported = true;
                    Note = "서버가 아직 마을 기능을 모릅니다. (서버 준비가 끝나면 보여요.)";
                }
                else Note = "지금은 친구 소식을 받아 오지 못했어요. (" + r.Error.Message + ")";
                if (Changed != null) Changed();
                if (done != null) done();
            });
        }

        public void Poke(Villager v, Action<string> done)
        {
            if (server == null || v == null) return;
            server.Call("omogi_poke", new Dictionary<string, object> { { "p_to", v.Id } }, r =>
            {
                if (r.Ok) done(v.Name + "에게 날아갔어요");
                else if (r.Error.Code.Contains("daily_limit")) done("오늘은 " + v.Name + "를 충분히 찔렀어요");
                else
                {
                    if (Missing(r.Error)) Unsupported = true;
                    done("못 갔어요 (" + (Missing(r.Error) ? "서버가 아직 마을 기능을 모릅니다." : r.Error.Message) + ")");
                }
            });
        }

        void FetchPokes()
        {
            if (server == null) return;
            lastPokeCheck = DateTime.UtcNow;
            server.Call("omogi_fetch_pokes", null, r =>
            {
                if (!r.Ok)
                {
                    if (Missing(r.Error)) Unsupported = true;
                    return;
                }
                var list = LetterFiles.Rows(r.Value);
                // 같은 친구가 여러 번 찔렀으면 한 번만 온다.
                var seen = new HashSet<string>();
                foreach (var j in list)
                {
                    string name = LetterFiles.Text(j, "name"), from = LetterFiles.Text(j, "from");
                    if (name == null || !seen.Add(from ?? name)) continue;
                    int n = list.Count(x => LetterFiles.Text(x, "from") == from);
                    pet.Visit(Wardrobe.RowsForNames(LetterFiles.Text(j, "wear") ?? ""),
                        n > 1 ? name + "가 콕콕 " + n + "번 찔렀어요" : name + "가 콕 찔렀어요");
                }
                if (list.Count > 0) Log.Write("마을: 콕 " + list.Count + "번 받음");
            });
        }

        /// 편지가 도착했을 때: 보낸 친구의 새가 그 친구 옷을 입고 잠깐 들른다 (이름이 같은 친구가 하나일 때만).
        public void LetterArrived(string name)
        {
            if (!Online) return;
            Refresh(() =>
            {
                var same = villagers.Where(v => v.Name == name).ToList();
                if (same.Count != 1) return;
                pet.Visit(Wardrobe.RowsForNames(same[0].Wear), name + "가 편지를 보냈어요");
            });
        }

        /// 동작 확인용: 서버 없이 친구 목록을 채워 넣는다.
        public void DebugSet(List<Villager> list) { villagers = list ?? new List<Villager>(); }
    }

    /// 마을 창
    sealed class VillageForm : Form
    {
        readonly Village village;
        readonly Pet pet;
        readonly WinTimer timer = new WinTimer { Interval = 30000 };
        string flash = "";
        int shownRows = -1;
        const int W = 460, RowH = 62;

        public VillageForm(Village village, Pet pet)
        {
            this.village = village;
            this.pet = pet;
            Text = "마을";
            Font = new Font("Malgun Gothic", 9f);
            AutoScaleMode = AutoScaleMode.None;         // 좌표는 96dpi 기준으로 적고 Dpi.R() 로 맞춘다
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            village.Changed += OnChanged;
            Study.Changed += OnChanged;
            Wardrobe.Changed += OnChanged;
            timer.Tick += (s, e) => { if (Visible) village.Refresh(); };
            Render();
        }

        void OnChanged() { if (!IsDisposed && Visible) Render(); }

        /// 창을 띄우면서 내 상태를 올리고 친구 소식을 받아 온다.
        public void Open()
        {
            Render();
            village.Push(true);
            village.Refresh();
            timer.Start();
            Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
        }

        static Label Text_(string text, Rectangle r, float size, FontStyle style, Color color)
        {
            return new Label { Text = text, Bounds = r, Font = new Font("Malgun Gothic", size, style), ForeColor = color, BackColor = Color.Transparent, AutoEllipsis = true, UseMnemonic = false };
        }

        PictureBox Picture(int[] rows, Rectangle r, int scale)
        {
            return new PictureBox { Image = pet.PreviewImage(rows, Dpi.S(scale)), SizeMode = PictureBoxSizeMode.CenterImage, Bounds = r };
        }

        static string Line(Villager v)
        {
            var parts = new List<string>();
            if (v.Studying) parts.Add("공부 중");
            bool today = v.Day == Wardrobe.TodayKey;
            if (today && v.Correct != null) parts.Add("오늘 " + v.Correct.Value + "문제");
            if (today && v.StudySecs >= 60) parts.Add("공부 " + Study.Clock(v.StudySecs));
            if (parts.Count == 0)
            {
                if (v.SeenSecs == null) return "아직 소식이 없어요";
                int s = v.SeenSecs.Value;
                return s < 3600 ? "조금 전에 다녀감" : s < 86400 ? (s / 3600) + "시간 전에 다녀감" : (s / 86400) + "일 전에 다녀감";
            }
            return string.Join("  ·  ", parts);
        }

        public void Render()
        {
            int rows = Math.Max(1, Math.Min(8, village.Villagers.Count));
            int H = 150 + RowH * rows + 46;
            SuspendLayout();
            Point scroll = AutoScrollPosition;          // 스크롤된 채로 다시 그리면 자리가 어긋난다
            if (AutoScroll) AutoScrollPosition = Point.Empty;
            if (rows != shownRows)
            {
                shownRows = rows;
                scroll = Point.Empty;
                AutoScroll = false;
                AutoScrollMinSize = Size.Empty;
                ClientSize = new Size(Dpi.S(W), Dpi.S(H));
                Dpi.FitToScreen(this);
            }
            foreach (Control c in Controls.Cast<Control>().ToList())
            {
                Controls.Remove(c);
                var p = c as PictureBox;
                if (p != null && p.Image != null) p.Image.Dispose();
                c.Dispose();
            }
            Color ink = Color.FromArgb(28, 28, 30);

            // 나
            Controls.Add(Picture(Wardrobe.WornRows, Dpi.R(20, 20, 144, 112), 4));
            Controls.Add(Text_("나", Dpi.R(180, 26, 200, 26), 12.5f, FontStyle.Bold, ink));
            string mine = "오늘 " + Wardrobe.CorrectToday + "문제";
            if (Study.SecondsToday >= 60) mine += "  ·  공부 " + Study.Clock(Study.SecondsToday);
            if (Study.Studying) mine = "공부 중  ·  " + mine;
            Controls.Add(Text_(mine, Dpi.R(181, 56, 260, 18), 9f, FontStyle.Regular, Color.Gray));
            var study = new Button { Text = Study.Studying ? "공부 끝" : "공부 시작", Bounds = Dpi.R(178, 80, 110, 30), FlatStyle = FlatStyle.System };
            study.Click += (s, e) => { if (Study.Studying) Study.Stop(); else Study.Start(); };
            Controls.Add(study);
            var share = new CheckBox
            {
                Text = "오늘 맞힌 수 보이기", Bounds = Dpi.R(298, 85, 146, 20), Font = new Font("Malgun Gothic", 8.25f),
                ForeColor = ink, Checked = Village.ShareCorrect,
            };
            share.CheckedChanged += (s, e) => { Village.ShareCorrect = share.Checked; village.Push(true); };
            Controls.Add(share);
            var hint = Text_("공부 중엔 책을 봐요. 5분 손을 놓으면 저절로 멈춥니다.", Dpi.R(181, 113, 262, 30), 8f, FontStyle.Regular, Color.DarkGray);
            hint.AutoEllipsis = false;
            Controls.Add(hint);
            Controls.Add(new Label { Bounds = Dpi.R(20, 146, W - 40, 1), BackColor = Color.FromArgb(225, 225, 225) });

            // 친구들
            int y = 150;
            if (village.Villagers.Count == 0)
            {
                string msg = string.IsNullOrEmpty(village.Note) ? "아직 친구가 없어요. 설정 창의 \"친구…\"에서 친구를 맺으면 여기에 모여요." : village.Note;
                var l = Text_(msg, Dpi.R(24, y + 12, W - 48, 40), 9f, FontStyle.Regular, Color.Gray);
                l.AutoEllipsis = false;
                Controls.Add(l);
            }
            foreach (Villager villager in village.Villagers.Take(8))
            {
                Villager v = villager;
                Controls.Add(Picture(Wardrobe.RowsForNames(v.Wear), Dpi.R(20, y + 3, 72, 56), 2));
                Controls.Add(Text_(string.IsNullOrEmpty(v.Handle) ? v.Name : v.Name + " (@" + v.Handle + ")", Dpi.R(100, y + 11, 240, 20), 9.75f, FontStyle.Bold, ink));
                Controls.Add(Text_(Line(v), Dpi.R(100, y + 32, 250, 18), 8.25f, FontStyle.Regular, v.Studying ? Color.FromArgb(40, 160, 80) : Color.Gray));
                var poke = new Button { Text = "콕", Bounds = Dpi.R(W - 92, y + 16, 72, 30), FlatStyle = FlatStyle.System };
                poke.Click += (s, e) =>
                {
                    poke.Enabled = false;
                    village.Poke(v, text =>
                    {
                        if (IsDisposed) return;
                        flash = text;
                        Render();
                        var clear = new WinTimer { Interval = 4000 };
                        clear.Tick += (s2, e2) =>
                        {
                            clear.Stop();
                            clear.Dispose();
                            if (flash == text && !IsDisposed) { flash = ""; Render(); }
                        };
                        clear.Start();
                    });
                };
                Controls.Add(poke);
                y += RowH;
            }
            bool plain = string.IsNullOrEmpty(flash);
            var foot = Text_(plain ? "친구에게 보이는 것: 입은 옷, 오늘 맞힌 수(끌 수 있음), 공부 시간, 공부 중인지." : flash,
                Dpi.R(20, H - 38, W - 40, 32), 8.25f, FontStyle.Regular, plain ? Color.DarkGray : ink);
            foot.AutoEllipsis = false;
            Controls.Add(foot);
            if (AutoScroll) AutoScrollPosition = new Point(-scroll.X, -scroll.Y);
            ResumeLayout();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; timer.Stop(); Hide(); return; }
            timer.Stop();
            village.Changed -= OnChanged;
            Study.Changed -= OnChanged;
            Wardrobe.Changed -= OnChanged;
            base.OnFormClosing(e);
        }

        /// 동작 확인용: 서버 없이 친구 목록을 채워 넣는다.
        public void DebugFill(List<Villager> list) { village.DebugSet(list); Render(); }

        public void Snapshot(string path)
        {
            using (var bmp = new Bitmap(Width, Height))
            {
                DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }
}
