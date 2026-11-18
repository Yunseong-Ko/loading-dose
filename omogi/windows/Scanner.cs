// 대상 앱 창의 화면 요소(UI Automation)를 읽어 "중지" 버튼이 있는지 본다.
// 버튼 이름만 읽는다. 대화 내용은 읽지 않는다.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Windows.Automation;

namespace Omogi
{
    static class Scanner
    {
        static int busy;   // 판독이 겹쳐 돌지 않게 한다

        static List<string> ButtonNames(IntPtr hwnd)
        {
            var names = new List<string>();
            AutomationElement root = AutomationElement.FromHandle(hwnd);
            var request = new CacheRequest();
            request.Add(AutomationElement.NameProperty);
            request.AutomationElementMode = AutomationElementMode.None;
            using (request.Activate())
            {
                AutomationElementCollection all = root.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
                foreach (AutomationElement e in all)
                {
                    string name = e.Cached.Name;
                    names.Add(name ?? "");
                }
            }
            return names;
        }

        // 결과는 백그라운드 스레드에서 done(찾음, 버튼 이름, 버튼 수, 걸린 ms)으로 알려 준다.
        // 앞선 판독이 아직 돌고 있으면 아무것도 하지 않는다.
        public static void FindStop(IntPtr hwnd, Action<bool, string, int, long> done)
        {
            if (Interlocked.Exchange(ref busy, 1) == 1) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                bool found = false;
                string label = "";
                int count = 0;
                var sw = Stopwatch.StartNew();
                try
                {
                    List<string> names = ButtonNames(hwnd);
                    count = names.Count;
                    foreach (string n in names)
                    {
                        if (Config.IsStop(n)) { found = true; label = n; break; }
                    }
                }
                catch (Exception e)
                {
                    label = "ERR " + e.GetType().Name;
                }
                finally
                {
                    Interlocked.Exchange(ref busy, 0);
                }
                try { done(found, label, count, sw.ElapsedMilliseconds); } catch { }
            });
        }

        // 진단용: 버튼 수와 짧은 버튼 이름 목록. 긴 이름(대화 제목일 수 있음)은 글자 수만 적는다.
        public static string Dump(IntPtr hwnd)
        {
            var sb = new StringBuilder();
            try
            {
                var sw = Stopwatch.StartNew();
                List<string> names = ButtonNames(hwnd);
                sb.AppendLine("버튼 " + names.Count + "개 (판독 " + sw.ElapsedMilliseconds + "ms)");
                int shown = 0, longer = 0, empty = 0;
                var seen = new HashSet<string>();
                foreach (string n in names)
                {
                    if (n.Length == 0) { empty++; continue; }
                    if (Config.IsStop(n)) { sb.AppendLine("  [중지 후보] " + n); continue; }
                    if (n.Length > 18) { longer++; continue; }
                    if (!seen.Add(n) || shown >= 60) continue;
                    sb.AppendLine("  " + n);
                    shown++;
                }
                sb.AppendLine("이름 없는 버튼 " + empty + "개, 긴 이름이라 생략한 버튼 " + longer + "개");
            }
            catch (Exception e)
            {
                sb.AppendLine("화면 요소를 읽지 못함: " + e.GetType().Name + " " + e.Message);
            }
            return sb.ToString();
        }
    }
}
