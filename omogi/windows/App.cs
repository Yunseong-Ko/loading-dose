// Omogi — 화면에 사는 작은 뱁새 (Windows 트레이 앱). Mac 판 omogi/main.swift 에 해당한다.
// 펫(Pet.cs), O/X 퀴즈(Quiz.cs), 친구와 주고받는 편지(Letters.cs, Server.cs)를 묶고, 트레이 메뉴와 설정 창을 만든다.
// 조정: %APPDATA%\Omogi\config.json   기록: 같은 폴더의 debug.log

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using WinTimer = System.Windows.Forms.Timer;

namespace Omogi
{
    // 켜져 있는 설정 하나 (설정 창과 메뉴가 같이 쓴다)
    sealed class Toggle
    {
        public string Title, MenuTitle, Note;
        public Func<bool> Get;
        public Action Flip;
    }

    sealed class TrayApp : ApplicationContext
    {
        public readonly Pet Pet = new Pet();
        public readonly QuizWatcher Quiz;
        public readonly LetterBox Letters;
        public readonly LetterWindows LetterWindows;
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly ToolStripMenuItem statusItem = new ToolStripMenuItem("") { Enabled = false };
        readonly ToolStripMenuItem inboxItem = new ToolStripMenuItem("편지함…");
        readonly ToolStripMenuItem startupItem = new ToolStripMenuItem("Windows 를 켤 때 같이 실행");
        readonly List<KeyValuePair<Toggle, ToolStripMenuItem>> toggleItems = new List<KeyValuePair<Toggle, ToolStripMenuItem>>();
        public readonly List<Toggle> Toggles = new List<Toggle>();
        SettingsForm settings;
        SubjectsForm subjects;
        Icon trayIcon;

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public TrayApp()
        {
            Log.Start();
            Config.Load();
            Quiz = new QuizWatcher(Pet);
            Letters = new LetterBox(Pet);
            LetterWindows = new LetterWindows(Letters);
            Pet.OnMailOpen = () => LetterWindows.ShowInbox();
            Letters.Changed += () => { if (settings != null && settings.Visible) settings.RefreshState(); };

            Toggles.Add(new Toggle
            {
                Title = "오모기 보이기", MenuTitle = "오모기 보이기",
                Note = "작업 표시줄 위에서 돌아다닙니다. 집어서 옮기거나 던질 수 있어요.",
                Get = () => Settings.PetOn, Flip = () => Pet.SetEnabled(!Settings.PetOn),
            });
            Toggles.Add(new Toggle
            {
                Title = "습관 알림", MenuTitle = "습관 알림 — 물·눈 쉬기·스트레칭",
                Note = "물 마시기, 눈 쉬기, 스트레칭을 때맞춰 알려 줍니다.",
                Get = () => Settings.HabitsOn, Flip = () => Settings.HabitsOn = !Settings.HabitsOn,
            });
            Toggles.Add(new Toggle
            {
                Title = "O/X — AI 답변을 기다리는 동안", MenuTitle = "O/X — AI 답변을 기다리는 동안 문제 띄우기",
                Note = "Claude·ChatGPT 앱에서 Enter 누르고 기다릴 때 뜹니다.",
                Get = () => Settings.QuizEnterOn,
                Flip = () =>
                {
                    Settings.QuizEnterOn = !Settings.QuizEnterOn;
                    Log.Write("퀴즈 Enter 감지 " + (Settings.QuizEnterOn ? "켬" : "끔"));
                    Quiz.UpdateHook();
                },
            });
            Toggles.Add(new Toggle
            {
                Title = "O/X — 가끔 물어 오기", MenuTitle = "O/X — 가끔 오모기가 문제 물어 오기",
                Note = "오모기가 가끔 문제를 물고 옵니다. 누르면 펼쳐져요.",
                Get = () => Settings.QuizBringOn, Flip = () => Settings.QuizBringOn = !Settings.QuizBringOn,
            });

            BuildMenu();
            Letters.Start();
            Quiz.Start();
            Log.Write("──── 실행 v" + AppInfo.Version + " 문제=" + Quiz.Deck.BuiltinCount + "+" + Quiz.Deck.OwnCount
                + " server=" + (Server.Shared != null) + " OS=" + Environment.OSVersion.Version);
            Pet.Start();

            // 처음 켰을 때는 설정 창을 보여 준다 (트레이 아이콘이 ^ 안에 숨어 안 보이는 PC 가 많다).
            if (!Settings.Welcomed)
            {
                Settings.Welcomed = true;
                var once = new WinTimer { Interval = 600 };
                once.Tick += (s, e) => { once.Stop(); once.Dispose(); ShowSettings(); };
                once.Start();
            }
        }

