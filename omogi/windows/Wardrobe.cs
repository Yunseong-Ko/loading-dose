// 꼬마 뱁새(문제를 맞히면 모이는 것)와 옷장. Mac 판의 wardrobe.swift 와 같은 규칙이다.
// 전부 내 컴퓨터(%APPDATA%\Omogi\wardrobe.json)에 저장한다. 입은 옷과 오늘 맞힌 수는 마을(Village.cs)이 친구에게 보인다.
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
        public const int MedalGoal = 100;       // 한 과목에서 이만큼 맞히면 그 과목 배지
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
        };

        /// 과목별 배지: 그 과목에서 MedalGoal 문제를 맞히면 받는다. 순서는 packs/kmle.txt 의 과목 순서이고 wear.png 의 8번째 줄부터다.
        public static readonly string[] Topics =
        {
            "해부학", "생화학", "생리학", "병리학", "약리학", "순환기", "호흡기", "소화기", "신장", "내분비", "혈액", "종양", "감염",
            "알레르기", "류마티스", "외과 총론", "외과 각론", "산과", "부인과", "소아청소년과 총론", "소아청소년과 각론",
            "정신건강의학과", "마이너", "예방의학", "의료법규",
        };
        public static readonly WearItem[] Badges = Topics.Select((t, i) =>
            new WearItem { Id = "badge" + i, Row = 8 + i, Name = t + " 배지", Slot = Neck, Price = 0, Note = t }).ToArray();

        static bool loaded;
        static int minis, dayCount, streak, correctCount;
        static string day = "", correctDay = "";
        static HashSet<string> owned = new HashSet<string>();
        static Dictionary<string, string> worn = new Dictionary<string, string>();
        static Dictionary<string, int> topicCorrect = new Dictionary<string, int>();

        static string FilePath { get { return Path.Combine(Config.Dir, "wardrobe.json"); } }
        static string Today { get { return DateTime.Now.ToString("yyyy-MM-dd"); } }

        /// 저장한 것을 다시 읽는다 (자체 점검에서 폴더를 바꾼 뒤에도 쓴다).
        public static void Reload()
        {
            loaded = true;
            minis = dayCount = streak = correctCount = 0;
            day = correctDay = "";
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
                if (Json.Number(j, "ccount", out v)) correctCount = Math.Max(0, (int)v);
                correctDay = Json.Str(j, "cday") ?? "";
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
                    { "minis", minis }, { "day", day }, { "dayCount", dayCount }, { "cday", correctDay }, { "ccount", correctCount },
                    { "owned", owned.OrderBy(s => s).ToList() }, { "worn", worn }, { "topicCorrect", topicCorrect },
                };
                File.WriteAllText(FilePath, Json.Write(j), new UTF8Encoding(false));
            }
            catch (Exception e) { Log.Write("wardrobe.json 을 쓰지 못함: " + e.Message); }
            if (Changed != null) Changed();
        }

        public static int Minis { get { Load(); return minis; } }
        public static int EarnedToday { get { Load(); return day == Today ? dayCount : 0; } }
        public static bool IsWorn(string id) { Load(); return worn.Values.Contains(id); }
        public static WearItem Item(string id) { return Items.FirstOrDefault(i => i.Id == id) ?? Badges.FirstOrDefault(i => i.Id == id); }
        public static string TodayKey { get { return Today; } }

        /// 가진 물건인지: 산 것, 또는 조건을 채운 과목 배지
        public static bool Owns(string id)
        {
            Load();
            if (owned.Contains(id)) return true;
            WearItem b = Badges.FirstOrDefault(i => i.Id == id);
            return b != null && TopicCount(b.Note) >= MedalGoal;
        }

        /// 그 과목에서 지금까지 맞힌 수
        public static int TopicCount(string topic)
        {
            Load();
            int n;
            return topicCorrect.TryGetValue(topic ?? "", out n) ? n : 0;
        }

        /// 오늘 맞힌 문제 수 (마을에서 친구에게 보인다)
        public static int CorrectToday { get { Load(); return correctDay == Today ? correctCount : 0; } }

        /// 입은 옷의 이름들을 겹치는 순서대로 (서버에 올리는 값, 예: "scarf,glasses,straw")
        public static string WornNames
        {
            get
            {
                Load();
                var names = new List<string>();
                foreach (string slot in new[] { Neck, Face, Head })
                {
                    string id;
                    if (worn.TryGetValue(slot, out id) && !string.IsNullOrEmpty(id)) names.Add(id);
                }
                return string.Join(",", names);
            }
        }

        /// 친구가 올린 옷 이름들을 줄 번호로 바꾼다 (모르는 이름은 건너뛴다).
        public static int[] RowsForNames(string names)
        {
            var rows = new List<int>();
            foreach (string n in (names ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                WearItem it = Item(n.Trim());
                if (it != null) rows.Add(it.Row);
            }
            return rows.ToArray();
        }

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
            correctCount = CorrectToday + 1;
            correctDay = Today;
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
            }
            Save();
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
            if (it == null || !Owns(id)) return;
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

        public static void DebugGrant(int n) { Load(); minis += n; Save(); }       // 자체 점검용
    }

    /// 옷장 창: 가진 꼬마 뱁새 수, 입은 모습, 물건 목록, 과목 배지.
    sealed class WardrobeForm : Form
    {
        readonly Pet pet;
        const int RowH = 46, CellH = 44, W = 440;

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
            ClientSize = new Size(Dpi.S(W), Dpi.S(146 + RowH * Wardrobe.Items.Length + 36 + CellH * 5 + 36));
            Dpi.FitToScreen(this);
            Wardrobe.Changed += OnChanged;
            Render();
        }

        void OnChanged() { if (!IsDisposed && Visible) Render(); }

        static Label Text_(string text, Rectangle r, float size, FontStyle style, Color color)
        {
            return new Label { Text = text, Bounds = r, Font = new Font("Malgun Gothic", size, style), ForeColor = color, BackColor = Color.Transparent, AutoEllipsis = true };
        }

        // cropTop: 그림 위쪽의 빈 줄을 이만큼(스프라이트 픽셀) 잘라 낸다 (줄 간격이 좁은 목록에서 쓴다).
        PictureBox Picture(int[] rows, Rectangle r, int scale, int cropTop = 0)
        {
            Bitmap image = pet.PreviewImage(rows, Dpi.S(scale));
            if (image != null && cropTop > 0)
            {
                int cut = cropTop * Dpi.S(scale);
                Bitmap cropped = image.Clone(new Rectangle(0, cut, image.Width, image.Height - cut), image.PixelFormat);
                image.Dispose();
                image = cropped;
            }
            return new PictureBox { Image = image, SizeMode = PictureBoxSizeMode.CenterImage, Bounds = r };
        }

        public void Render()
        {
            SuspendLayout();
            Point scroll = AutoScrollPosition;          // 스크롤된 채로 다시 그리면 자리가 어긋난다
            if (AutoScroll) AutoScrollPosition = Point.Empty;
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
                Controls.Add(Picture(have ? Wardrobe.RowsTrying(it.Id) : new[] { it.Row }, Dpi.R(20, y, 72, RowH), 2, 5));
                Controls.Add(Text_(it.Name, Dpi.R(100, y + 4, 200, 20), 9.75f, FontStyle.Bold, Color.FromArgb(28, 28, 30)));
                string sub = it.Slot;
                if (!have) sub += "  ·  꼬마 뱁새 " + it.Price + "마리";
                else if (wearing) sub += "  ·  입고 있어요";
                Controls.Add(Text_(sub, Dpi.R(100, y + 24, 210, 18), 8.25f, FontStyle.Regular, Color.Gray));
                var b = new Button { Text = have ? (wearing ? "벗기" : "입히기") : "사기", Bounds = Dpi.R(W - 116, y + 8, 96, 30), FlatStyle = FlatStyle.System };
                b.Enabled = have || Wardrobe.Minis >= it.Price;
                b.Click += (s, e) =>
                {
                    if (Wardrobe.Owns(it.Id)) Wardrobe.ToggleWear(it.Id);
                    else if (Wardrobe.Buy(it.Id)) Wardrobe.ToggleWear(it.Id);        // 사자마자 입혀 본다
                };
                Controls.Add(b);
                y += RowH;
            }

            // 과목 배지: 한 과목에서 100문제를 맞히면 받는다. 받은 것은 누르면 달고, 다시 누르면 뗀다.
            Controls.Add(new Label { Bounds = Dpi.R(20, y + 4, W - 40, 1), BackColor = Color.FromArgb(225, 225, 225) });
            Controls.Add(Text_("과목 배지 — 한 과목에서 " + Wardrobe.MedalGoal + "문제를 맞히면 받아요 (목에 답니다)", Dpi.R(20, y + 12, W - 40, 18), 8.25f, FontStyle.Regular, Color.Gray));
            int top = y + 36, cw = (W - 40) / 5;
            for (int i = 0; i < Wardrobe.Badges.Length; i++)
            {
                WearItem it = Wardrobe.Badges[i];
                bool have = Wardrobe.Owns(it.Id);
                string name = it.Note.Replace("소아청소년과", "소아").Replace("정신건강의학과", "정신");
                var b = new Button
                {
                    Text = (Wardrobe.IsWorn(it.Id) ? "● " : "") + name + "\n" + (have ? "받음" : Wardrobe.TopicCount(it.Note) + "/" + Wardrobe.MedalGoal),
                    Bounds = Dpi.R(20 + (i % 5) * cw, top + (i / 5) * CellH, cw - 4, CellH - 4),
                    Font = new Font("Malgun Gothic", 8f, have ? FontStyle.Bold : FontStyle.Regular),
                    FlatStyle = FlatStyle.Flat, BackColor = have ? Color.FromArgb(246, 246, 248) : Color.White,
                    ForeColor = Color.FromArgb(28, 28, 30), Enabled = have, UseMnemonic = false, Padding = Padding.Empty,
                };
                b.FlatAppearance.BorderSize = have ? 1 : 0;
                b.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 205);
                b.Click += (s, e) => Wardrobe.ToggleWear(it.Id);
                Controls.Add(b);
            }
            Controls.Add(Text_("이 컴퓨터에 저장됩니다. 입은 옷은 마을에서 친구에게 보여요.", Dpi.R(20, top + CellH * 5 + 8, W - 40, 18), 8.25f, FontStyle.Regular, Color.DarkGray));
            if (AutoScroll) AutoScrollPosition = new Point(-scroll.X, -scroll.Y);
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
