// 꼬마 뱁새(문제를 맞히면 모이는 것)와 옷장. Mac 판의 wardrobe.swift 와 같은 규칙이다.
// 전부 내 컴퓨터(%APPDATA%\Omogi\wardrobe.json)에만 저장한다. 서버로는 아무것도 보내지 않는다.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace Omogi
{
    /// 옷 한 가지. Row 는 wear.png 의 줄 번호 (tools/make_pet_sprites.py 의 ITEMS 순서).
    sealed class WearItem
    {
        public string Id, Name, Slot, Note;
        public int Row, Price;          // Price 가 0 이면 살 수 없고 조건을 채우면 받는다
    }

    static class Wardrobe
    {
        public const int DailyCap = 60;         // 하루에 받을 수 있는 꼬마 뱁새
        public const int MedalGoal = 100;       // 한 과목에서 이만큼 맞히면 메달
        public const string Head = "머리", Face = "얼굴", Neck = "목";
        public static event Action Changed;

        public static readonly WearItem[] Items =
        {
            new WearItem { Id = "scarf", Row = 0, Name = "빨간 목도리", Slot = Neck, Price = 30 },
            new WearItem { Id = "straw", Row = 1, Name = "밀짚모자", Slot = Head, Price = 40 },
            new WearItem { Id = "glasses", Row = 2, Name = "동그란 안경", Slot = Face, Price = 40 },
            new WearItem { Id = "scrubcap", Row = 3, Name = "수술모", Slot = Head, Price = 60 },
            new WearItem { Id = "steth", Row = 4, Name = "청진기", Slot = Neck, Price = 80 },
            new WearItem { Id = "gradcap", Row = 5, Name = "학사모", Slot = Head, Price = 120 },
            new WearItem { Id = "crown", Row = 6, Name = "왕관", Slot = Head, Price = 250 },
            new WearItem { Id = "medal", Row = 7, Name = "메달", Slot = Neck, Price = 0, Note = "한 과목에서 100문제를 맞히면 받아요" },
        };

        static bool loaded;
        static int minis, dayCount, streak;
        static string day = "";
        static HashSet<string> owned = new HashSet<string>();
        static Dictionary<string, string> worn = new Dictionary<string, string>();
        static Dictionary<string, int> topicCorrect = new Dictionary<string, int>();

        static string FilePath { get { return Path.Combine(Config.Dir, "wardrobe.json"); } }
        static string Today { get { return DateTime.Now.ToString("yyyy-MM-dd"); } }

        /// 저장한 것을 다시 읽는다 (자체 점검에서 폴더를 바꾼 뒤에도 쓴다).
        public static void Reload()
        {
            loaded = true;
            minis = dayCount = streak = 0;
            day = "";
            owned = new HashSet<string>();
            worn = new Dictionary<string, string>();
            topicCorrect = new Dictionary<string, int>();
            try
            {
                if (!File.Exists(FilePath)) return;
                var j = Json.Parse(File.ReadAllText(FilePath, Encoding.UTF8));
                double v;
                if (Json.Number(j, "minis", out v)) minis = Math.Max(0, (int)v);
                if (Json.Number(j, "dayCount", out v)) dayCount = Math.Max(0, (int)v);
                day = Json.Str(j, "day") ?? "";
                var o = Json.Strings(j, "owned");
                if (o != null) owned = new HashSet<string>(o);
                object x;
                var d = j.TryGetValue("worn", out x) ? x as IDictionary<string, object> : null;
                if (d != null) foreach (var kv in d) if (kv.Value != null) worn[kv.Key] = kv.Value.ToString();
                d = j.TryGetValue("topicCorrect", out x) ? x as IDictionary<string, object> : null;
                if (d != null) foreach (var kv in d) topicCorrect[kv.Key] = Convert.ToInt32(kv.Value);
            }
            catch (Exception e) { Log.Write("wardrobe.json 을 읽지 못함: " + e.Message); }
        }

        static void Load() { if (!loaded) Reload(); }

        static void Save()
        {
            try
            {
                var j = new Dictionary<string, object>
                {
                    { "minis", minis }, { "day", day }, { "dayCount", dayCount },
                    { "owned", owned.OrderBy(s => s).ToList() }, { "worn", worn }, { "topicCorrect", topicCorrect },
                };
                File.WriteAllText(FilePath, Json.Write(j), new UTF8Encoding(false));
            }
            catch (Exception e) { Log.Write("wardrobe.json 을 쓰지 못함: " + e.Message); }
            if (Changed != null) Changed();
        }

        public static int Minis { get { Load(); return minis; } }
        public static int EarnedToday { get { Load(); return day == Today ? dayCount : 0; } }
        public static bool Owns(string id) { Load(); return owned.Contains(id); }
        public static bool IsWorn(string id) { Load(); return worn.Values.Contains(id); }
        public static WearItem Item(string id) { return Items.FirstOrDefault(i => i.Id == id); }

        /// 꼬마 뱁새를 n 마리 받는다. 하루 상한을 넘는 만큼은 버린다. 실제로 받은 수를 돌려준다.
        public static int Earn(int n)
        {
            Load();
            int today = EarnedToday;
            int got = Math.Max(0, Math.Min(n, DailyCap - today));
            if (got <= 0) return 0;
            day = Today;
            dayCount = today + got;
            minis += got;
            Save();
            return got;
        }

        /// 문제에 답했을 때. popped: 5연속에 펑 터지는 동작이 켜져 있는지 (꺼져 있으면 5연속 보너스를 바로 준다).
        /// 돌려주는 값: 이번 답으로 받은 꼬마 뱁새 수
        public static int Answered(bool correct, string topic, bool popped)
        {
            Load();
            if (!correct) { streak = 0; return 0; }
            streak++;
            int got = Earn(1);
            if (streak >= 5)
            {
                streak = 0;
                if (!popped) got += Earn(10);
            }
            if (!string.IsNullOrEmpty(topic))
            {
                int n;
                topicCorrect.TryGetValue(topic, out n);
                topicCorrect[topic] = n + 1;
                if (n + 1 >= MedalGoal) owned.Add("medal");
                Save();
            }
            return got;
        }

        public static bool Buy(string id)
        {
            Load();
            WearItem it = Item(id);
            if (it == null || it.Price <= 0 || owned.Contains(id) || minis < it.Price) return false;
            minis -= it.Price;
            owned.Add(id);
            Save();
            return true;
        }

        /// 입히거나(같은 자리의 다른 물건은 벗는다), 이미 입고 있으면 벗긴다.
        public static void ToggleWear(string id)
        {
            Load();
            WearItem it = Item(id);
            if (it == null || !owned.Contains(id)) return;
            string now;
            if (worn.TryGetValue(it.Slot, out now) && now == id) worn.Remove(it.Slot); else worn[it.Slot] = id;
            Save();
        }

        static int[] Rows(Dictionary<string, string> w)
        {
            var rows = new List<int>();
            foreach (string slot in new[] { Neck, Face, Head })          // 목 → 얼굴 → 머리 순서로 겹친다
            {
                string id;
                if (w.TryGetValue(slot, out id) && Item(id) != null) rows.Add(Item(id).Row);
            }
            return rows.ToArray();
        }

        /// 입은 물건의 줄 번호
        public static int[] WornRows { get { Load(); return Rows(worn); } }

        /// 이 물건을 입혀 본 모습 (지금 입은 것에서 같은 자리만 바꾼다)
        public static int[] RowsTrying(string id)
        {
            Load();
            WearItem it = Item(id);
            if (it == null) return WornRows;
            var w = new Dictionary<string, string>(worn);
            w[it.Slot] = id;
            return Rows(w);
        }

        /// 메달까지 가장 가까운 과목과 맞힌 수 ("" 이면 아직 없음)
        public static string BestTopic(out int count)
        {
            Load();
            count = 0;
            string best = "";
            foreach (var kv in topicCorrect) if (kv.Value > count) { count = kv.Value; best = kv.Key; }
            return best;
        }

        public static void DebugGrant(int n) { Load(); minis += n; Save(); }       // 자체 점검용
    }

    /// 옷장 창: 가진 꼬마 뱁새 수, 입은 모습, 물건 목록.
    sealed class WardrobeForm : Form
    {
        readonly Pet pet;
        const int RowH = 56, W = 440;

        public WardrobeForm(Pet pet)
        {
            this.pet = pet;
            Text = "옷장";
            Font = new Font("Malgun Gothic", 9f);
            AutoScaleMode = AutoScaleMode.None;         // 좌표는 96dpi 기준으로 적고 Dpi.R() 로 맞춘다
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            ClientSize = new Size(Dpi.S(W), Dpi.S(150 + RowH * Wardrobe.Items.Length + 40));
            Dpi.FitToScreen(this);
            Wardrobe.Changed += OnChanged;
            Render();
        }

        void OnChanged() { if (!IsDisposed && Visible) Render(); }

        static Label Text_(string text, Rectangle r, float size, FontStyle style, Color color)
        {
            return new Label { Text = text, Bounds = r, Font = new Font("Malgun Gothic", size, style), ForeColor = color, BackColor = Color.Transparent, AutoEllipsis = true };
        }

        PictureBox Picture(int[] rows, Rectangle r, int scale)
        {
            return new PictureBox { Image = pet.PreviewImage(rows, Dpi.S(scale)), SizeMode = PictureBoxSizeMode.CenterImage, Bounds = r };
        }

        public void Render()
        {
            SuspendLayout();
            foreach (Control c in Controls.Cast<Control>().ToList())
            {
                Controls.Remove(c);
                var p = c as PictureBox;
                if (p != null && p.Image != null) p.Image.Dispose();
                c.Dispose();
            }
            Controls.Add(Picture(Wardrobe.WornRows, Dpi.R(20, 16, 144, 112), 4));
            Controls.Add(Text_("꼬마 뱁새 " + Wardrobe.Minis + "마리", Dpi.R(180, 28, 240, 30), 15f, FontStyle.Bold, Color.FromArgb(28, 28, 30)));
            Controls.Add(Text_("오늘 받은 수 " + Wardrobe.EarnedToday + " / " + Wardrobe.DailyCap, Dpi.R(181, 60, 240, 18), 9f, FontStyle.Regular, Color.Gray));
            Controls.Add(Text_("문제를 맞히면 1마리. 다섯 번 연속으로 맞혀 펑 터지면, 흩어지는 꼬마들을 눌러서 잡으세요.",
                Dpi.R(181, 82, 244, 36), 8.25f, FontStyle.Regular, Color.Gray));
            Controls.Add(new Label { Bounds = Dpi.R(20, 138, W - 40, 1), BackColor = Color.FromArgb(225, 225, 225) });

            int y = 146;
            foreach (WearItem item in Wardrobe.Items)
            {
                WearItem it = item;
                bool have = Wardrobe.Owns(it.Id), wearing = Wardrobe.IsWorn(it.Id);
                Controls.Add(Picture(have ? Wardrobe.RowsTrying(it.Id) : new[] { it.Row }, Dpi.R(20, y, 72, 56), 2));
                Controls.Add(Text_(it.Name, Dpi.R(100, y + 9, 200, 20), 9.75f, FontStyle.Bold, Color.FromArgb(28, 28, 30)));
                string sub = it.Slot;
                if (!have)
                {
                    if (it.Price > 0) sub += "  ·  꼬마 뱁새 " + it.Price + "마리";
                    else
                    {
                        int n;
                        string topic = Wardrobe.BestTopic(out n);
                        sub += "  ·  " + it.Note + (topic.Length > 0 ? " (" + topic + " " + n + "/" + Wardrobe.MedalGoal + ")" : "");
                    }
                }
                else if (wearing) sub += "  ·  입고 있어요";
                bool button = have || it.Price > 0;
                Controls.Add(Text_(sub, Dpi.R(100, y + 30, button ? 210 : 320, 18), 8.25f, FontStyle.Regular, Color.Gray));
                if (button)
                {
                    var b = new Button { Text = have ? (wearing ? "벗기" : "입히기") : "사기", Bounds = Dpi.R(W - 116, y + 12, 96, 30), FlatStyle = FlatStyle.System };
                    b.Enabled = have || Wardrobe.Minis >= it.Price;
                    b.Click += (s, e) =>
                    {
                        if (Wardrobe.Owns(it.Id)) Wardrobe.ToggleWear(it.Id);
                        else if (Wardrobe.Buy(it.Id)) Wardrobe.ToggleWear(it.Id);        // 사자마자 입혀 본다
                    };
                    Controls.Add(b);
                }
                y += RowH;
            }
            Controls.Add(Text_("꼬마 뱁새와 옷은 이 컴퓨터에만 저장됩니다.", Dpi.R(20, y + 10, W - 40, 18), 8.25f, FontStyle.Regular, Color.DarkGray));
            ResumeLayout();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            Wardrobe.Changed -= OnChanged;
            base.OnFormClosing(e);
        }

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