        // ── 트레이 메뉴 (오모기를 오른쪽 클릭해도 같은 메뉴가 뜬다) ──
        void BuildMenu()
        {
            try
            {
                using (Bitmap face = Pet.FaceImage(32))
                {
                    if (face != null)
                    {
                        using (var square = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
                        {
                            using (Graphics g = Graphics.FromImage(square)) g.DrawImage(face, (32 - face.Width) / 2, 0, face.Width, face.Height);
                            trayIcon = Icon.FromHandle(square.GetHicon());
                        }
                    }
                }
            }
            catch { }
            if (trayIcon == null)
            {
                try { trayIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            }
            tray.Icon = trayIcon ?? SystemIcons.Application;
            tray.Text = "Omogi";

            menu.Items.Add(statusItem);
            menu.Items.Add(new ToolStripSeparator());
            for (int i = 0; i < Toggles.Count; i++)
            {
                Toggle t = Toggles[i];
                var item = new ToolStripMenuItem(t.MenuTitle);
                item.Click += (s, e) => FlipToggle(t);
                toggleItems.Add(new KeyValuePair<Toggle, ToolStripMenuItem>(t, item));
                if (i == 2) menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add(item);
            }
            menu.Items.Add("지금 한 문제 풀기", null, (s, e) => Quiz.SolveOne());
            menu.Items.Add("O/X 과목 고르기…", null, (s, e) => ShowSubjects());
            menu.Items.Add("내 문제 편집…", null, (s, e) => EditOwn());
            menu.Items.Add("내 문제 다시 읽기", null, (s, e) => { Quiz.Deck.LoadOwn(); Notify("내 문제 " + Quiz.Deck.OwnCount + "개를 읽었습니다."); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("편지 쓰기…", null, (s, e) => LetterWindows.ShowCompose());
            inboxItem.Click += (s, e) => LetterWindows.ShowInbox();
            menu.Items.Add(inboxItem);
            menu.Items.Add("친구…", null, (s, e) => LetterWindows.ShowFriends());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("설정 창 열기…", null, (s, e) => ShowSettings());
            var preview = new ToolStripMenuItem("동작 보기");
            foreach (var p in new[]
            {
                new[] { "물 마시기", "drink" }, new[] { "둥지 짓고 자기", "nest" }, new[] { "꾸벅꾸벅 졸기", "nod" },
                new[] { "졸다가 구르기", "roll" }, new[] { "날아서 옮겨 가기", "fly" }, new[] { "앞 보고 기우뚱", "tilt" },
                new[] { "눈 쉬기", "eyes" }, new[] { "기지개 켜기", "stretch" }, new[] { "문제 물어 오기 (예시)", "quizIn" },
                new[] { "편지 물고 나가기", "mailOut" }, new[] { "편지 받아 오기 (예시)", "mailIn" }, new[] { "편지 잃어버림 (예시)", "lost" },
            })
            {
                string key = p[1];
                preview.DropDownItems.Add(p[0], null, (s, e) => Pet.Preview(key));
            }
            menu.Items.Add(preview);
            startupItem.Click += (s, e) => { SetStartup(!StartupOn); RefreshMenu(); };
            menu.Items.Add(startupItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("진단 정보 복사", null, (s, e) => CopyDiagnostics());
            menu.Items.Add("진단 기록 파일 열기", null, (s, e) => OpenInNotepad(Log.FilePath));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Omogi 종료", null, (s, e) => Quit());
            menu.Opening += (s, e) => RefreshMenu();
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += (s, e) => ShowSettings();
            tray.Visible = true;
            Pet.Menu = menu;
            RefreshMenu();
        }

        public void FlipToggle(Toggle t)
        {
            try { t.Flip(); } catch (Exception e) { Log.Write("설정을 바꾸지 못함: " + e.Message); }
            RefreshMenu();
            if (settings != null && settings.Visible) settings.RefreshState();
        }

        void RefreshMenu()
        {
            foreach (var kv in toggleItems) kv.Value.Checked = kv.Key.Get();
            int unread = Letters.UnreadCount;
            inboxItem.Text = unread > 0 ? "편지함… (새 편지 " + unread + "통)" : "편지함…";
            startupItem.Checked = StartupOn;
            if (Settings.QuizEnterOn && Quiz.HookFailed) statusItem.Text = "키 감지를 켜지 못했어요 — Enter 를 눌러도 문제가 안 뜹니다";
            else if (!Settings.PetOn) statusItem.Text = "오모기가 숨어 있어요";
            else statusItem.Text = "오모기가 작업 표시줄 위에 있어요 — 집어서 옮길 수 있어요";
        }

        public int UnreadLetters { get { return Letters.UnreadCount; } }

        public void ShowSettings()
        {
            if (settings == null || settings.IsDisposed) settings = new SettingsForm(this);
            settings.RefreshState();
            settings.Show();
            if (settings.WindowState == FormWindowState.Minimized) settings.WindowState = FormWindowState.Normal;
            settings.Activate();
        }

        public SettingsForm SettingsWindow
        {
            get
            {
                if (settings == null || settings.IsDisposed) settings = new SettingsForm(this);
                return settings;
            }
        }

        public void ShowSubjects()
        {
            if (subjects == null || subjects.IsDisposed) subjects = new SubjectsForm(Quiz.Deck);
            subjects.Reload();
            subjects.Show();
            subjects.Activate();
        }

        public void Notify(string text)
        {
            try { tray.ShowBalloonTip(4000, "Omogi", text, ToolTipIcon.Info); } catch { }
        }

        void EditOwn()
        {
            try
            {
                Quiz.Deck.EnsureOwnFile();
                Process.Start("notepad.exe", "\"" + Deck.OwnFile + "\"");
            }
            catch (Exception e) { Notify("파일을 열지 못했습니다: " + e.Message); }
        }

        static void OpenInNotepad(string path)
        {
            try
            {
                if (!File.Exists(path)) File.WriteAllText(path, "");
                Process.Start("notepad.exe", "\"" + path + "\"");
            }
            catch { }
        }

        // ── Windows 를 켤 때 같이 실행 (현재 사용자의 시작 프로그램 목록에 넣는다) ──
        static bool StartupOn
        {
            get
            {
                try
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey))
                        return k != null && k.GetValue("Omogi") != null;
                }
                catch { return false; }
            }
        }

        static void SetStartup(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (k == null) return;
                    if (on) k.SetValue("Omogi", "\"" + Application.ExecutablePath + "\"");
                    else k.DeleteValue("Omogi", false);
                }
                Log.Write("시작할 때 같이 실행 " + (on ? "켬" : "끔"));
            }
            catch (Exception e) { Log.Write("시작 프로그램 설정을 바꾸지 못함: " + e.Message); }
        }

