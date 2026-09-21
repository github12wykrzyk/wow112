using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private readonly Button dllCleanupButton = new Button();
        private readonly HashSet<string> dllInstallDisabled = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        private static bool IsRootDllName(string name)
        {
            return !string.IsNullOrWhiteSpace(name) && Path.GetFileName(name) == name
                && name.IndexOfAny(Path.GetInvalidFileNameChars()) < 0
                && name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase);
        }

        private bool IsDllInstallDisabled(string name) { return dllInstallDisabled.Contains(name); }
        private string[] GetDllInstallDisabledForSave()
        {
            return dllInstallDisabled.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToArray();
        }
        private void LoadDllInstallDisabled(Dictionary<string, object> config)
        {
            dllInstallDisabled.Clear();
            foreach (var item in AsArray(GetValue(config, "dll_install_disabled")))
            {
                var name = Convert.ToString(item);
                if (IsRootDllName(name)) dllInstallDisabled.Add(name);
            }
        }

        private static HashSet<string> ReadListedDlls(string root)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var path = Path.Combine(root, "dlls.txt");
            if (!File.Exists(path)) return names;
            foreach (var line in File.ReadAllLines(path))
            {
                var name = line.Trim();
                if (IsRootDllName(name)) names.Add(name);
            }
            return names;
        }

        private void ShowDllCleanupDialog()
        {
            if (busy) return;
            var root = gameDir.Text.Trim();
            if (!Directory.Exists(root))
            {
                MessageBox.Show(this, "Wybierz katalog gry.", "Oczyść DLL");
                return;
            }
            if (IsGameRunning(root))
            {
                MessageBox.Show(this, "Zamknij WoW przed czyszczeniem DLL.", "Oczyść DLL");
                return;
            }
            var installed = ReadInstalledState(root);
            var managed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (installed != null)
                foreach (var item in AsArray(GetValue(installed, "managed_files")))
                {
                    var name = Convert.ToString(item);
                    if (IsRootDllName(name)) managed.Add(name);
                }
            var listed = ReadListedDlls(root);
            var all = new HashSet<string>(
                Directory.GetFiles(root, "*.dll", SearchOption.TopDirectoryOnly)
                .Select(Path.GetFileName).Where(IsRootDllName), StringComparer.OrdinalIgnoreCase);
            all.UnionWith(dllInstallDisabled);
            using (var dialog = new Form {
                Text = "Oczyść DLL — PARALLEL", ClientSize = new Size(880, 520),
                MinimumSize = new Size(720, 430), StartPosition = FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi, Font = Font, BackColor = Surface, ForeColor = Ink
            })
            {
                var layout = Grid(1, 3);
                layout.Padding = new Padding(14);
                layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
                layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
                layout.Controls.Add(TextLabel(
                    "ZAZNACZONE = usuń i nie instaluj ponownie. ODZNACZ wcześniej wyłączony moduł, aby przywrócić go przy aktualizacji.\n"
                    + "Usunięcie aktywnej lub nieznanej DLL może zakłócić działanie WoW. Przed zmianą powstaje kopia zapasowa.",
                    9, Muted), 0, 0);
                var list = new CheckedListBox {
                    Dock = DockStyle.Fill, CheckOnClick = true,
                    BackColor = Canvas, ForeColor = Ink, Font = new Font("Consolas", 9F),
                    HorizontalScrollbar = true, BorderStyle = BorderStyle.FixedSingle
                };
                var choices = new List<DllCleanupChoice>();
                foreach (var name in all.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                {
                    var present = File.Exists(SafeDestination(root, name));
                    var state = !present ? "WYŁĄCZONA / BRAK"
                        : listed.Contains(name) ? "AKTYWNA W dlls.txt"
                        : managed.Contains(name) ? "ZARZĄDZANA / POZA LISTĄ"
                        : "NIEZNANA / POZA LISTĄ";
                    if (present && !IsDllUpdateEnabled(name)) state += " / UPDATE OFF";
                    var choice = new DllCleanupChoice(name, state, present, managed.Contains(name));
                    choices.Add(choice);
                    list.Items.Add(choice, dllInstallDisabled.Contains(name));
                }
                layout.Controls.Add(list, 0, 1);
                var buttons = Grid(2, 1);
                var cancel = ActionButton(new Button(), "Anuluj"); cancel.DialogResult = DialogResult.Cancel;
                var apply = ActionButton(new Button(), "Zastosuj", true); apply.DialogResult = DialogResult.OK;
                buttons.Controls.Add(cancel, 0, 0);
                buttons.Controls.Add(apply, 1, 0);
                layout.Controls.Add(buttons, 0, 2);
                dialog.Controls.Add(layout);
                dialog.AcceptButton = apply; dialog.CancelButton = cancel;
                if (dialog.ShowDialog(this) != DialogResult.OK) return;

                var selected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i < choices.Count; i++)
                    if (list.GetItemChecked(i)) selected.Add(choices[i].Name);
                var deletions = choices.Where(x => x.Present && selected.Contains(x.Name)).ToList();
                var active = deletions.Count(x => listed.Contains(x.Name));
                var unknown = deletions.Count(x => !x.Managed && !listed.Contains(x.Name));
                var reenabled = dllInstallDisabled.Count(x => !selected.Contains(x));
                if (deletions.Count == 0 && reenabled == 0 && selected.SetEquals(dllInstallDisabled)) return;
                var prompt = "Usunąć " + deletions.Count + " DLL i zapisać listę wyłączeń?"
                    + "\nAktywne w dlls.txt: " + active + "; nieznane: " + unknown
                    + "; ponownie włączane: " + reenabled
                    + ".\n\nWyłączone DLL nie wrócą przy kolejnej aktualizacji. Wykonam kopię zapasową.";
                if (MessageBox.Show(this, prompt, "Potwierdź czyszczenie DLL",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                    return;

                var previous = new HashSet<string>(dllInstallDisabled, StringComparer.OrdinalIgnoreCase);
                try
                {
                    if (IsGameRunning(root)) throw new InvalidOperationException("Gra została uruchomiona podczas wyboru DLL.");
                    SetBusy(true, "Oczyszczanie DLL...");
                    dllInstallDisabled.Clear(); dllInstallDisabled.UnionWith(selected);
                    SaveConfig(false);
                    var saved = AsDictionary(json.DeserializeObject(File.ReadAllText(configPath, Encoding.UTF8)));
                    var persisted = new HashSet<string>(
                        AsArray(GetValue(saved, "dll_install_disabled")).Select(Convert.ToString),
                        StringComparer.OrdinalIgnoreCase);
                    if (!persisted.SetEquals(selected))
                        throw new InvalidOperationException("Nie zapisano listy wyłączonych DLL.");
                    var result = DeleteSelectedDlls(Path.GetFullPath(root), deletions.Select(x => x.Name).ToArray());
                    status.Text = "Oczyszczono: " + result.Item1 + " DLL usunięto, " + selected.Count + " wyłączonych.";
                    Log(status.Text);
                    if (!string.IsNullOrEmpty(result.Item2)) Log("Backup: " + result.Item2);
                    TrimBackups(root, MaxBackups);
                    RefreshLocalState();
                    ResetDllUpdateInspection();
                }
                catch (Exception ex)
                {
                    dllInstallDisabled.Clear(); dllInstallDisabled.UnionWith(previous);
                    SaveConfig(false);
                    status.Text = "Czyszczenie DLL nie powiodło się";
                    Log("BŁĄD czyszczenia DLL: " + ex.Message);
                    MessageBox.Show(this, ex.Message, "Oczyść DLL", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                finally { if (busy) SetBusy(false, status.Text); }
            }
        }

        private Tuple<int, string> DeleteSelectedDlls(string root, string[] selectedNames)
        {
            if (IsGameRunning(root)) throw new InvalidOperationException("Gra działa — czyszczenie przerwane.");
            var selected = new HashSet<string>(selectedNames.Where(IsRootDllName), StringComparer.OrdinalIgnoreCase);
            var present = selected.Where(n => File.Exists(SafeDestination(root, n))).ToList();
            if (present.Count == 0) return Tuple.Create(0, string.Empty);
            var dllsPath = Path.Combine(root, "dlls.txt");
            var oldLines = File.Exists(dllsPath) ? File.ReadAllLines(dllsPath) : new string[0];
            var newLines = oldLines.Where(line => !selected.Contains(line.Trim())).ToArray();
            var listChanged = oldLines.Length != newLines.Length;
            var oldState = ReadInstalledState(root);
            var remote = new RemotePackageInfo { RunId = oldState == null ? 0 : GetLong(oldState, "run_id"),
                HeadSha = oldState == null ? string.Empty : GetString(oldState, "head_sha") };
            var touched = new List<string>(present);
            if (listChanged) touched.Add("dlls.txt");
            var backup = CreateBackup(root, touched, oldState, remote);
            try
            {
                foreach (var name in present)
                {
                    File.Delete(SafeDestination(root, name));
                    Log("DEL " + name + " (DLL wyłączona)");
                }
                if (listChanged)
                {
                    var temp = dllsPath + ".wow112tmp";
                    File.WriteAllText(temp, newLines.Length == 0 ? string.Empty :
                        string.Join("\r\n", newLines) + "\r\n", Encoding.ASCII);
                    ReplaceFile(temp, dllsPath);
                }
                if (oldState != null)
                {
                    oldState["managed_files"] = AsArray(GetValue(oldState, "managed_files"))
                        .Select(Convert.ToString).Where(x => !selected.Contains(x)).ToArray();
                    UpdaterSafety.WriteUtf8Atomic(InstalledStatePath(root),
                        json.Serialize(oldState), ".tmp", ".previous");
                }
            }
            catch { RestoreBackupDirectory(root, backup, false); throw; }
            return Tuple.Create(present.Count, backup);
        }

        private sealed class DllCleanupChoice
        {
            public readonly string Name;
            public readonly bool Present;
            public readonly bool Managed;
            private readonly string status;
            public DllCleanupChoice(string name, string status, bool present, bool managed)
            { Name = name; this.status = status; Present = present; Managed = managed; }
            public override string ToString() { return status.PadRight(38) + " " + Name; }
        }
    }
}
