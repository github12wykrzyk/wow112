using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Local wrapper intentionally shadows System.Windows.Forms.Application for
    // Program.Main. It lets optional updater UI features attach after MainForm
    // has finished constructing without rewriting the main updater source.
    internal static class Application
    {
        public static void EnableVisualStyles()
        {
            System.Windows.Forms.Application.EnableVisualStyles();
        }

        public static void SetCompatibleTextRenderingDefault(bool defaultValue)
        {
            System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(defaultValue);
        }

        public static void Run(Form mainForm)
        {
            RealmlistFeature.Attach(mainForm);
            MaintenanceFeature.Attach(mainForm);
            IssueReportFeature.Attach(mainForm);
            ((MainForm)mainForm).AttachAccounts();
            ((MainForm)mainForm).BuildDashboard();
            var args = Environment.GetCommandLineArgs();
            if (args.Length == 3 && args[1] == "--ui-smoke")
            {
                try { ((MainForm)mainForm).CaptureUiSmoke(args[2]); }
                catch (Exception ex) { System.IO.Directory.CreateDirectory(args[2]); System.IO.File.WriteAllText(System.IO.Path.Combine(args[2], "failure.txt"), ex.ToString()); Environment.ExitCode = 1; }
                finally { mainForm.Dispose(); }
                return;
            }
            System.Windows.Forms.Application.Run(mainForm);
        }
    }

    internal static class RealmlistFeature
    {
        private const int AddedHeight = 58;

        public static void Attach(Form form)
        {
            if (form == null) return;
            var feature = new RealmlistController(form);
            feature.Attach();
        }

        private sealed class RealmlistController
        {
            private readonly Form form;
            private readonly TextBox gameDir;
            private readonly RichTextBox log;
            private readonly ComboBox selector = new ComboBox();
            private readonly Button applyButton = new Button();
            private readonly RealmlistPreset octo = new RealmlistPreset("OctoWoW", "play.octowow.st");
            private readonly RealmlistPreset raven = new RealmlistPreset("RavenCraft", "logon.ravencraft.io");
            private bool attached;

            public RealmlistController(Form form)
            {
                this.form = form;
                gameDir = GetPrivateField<TextBox>(form, "gameDir");
                log = GetPrivateField<RichTextBox>(form, "log");
            }

            public void Attach()
            {
                if (attached || gameDir == null) return;
                attached = true;

                selector.DropDownStyle = ComboBoxStyle.DropDownList;
                applyButton.Click += delegate { ApplySelected(); };
                var host = (IUpdaterHost)form;
                host.RegisterUiControl("realm", selector);
                host.RegisterUiControl("realmApply", applyButton);

                gameDir.TextChanged += delegate { RefreshSelection(); };
                RefreshSelection();
            }

            private void RefreshSelection()
            {
                selector.Items.Clear();
                selector.Items.Add(octo);
                selector.Items.Add(raven);

                var host = ReadCurrentHost();
                RealmlistPreset selected = null;
                if (string.Equals(host, octo.Host, StringComparison.OrdinalIgnoreCase)) selected = octo;
                if (string.Equals(host, raven.Host, StringComparison.OrdinalIgnoreCase)) selected = raven;

                if (selected != null)
                {
                    selector.SelectedItem = selected;
                }
                else if (!string.IsNullOrWhiteSpace(host))
                {
                    var custom = new RealmlistPreset("Aktualny (niestandardowy)", host);
                    selector.Items.Add(custom);
                    selector.SelectedItem = custom;
                }
                else
                {
                    selector.SelectedIndex = -1;
                }

                applyButton.Enabled = Directory.Exists(gameDir.Text.Trim()) && selector.SelectedItem != null;
            }

            private void ApplySelected()
            {
                try
                {
                    var preset = selector.SelectedItem as RealmlistPreset;
                    var root = gameDir.Text.Trim();
                    if (preset == null) throw new InvalidOperationException("Wybierz realmlist z listy.");
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                        throw new InvalidOperationException("Wybierz istniejący katalog gry.");

                    var path = Path.Combine(root, "realmlist.wtf");
                    var desired = "SET realmList \"" + preset.Host + "\"";
                    var lines = File.Exists(path)
                        ? new List<string>(File.ReadAllLines(path))
                        : new List<string>();

                    var replaced = false;
                    for (var i = 0; i < lines.Count; i++)
                    {
                        if (!IsRealmlistDirective(lines[i])) continue;
                        lines[i] = desired;
                        replaced = true;
                        break;
                    }
                    if (!replaced) lines.Insert(0, desired);

                    File.WriteAllLines(path, lines.ToArray(), new UTF8Encoding(false));
                    Log("Realmlist ustawiony: " + desired);
                    RefreshSelection();
                }
                catch (Exception ex)
                {
                    Log("BŁĄD realmlist: " + ex.Message);
                    MessageBox.Show(form, ex.Message, "WoW112 Updater", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }

            private string ReadCurrentHost()
            {
                try
                {
                    var root = gameDir.Text.Trim();
                    if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return string.Empty;
                    var path = Path.Combine(root, "realmlist.wtf");
                    if (!File.Exists(path)) return string.Empty;

                    foreach (var line in File.ReadAllLines(path))
                    {
                        if (!IsRealmlistDirective(line)) continue;
                        var text = line.Trim();
                        var first = text.IndexOf('"');
                        if (first >= 0)
                        {
                            var second = text.IndexOf('"', first + 1);
                            if (second > first + 1) return text.Substring(first + 1, second - first - 1).Trim();
                        }

                        const string prefix = "set realmlist";
                        if (text.Length > prefix.Length)
                            return text.Substring(prefix.Length).Trim().Trim('"');
                    }
                }
                catch
                {
                }
                return string.Empty;
            }

            private static bool IsRealmlistDirective(string line)
            {
                if (line == null) return false;
                var text = line.TrimStart();
                const string prefix = "set realmlist";
                if (!text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
                return text.Length == prefix.Length || char.IsWhiteSpace(text[prefix.Length]);
            }

            private void Log(string message)
            {
                if (log == null) return;
                log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message + Environment.NewLine);
                log.SelectionStart = log.TextLength;
                log.ScrollToCaret();
            }

            private static T GetPrivateField<T>(object instance, string name) where T : class
            {
                var field = instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic);
                return field == null ? null : field.GetValue(instance) as T;
            }
        }

        private sealed class RealmlistPreset
        {
            public readonly string Name;
            public readonly string Host;

            public RealmlistPreset(string name, string host)
            {
                Name = name;
                Host = host;
            }

            public override string ToString()
            {
                return Name + " — " + Host;
            }
        }
    }
}