        // ── 진단 ──
        void CopyDiagnostics()
        {
            IntPtr hwnd;
            string line = Quiz.Diagnostics(out hwnd);
            string petState = Pet.DebugState;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var sb = new StringBuilder();
                sb.AppendLine("Omogi 진단 정보 (보내기 전에 내용을 한 번 확인하세요. 버튼 이름에 대화 제목이 섞일 수 있습니다.)");
                sb.AppendLine("버전 " + AppInfo.Version + " / Windows " + Environment.OSVersion.Version + " / 64비트 프로세스 " + Environment.Is64BitProcess);
                sb.AppendLine("펫: " + petState);
                sb.AppendLine("퀴즈: Enter 감지 " + (Settings.QuizEnterOn ? "켬" : "끔") + " / 물어 오기 " + (Settings.QuizBringOn ? "켬" : "끔") + " / " + line);
                sb.AppendLine("편지 서버 설정: " + (Server.Shared != null ? "있음" : "없음"));
                if (Settings.QuizEnterOn)
                {
                    if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd))
                        sb.AppendLine("대상 앱 창을 아직 보지 못했습니다. Claude나 ChatGPT 앱 창을 한 번 앞으로 가져온 뒤 다시 눌러 주세요.");
                    else sb.AppendLine(Scanner.Dump(hwnd));
                }
                string text = sb.ToString();
                Ui.Post(() =>
                {
                    try { Clipboard.SetText(text); Notify("진단 정보를 복사했습니다. 붙여넣어 보내 주세요."); }
                    catch (Exception e) { Notify("복사하지 못했습니다: " + e.Message); }
                });
            });
        }

        public void Quit()
        {
            tray.Visible = false;
            Quiz.Stop();
            Pet.Stop();
            ExitThread();
        }
    }

    // ───────────────────────── 설정 창 ─────────────────────────
    // 트레이 메뉴와 같은 일을 하는 창. 앱을 처음 켰을 때와, 켜져 있는 앱을 다시 실행했을 때 뜬다.
    // 화면 배율(100%, 125%, 150%…)에 맞춰 96dpi 기준 좌표를 늘린다.
    // WinForms 의 자동 배율은 컨트롤을 넣는 순서에 따라 일부만 늘어나는 일이 있어 쓰지 않는다
    // (글자만 커지고 창과 칸은 그대로여서 설정 항목이 잘려 보였다).
    static class Dpi
    {
        static float k;
        public static float K
        {
            get
            {
                if (k <= 0f)
                {
                    k = 1f;
                    try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) k = Math.Max(1f, g.DpiX / 96f); }
                    catch { }
                }
                return k;
            }
        }
        public static void Force(float value) { k = value; }      // 자체 점검용: 다른 배율을 흉내 낸다
        public static int S(int v) { return (int)Math.Round(v * K); }
        public static Rectangle R(int x, int y, int w, int h) { return new Rectangle(S(x), S(y), S(w), S(h)); }

        // 창이 화면보다 길면 화면 높이에 맞추고 세로로 스크롤할 수 있게 한다.
        public static void FitToScreen(Form f)
        {
            try
            {
                int room = Screen.PrimaryScreen.WorkingArea.Height - S(60);
                if (f.ClientSize.Height <= room) return;
                f.AutoScrollMinSize = new Size(0, f.ClientSize.Height);
                f.AutoScroll = true;
                f.ClientSize = new Size(f.ClientSize.Width + SystemInformation.VerticalScrollBarWidth, room);
            }
            catch { }
        }
    }

    sealed class SettingsForm : Form
    {
        readonly TrayApp app;
        readonly List<CheckBox> boxes = new List<CheckBox>();
        readonly Button inbox;
        bool refreshing;

        public SettingsForm(TrayApp app)
        {
            this.app = app;
            Text = "Omogi";
            Font = new Font("Malgun Gothic", 9f);
            AutoScaleMode = AutoScaleMode.None;         // 자동 배율은 쓰지 않는다. 좌표는 96dpi 기준으로 적고 Dpi.R() 로 직접 맞춘다.
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.White;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            Bitmap face = app.Pet.FaceImage(Dpi.S(46));
            if (face != null)
                Controls.Add(new PictureBox { Image = face, SizeMode = PictureBoxSizeMode.Normal, Bounds = Dpi.R(24, 20, 40, 46) });
            Controls.Add(Label("Omogi", Dpi.R(76, 20, 300, 26), 13.5f, FontStyle.Bold, Color.FromArgb(28, 28, 30)));
            Controls.Add(Label("화면에 사는 작은 뱁새", Dpi.R(77, 46, 300, 18), 9f, FontStyle.Regular, Color.Gray));

            int y = 84;
            foreach (Toggle t in app.Toggles)
            {
                Toggle toggle = t;
                var box = new CheckBox { Text = t.Title, Bounds = Dpi.R(24, y, 372, 22), Font = new Font("Malgun Gothic", 9.75f, FontStyle.Bold) };
                box.CheckedChanged += (s, e) => { if (!refreshing) app.FlipToggle(toggle); };
                boxes.Add(box);
                Controls.Add(box);
                Controls.Add(Label(t.Note, Dpi.R(42, y + 22, 360, 18), 8.25f, FontStyle.Regular, Color.Gray));
                y += 52;
            }

            Controls.Add(new Label { Bounds = Dpi.R(24, y + 2, 372, 1), BackColor = Color.FromArgb(225, 225, 225) });
            y += 14;
            var write = Button("편지 쓰기…", Dpi.R(22, y, 122, 32), () => app.LetterWindows.ShowCompose());
            inbox = Button("편지함…", Dpi.R(149, y, 122, 32), () => app.LetterWindows.ShowInbox());
            var friends = Button("친구…", Dpi.R(276, y, 122, 32), () => app.LetterWindows.ShowFriends());
            y += 38;
            var solve = Button("지금 한 문제 풀기", Dpi.R(22, y, 186, 32), () => app.Quiz.SolveOne());
            var pick = Button("O/X 과목 고르기…", Dpi.R(212, y, 186, 32), () => app.ShowSubjects());
            Controls.AddRange(new Control[] { write, inbox, friends, solve, pick });
            y += 44;

            Controls.Add(Label("이 창은 Omogi 를 다시 실행하면 언제든 뜹니다. 화면의 오모기를 오른쪽 클릭하거나, 작업 표시줄 오른쪽(시계 옆, 안 보이면 ^ 안)의 새 얼굴 아이콘을 오른쪽 클릭해도 같은 메뉴가 나와요.",
                Dpi.R(24, y, 374, 54), 8.25f, FontStyle.Regular, Color.Gray));
            y += 62;
            Controls.Add(Label(AppInfo.Credit + "  ·  v" + AppInfo.Version + " (Windows)", Dpi.R(24, y + 7, 250, 18), 8.25f, FontStyle.Regular, Color.DarkGray));
            Controls.Add(Button("Omogi 종료", Dpi.R(288, y, 110, 28), () => app.Quit()));
            ClientSize = new Size(Dpi.S(420), Dpi.S(y + 44));
            Dpi.FitToScreen(this);
        }

        static Label Label(string text, Rectangle r, float size, FontStyle style, Color color)
        {
            return new Label { Text = text, Bounds = r, Font = new Font("Malgun Gothic", size, style), ForeColor = color, BackColor = Color.Transparent };
        }

        static Button Button(string text, Rectangle r, Action act)
        {
            var b = new Button { Text = text, Bounds = r, FlatStyle = FlatStyle.System };
            b.Click += (s, e) => act();
            return b;
        }

        public void RefreshState()
        {
            refreshing = true;
            for (int i = 0; i < boxes.Count && i < app.Toggles.Count; i++) boxes[i].Checked = app.Toggles[i].Get();
            refreshing = false;
            int unread = app.UnreadLetters;
            inbox.Text = unread > 0 ? "편지함 (" + unread + ")…" : "편지함…";
        }

        // 닫으면 숨기기만 한다 (앱은 계속 돈다).
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            base.OnFormClosing(e);
        }

        // 자체 점검용: 창 밖으로 나간 항목이나, 칸보다 긴 한 줄 글자가 있으면 그 이름을 돌려준다.
        public string LayoutProblem(bool measureText)
        {
            int w = ClientSize.Width, h = AutoScroll ? Math.Max(ClientSize.Height, AutoScrollMinSize.Height) : ClientSize.Height;
            foreach (Control c in Controls)
            {
                if (c.Left < 0 || c.Top < 0 || c.Right > w || c.Bottom > h) return "창 밖: " + c.Text + " " + c.Bounds;
                if (!measureText || c.Text.Length == 0 || c is Button) continue;
                Size need = TextRenderer.MeasureText(c.Text, c.Font);
                int room = c.Width - (c is CheckBox ? Dpi.S(20) : 0);
                if (c.Height < need.Height * 2 && need.Width > room) return "글자가 김: " + c.Text + " (" + need.Width + " > " + room + ")";
                if (need.Height > c.Height + 2 && c.Height < need.Height * 2) return "글자가 높음: " + c.Text;
            }
            return null;
        }

        public void Snapshot(string path)
        {
            using (var bmp = new Bitmap(Width, Height))
            {
                DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
                bmp.Save(path, ImageFormat.Png);
            }
        }
    }

    // ───────────────────────── O/X 과목 고르기 ─────────────────────────
    sealed class SubjectsForm : Form
    {
        readonly Deck deck;
        readonly CheckedListBox list = new CheckedListBox();
        readonly Label count = new Label();
        bool loading;

        public SubjectsForm(Deck deck)
        {
            this.deck = deck;
            Text = "O/X 과목 고르기";
            Font = new Font("Malgun Gothic", 9f);
            AutoScaleMode = AutoScaleMode.None;         // 자동 배율은 쓰지 않는다. 좌표는 96dpi 기준으로 적고 Dpi.R() 로 직접 맞춘다.
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(Dpi.S(380), Dpi.S(520));
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            count.Bounds = Dpi.R(18, 14, 344, 18);
            count.ForeColor = Color.Gray;
            list.Bounds = Dpi.R(16, 40, 348, 424);
            list.CheckOnClick = true;
            list.IntegralHeight = false;
            list.ItemCheck += (s, e) =>
            {
                if (loading) return;
                string topic = deck.Topics[e.Index];
                if (e.NewValue == CheckState.Checked) deck.PackOff.Remove(topic); else deck.PackOff.Add(topic);
                deck.SaveState();
                UpdateCount();
            };
            var allOn = new Button { Text = "모두 켜기", Bounds = Dpi.R(16, 476, 100, 30), FlatStyle = FlatStyle.System };
            allOn.Click += (s, e) => { deck.PackOff.Clear(); deck.SaveState(); Reload(); };
            var allOff = new Button { Text = "모두 끄기", Bounds = Dpi.R(122, 476, 100, 30), FlatStyle = FlatStyle.System };
            allOff.Click += (s, e) => { deck.PackOff = new HashSet<string>(deck.Topics); deck.SaveState(); Reload(); };
            Controls.AddRange(new Control[] { count, list, allOn, allOff });
        }

        void UpdateCount()
        {
            count.Text = "국시 대비 기본 문항 — 켜 둔 문항 " + deck.PackCount + "개";
        }

        public void Reload()
        {
            loading = true;
            list.Items.Clear();
            foreach (string t in deck.Topics) list.Items.Add(t + "  (" + deck.CountOf(t) + ")", !deck.PackOff.Contains(t));
            loading = false;
            UpdateCount();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
            base.OnFormClosing(e);
        }
    }

    // 빌드 서버(Windows)에서 돌리는 자체 점검: 펫·카드·편지 잠금·키 감지·화면 요소 판독을 실제로 실행해 본다.
    // 실제 Claude·ChatGPT 앱과의 연동, 서버와 주고받기, 사람이 집어 던지는 느낌은 여기서 확인되지 않는다.
    static class SelfTest
    {
        public static int Run(string dir)
        {
            dir = Path.GetFullPath(dir);
            Directory.CreateDirectory(dir);
            Config.Dir = Path.Combine(dir, "data");          // 실제 사용자 폴더를 건드리지 않는다
            var report = new StringBuilder();
            bool ok = true;
            Action<string, bool> check = (name, pass) =>
            {
                report.AppendLine((pass ? "PASS " : "FAIL ") + name);
                if (!pass) ok = false;
            };
            Action<string> note = text => report.AppendLine("     " + text);
            Action<string> shot = name =>
            {
                // 화면 전체를 찍는다. 화면이 없는 빌드 서버에서는 실패할 수 있고, 그것은 결과에 넣지 않는다.
                try
                {
                    Rectangle b = Screen.PrimaryScreen.Bounds;
                    using (var bmp = new Bitmap(b.Width, b.Height))
                    {
                        using (Graphics g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Location, Point.Empty, b.Size);
                        bmp.Save(Path.Combine(dir, name), ImageFormat.Png);
                    }
                }
                catch (Exception e) { note("화면 캡처 실패 (" + name + "): " + e.GetType().Name); }
            };

            try
            {
                Ui.Init();
                Settings.PetOn = true;
                Settings.Welcomed = true;        // 첫 실행 설정 창이 화면을 가리지 않게
                Settings.HabitsOn = false;       // 점검 도중 습관 알림이 끼어들지 않게
                Config.NestMinutes = 1e7;        // 빌드 서버는 입력이 없어서 그냥 두면 바로 둥지를 짓는다
                note("애니메이션 줄이기 설정: " + Native.ReduceMotion() + ", 입력 없이 지난 시간 " + (int)Native.IdleSeconds() + "초");
                Native.ForceMotion = true;
                TrayApp app = null;
                var steps = new List<KeyValuePair<int, Action>>();
                Action<int, Action> after = (ms, act) => steps.Add(new KeyValuePair<int, Action>(ms, act));
                Rectangle screen = Screen.PrimaryScreen.Bounds;
                note("화면 " + screen.Width + "x" + screen.Height + " 작업 영역 " + Screen.PrimaryScreen.WorkingArea);
                bool mailOpened = false;
                float before = 0;
                string scan = null, dump = null;
                Form probe = null;

                after(100, () =>
                {
                    app = new TrayApp();
                    app.Pet.Calm = true;
                    check("펫 그림 " + app.Pet.FrameCount + "프레임", app.Pet.FrameCount == 37);
                    app.Pet.SnapshotPoses(Path.Combine(dir, "poses.png"));
                    Deck deck = app.Quiz.Deck;
                    check("기본 제공 문제 " + deck.BuiltinCount + "개, 과목 " + deck.Topics.Count + "개", deck.BuiltinCount > 100 && deck.Topics.Count > 5);
                    check("서버 설정 읽기", Server.Shared != null);
                });
                after(900, () =>
                {
                    Rectangle r = app.Pet.WindowRect;
                    note(app.Pet.DebugState);
                    check("펫이 화면 안에 앉아 있음", app.Pet.IsShown && app.Pet.ModeName == "Sit" && screen.Contains(r) && r.Width > 60);
                    check("발이 작업 영역 아래 끝에 있음", Math.Abs(app.Pet.Feet.Y - Screen.PrimaryScreen.WorkingArea.Bottom) <= 4);
                    shot("desk-1-sit.png");
                    app.Pet.Preview("drink");
                });
                after(1500, () =>
                {
                    note(app.Pet.DebugState);
                    check("물 마시기 동작과 말풍선", app.Pet.ModeName == "Drink" && app.Pet.DebugState.Contains("bubble=True"));
                    shot("desk-2-drink.png");
                    app.Pet.Preview("tilt");
                });
                after(500, () =>
                {
                    var hook = new KeyHook();
                    check("키 감지 설치", hook.Install());
                    hook.Dispose();
                    app.Quiz.SolveOne();
                });
                after(1900, () =>
                {
                    QuizForm ui = app.Quiz.Ui;
                    note(app.Pet.DebugState);
                    check("혼자 푸는 카드 표시", ui.CanAnswer && ui.Standalone);
                    check("오모기가 카드 옆에 앉음", app.Pet.ModeName == "Perch");
                    ui.Snapshot(Path.Combine(dir, "card-1-ask.png"));
                    shot("desk-3-card.png");
                    before = app.Pet.Growth;
                    ui.Answer(!ui.CurrentAnswer);
                });
                after(1300, () =>
                {
                    QuizForm ui = app.Quiz.Ui;
                    check("오답 뒤 답 입력 잠김, 몸 크기 그대로", !ui.CanAnswer && Math.Abs(app.Pet.Growth - 1) < 0.01);
                    ui.Snapshot(Path.Combine(dir, "card-2-wrong.png"));
                    ui.NextNow();
                });
                for (int i = 1; i <= 5; i++)
                {
                    int n = i;
                    after(500, () =>
                    {
                        QuizForm ui = app.Quiz.Ui;
                        before = app.Pet.Growth;
                        ui.Answer(ui.CurrentAnswer);
                    });
                    if (n < 5)
                    {
                        after(900, () =>
                        {
                            note("연속 " + n + ": " + app.Pet.DebugState);
                            check("연속 정답 " + n + "번째에 몸이 커짐 (" + before.ToString("0.00") + " → " + app.Pet.Growth.ToString("0.00") + ")", app.Pet.Growth > before * 1.2);
                            if (n == 1) app.Quiz.Ui.Snapshot(Path.Combine(dir, "card-3-right.png"));
                            if (n == 4) shot("desk-4-grown.png");
                            app.Quiz.Ui.NextNow();
                        });
                    }
                }
                after(700, () =>
                {
                    note("연속 5 (터지기 직전): " + app.Pet.DebugState);
                    Rectangle r = app.Pet.WindowRect;
                    check("다섯 번째에 화면 높이의 3분의 1 넘게 부풂 (창 높이 " + r.Height + ")", r.Height * 17 / 28 > screen.Height / 3);
                    shot("desk-5-giant.png");
                });
                after(700, () =>
                {
                    note("펑: " + app.Pet.DebugState);
                    check("펑 터져 작은 새 여러 마리", app.Pet.MiniCount >= 10);
                    check("본래 크기로 돌아옴", app.Pet.Growth < 1.3);
                    shot("desk-6-pop.png");
                });
                after(700, () => shot("desk-7-pop-later.png"));
                after(300, () => app.Quiz.Ui.HideCard());
                after(6500, () =>
                {
                    note("카드가 닫힌 뒤: " + app.Pet.DebugState);
                    check("작은 새들이 모두 날아감", app.Pet.MiniCount == 0);
                    check("카드가 닫히면 바닥으로 돌아와 앉음", app.Pet.ModeName == "Sit" && !app.Quiz.Ui.Visible);
                    before = app.Pet.Feet.X;
                    app.Pet.TestThrow(-900, -300);
                });
                after(700, () => { note("던진 뒤 0.7초: " + app.Pet.DebugState); shot("desk-8-thrown.png"); });
                after(3800, () =>
                {
                    note("던진 뒤: " + app.Pet.DebugState);
                    check("던지면 굴러가서 멈춤 (" + (int)before + " → " + (int)app.Pet.Feet.X + ")",
                        app.Pet.ModeName == "Sit" && Math.Abs(app.Pet.Feet.X - before) > 80 && screen.Contains(app.Pet.WindowRect));
                    app.Pet.OnMailOpen = () => mailOpened = true;
                    check("편지 받아 오기 시작", app.Pet.BringMail("편지가 왔어요 — 눌러서 열기"));
                });
                after(1000, () => { note("나가는 중: " + app.Pet.DebugState); shot("desk-9-depart.png"); });
                after(5200, () =>
                {
                    note("편지를 물고: " + app.Pet.DebugState);
                    check("편지를 물고 돌아와 기다림", app.Pet.ModeName == "Mail" && app.Pet.IsHoldingMail && app.Pet.DebugState.Contains("bubble=True"));
                    shot("desk-10-mail.png");
                    check("누르면 편지함 열기 신호", app.Pet.TestOpenHeld() && mailOpened);
                });
                after(300, () =>
                {
                    try { LetterSelfTest.Run(check); }
                    catch (Exception e) { check("편지 점검 중 오류: " + e, false); }
                });
                after(300, () =>
                {
                    try
                    {
                        SettingsForm s = app.SettingsWindow;
                        s.RefreshState();
                        s.Show();
                        s.Snapshot(Path.Combine(dir, "window-settings.png"));
                        check("설정 창 " + s.Width + "x" + s.Height, s.Height > 300);
                        s.Hide();
                        // 배율을 바꿔 가며 설정 창을 새로 만들어, 항목이 창 밖으로 나가거나 글자가 칸보다 길지 않은지 본다.
                        float real = Dpi.K;
                        foreach (float k in new[] { real, 1.25f, 1.5f, 2f })
                        {
                            Dpi.Force(k);
                            using (var t = new SettingsForm(app))
                            {
                                string bad = t.LayoutProblem(k == real);
                                check("설정 창 배치 (배율 " + k.ToString("0.00") + ", " + t.ClientSize.Width + "x" + t.ClientSize.Height + ")" + (bad == null ? "" : " — " + bad), bad == null);
                                if (k == 1.5f) { t.Show(); t.Snapshot(Path.Combine(dir, "window-settings-150.png")); t.Hide(); }
                            }
                        }
                        Dpi.Force(real);
                        var forms = new[]
                        {
                            new KeyValuePair<string, Form>("window-compose.png", app.LetterWindows.ComposeForm),
                            new KeyValuePair<string, Form>("window-inbox.png", app.LetterWindows.InboxForm),
                            new KeyValuePair<string, Form>("window-friends.png", app.LetterWindows.FriendsForm),
                        };
                        foreach (var kv in forms)
                        {
                            Form f = kv.Value;
                            f.Show();
                            using (var bmp = new Bitmap(f.Width, f.Height))
                            {
                                f.DrawToBitmap(bmp, new Rectangle(0, 0, f.Width, f.Height));
                                bmp.Save(Path.Combine(dir, kv.Key), ImageFormat.Png);
                            }
                            check("창 그리기 " + kv.Key + " " + f.Width + "x" + f.Height, f.Width > 200 && f.Height > 150);
                            f.Hide();
                        }
                    }
                    catch (Exception e) { check("창 그리기 중 오류: " + e, false); }
                    probe = new Form { Text = "probe", StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(60, 420, 360, 160) };
                    probe.Controls.Add(new Button { Text = "보내기", Bounds = new Rectangle(20, 20, 140, 40) });
                    probe.Controls.Add(new Button { Text = "응답 중지", Bounds = new Rectangle(180, 20, 140, 40) });
                    probe.Show();
                });
                after(700, () =>
                {
                    IntPtr h = probe.Handle;
                    Scanner.FindStop(h, (found, label, count, ms) =>
                    {
                        scan = "found=" + found + " label=\"" + label + "\" 버튼 " + count + "개 ms=" + ms;
                        dump = Scanner.Dump(h);
                    });
                });
                after(4000, () =>
                {
                    check("화면 요소 판독: " + (scan ?? "응답 없음"), scan != null && scan.StartsWith("found=True"));
                    report.AppendLine("판독 목록:");
                    report.AppendLine(dump ?? "(없음)");
                });

                int at = 0;
                var timer = new WinTimer { Interval = steps[0].Key };
                timer.Tick += (s, e) =>
                {
                    timer.Stop();
                    try { steps[at].Value(); }
                    catch (Exception ex) { check("단계 " + (at + 1) + " 실행 중 오류: " + ex, false); }
                    at++;
                    if (at >= steps.Count)
                    {
                        try { if (app != null) app.Quit(); } catch { }
                        Application.ExitThread();
                        return;
                    }
                    timer.Interval = steps[at].Key;
                    timer.Start();
                };
                Application.ThreadException += (s, e) => check("처리되지 않은 오류: " + e.Exception, false);
                timer.Start();
                Application.Run();
            }
            catch (Exception ex)
            {
                check("오류: " + ex, false);
            }
            report.AppendLine(ok ? "결과: 통과" : "결과: 실패");
            File.WriteAllText(Path.Combine(dir, "result.txt"), report.ToString(), new UTF8Encoding(false));
            return ok ? 0 : 1;
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            int at = Array.IndexOf(args, "--selftest");
            if (at >= 0) return SelfTest.Run(at + 1 < args.Length ? args[at + 1] : "selftest");

            bool created;
            using (var mutex = new Mutex(true, "Omogi.SingleInstance", out created))
            using (var wake = new EventWaitHandle(false, EventResetMode.AutoReset, "Omogi.ShowSettings"))
            {
                if (!created)
                {
                    wake.Set();     // 이미 켜져 있으면 그쪽의 설정 창을 띄우고 끝낸다
                    return 0;
                }
                Ui.Init();
                Application.ThreadException += (s, e) => Log.Write("오류: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Write("치명적 오류: " + e.ExceptionObject);
                var app = new TrayApp();
                var listener = new Thread(() =>
                {
                    while (true)
                    {
                        try { wake.WaitOne(); } catch { return; }
                        Ui.Post(() => app.ShowSettings());
                    }
                }) { IsBackground = true };
                listener.Start();
                Application.Run(app);
                GC.KeepAlive(mutex);
            }
            return 0;
        }
    }
}
