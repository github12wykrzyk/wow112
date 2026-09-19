using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private readonly Dictionary<string, bool> dllUpdatePreferences =
            new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        private readonly List<DllUpdateStatus> lastDllInspection = new List<DllUpdateStatus>();
        private DllUpdateStatus lastExeInspection;
        private byte[] cachedVerifiedPackage;
        private long cachedVerifiedRunId;
        private string cachedVerifiedChannel = string.Empty;

        private int LastDllChangeCount { get { return lastDllInspection.Count(x => x.HasChange); } }
        private int LastEnabledDllChangeCount { get { return lastDllInspection.Count(x => x.HasChange && IsDllUpdateEnabled(x.Name)); } }

        private void LoadDllUpdatePreferences(Dictionary<string, object> root)
        {
            dllUpdatePreferences.Clear();
            var stored = GetValue(root, "dll_update_enabled") as Dictionary<string, object>;
            if (stored == null) return;
            foreach (var pair in stored)
            {
                try { dllUpdatePreferences[pair.Key] = Convert.ToBoolean(pair.Value); }
                catch { }
            }
        }

        private Dictionary<string, bool> GetDllUpdatePreferencesForSave()
        {
            return new Dictionary<string, bool>(dllUpdatePreferences, StringComparer.OrdinalIgnoreCase);
        }

        private bool IsDllUpdateEnabled(string name)
        {
            bool enabled;
            return !dllUpdatePreferences.TryGetValue(name, out enabled) || enabled;
        }

        private void ResetDllUpdateInspection()
        {
            lastDllInspection.Clear();
            lastExeInspection = null;
            cachedVerifiedPackage = null;
            cachedVerifiedRunId = 0;
            cachedVerifiedChannel = string.Empty;
        }

        private async Task<byte[]> GetVerifiedPackageBytesAsync(RemotePackageInfo remote)
        {
            if (cachedVerifiedPackage != null && cachedVerifiedRunId == remote.RunId
                && string.Equals(cachedVerifiedChannel, remote.Channel, StringComparison.OrdinalIgnoreCase))
            {
                Log("Używam zweryfikowanej paczki z bieżącej sesji.");
                return cachedVerifiedPackage;
            }

            Log("Pobieram artifact: " + remote.ArtifactName);
            var outerBytes = await DownloadBytesAsync(remote.DownloadUrl);
            Log("Pobrano " + FormatBytes(outerBytes.LongLength) + ". Weryfikuję paczkę...");

            byte[] innerBytes;
            string expectedPackageSha;
            ExtractInnerPackage(outerBytes, remote.InnerZipName, out innerBytes, out expectedPackageSha);
            var gotPackageSha = Sha256(innerBytes);
            if (!string.Equals(gotPackageSha, expectedPackageSha, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("SHA256 wewnętrznej paczki nie zgadza się z candidate_metadata.json.");

            Log("SHA256 paczki OK: " + gotPackageSha.Substring(0, 16) + "...");
            cachedVerifiedPackage = innerBytes;
            cachedVerifiedRunId = remote.RunId;
            cachedVerifiedChannel = remote.Channel;
            return innerBytes;
        }

        private async Task InspectRemoteDllsAsync(RemotePackageInfo remote)
        {
            var packageBytes = await GetVerifiedPackageBytesAsync(remote);
            InspectDllPackage(packageBytes, gameDir.Text.Trim());
        }

        private void InspectDllPackage(byte[] packageBytes, string root)
        {
            lastDllInspection.Clear();
            lastExeInspection = null;
            var remoteDlls = new List<PackageFile>();
            var remoteExes = new List<PackageFile>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            using (var ms = new MemoryStream(packageBytes, false))
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Read, false))
            {
                foreach (var entry in zip.Entries)
                {
                    if (string.IsNullOrWhiteSpace(entry.Name)) continue;
                    var isDll = entry.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase);
                    var isExe = entry.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
                    if (!isDll && !isExe) continue;
                    if (!string.Equals(entry.FullName, entry.Name, StringComparison.Ordinal))
                        throw new InvalidOperationException("Paczka zawiera zagnieżdżoną ścieżkę EXE/DLL: " + entry.FullName);
                    if (!seen.Add(entry.Name))
                        throw new InvalidOperationException("Paczka zawiera powieloną nazwę EXE/DLL: " + entry.Name);
                    var file = new PackageFile(entry.Name, ReadEntry(entry));
                    if (isExe) remoteExes.Add(file);
                    else remoteDlls.Add(file);
                }
            }
            if (remoteExes.Count != 1)
                throw new InvalidOperationException("Paczka musi zawierać dokładnie jeden główny EXE WoW.");

            var exe = remoteExes[0];
            var localExe = SafeDestination(root, exe.Name);
            var localExeSha = File.Exists(localExe) ? Sha256File(localExe) : string.Empty;
            var exeChanged = !string.Equals(localExeSha, exe.Sha256, StringComparison.OrdinalIgnoreCase);
            var exeState = string.IsNullOrEmpty(localExeSha) ? "BRAK LOKALNIE" : (exeChanged ? "AKTUALIZACJA" : "AKTUALNY");
            lastExeInspection = new DllUpdateStatus(exe.Name, exeState, exeChanged, localExeSha, exe.Sha256, false);
            Log("EXE " + exeState + " " + exe.Name
                + " [" + (string.IsNullOrEmpty(localExeSha) ? "-" : localExeSha.Substring(0, 12))
                + " -> " + exe.Sha256.Substring(0, 12) + "]");

            foreach (var dll in remoteDlls)
            {
                var localPath = SafeDestination(root, dll.Name);
                string localSha = string.Empty;
                string state;
                bool change;
                if (!File.Exists(localPath))
                {
                    state = "BRAK LOKALNIE";
                    change = true;
                }
                else
                {
                    localSha = Sha256File(localPath);
                    change = !string.Equals(localSha, dll.Sha256, StringComparison.OrdinalIgnoreCase);
                    state = change ? "AKTUALIZACJA" : "AKTUALNA";
                }
                lastDllInspection.Add(new DllUpdateStatus(dll.Name, state, change, localSha, dll.Sha256, false));
            }

            var remoteNames = new HashSet<string>(remoteDlls.Select(x => x.Name), StringComparer.OrdinalIgnoreCase);
            var installed = ReadInstalledState(root);
            if (installed != null)
            {
                foreach (var value in AsArray(GetValue(installed, "managed_files")))
                {
                    var name = Convert.ToString(value);
                    if (string.IsNullOrWhiteSpace(name) || !name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || remoteNames.Contains(name)) continue;
                    var localPath = SafeDestination(root, name);
                    if (!File.Exists(localPath)) continue;
                    lastDllInspection.Add(new DllUpdateStatus(name, "USUNIĘTA Z PACZKI", true, Sha256File(localPath), string.Empty, true));
                }
            }

            foreach (var row in lastDllInspection)
                Log("DLL " + row.State.PadRight(18) + " " + row.Name + (IsDllUpdateEnabled(row.Name) ? " [update ON]" : " [update OFF]"));
        }

        private void ShowRemoteDllSummary()
        {
            if (lastRemote == null) return;
            var changed = LastDllChangeCount;
            var enabled = LastEnabledDllChangeCount;
            var held = changed - enabled;
            var exeText = lastExeInspection == null ? "NIE SPRAWDZONO" : lastExeInspection.State;
            remoteInfo.Text = lastRemote.Channel.ToUpperInvariant() + " • " + ShortSha(lastRemote.HeadSha)
                + " • run " + lastRemote.RunId + "\nEXE: " + exeText + " • DLL: " + enabled + " do aktualizacji";
            detailsTip.SetToolTip(remoteInfo, remoteInfo.Text
                + (lastExeInspection == null ? string.Empty : "\nEXE: " + lastExeInspection.Name
                    + "\nSHA256 paczki: " + lastExeInspection.RemoteSha)
                + "\nDLL: " + changed + " zmian, aktywne " + enabled
                + (held > 0 ? ", wstrzymane " + held : string.Empty));
        }

        private async Task ShowDllUpdateDialogAsync()
        {
            try
            {
                ValidateInputs();
                SaveConfig(false);
                if (lastRemote == null || lastDllInspection.Count == 0)
                {
                    SetBusy(true, "Sprawdzanie DLL-i...");
                    lastRemote = await FindLatestPackageAsync();
                    await InspectRemoteDllsAsync(lastRemote);
                    ShowRemoteDllSummary();
                }
            }
            catch (Exception ex)
            {
                ShowRemoteFailure(ex);
                Log("BŁĄD DLL: " + ex.Message);
                MessageBox.Show(this, ex.Message, "Aktualizacje DLL", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            finally
            {
                if (busy) SetBusy(false, status.Text);
            }

            using (var dialog = new Form
            {
                Text = "Aktualizacje DLL",
                ClientSize = new Size(900, 500),
                MinimumSize = new Size(760, 420),
                StartPosition = FormStartPosition.CenterParent,
                Font = Font,
                BackColor = Surface,
                ForeColor = Ink,
                AutoScaleMode = AutoScaleMode.Dpi
            })
            {
                var root = Grid(1, 3);
                root.Padding = new Padding(14);
                root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
                root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
                root.Controls.Add(TextLabel(
                    "Zaznaczone = updater może zmienić tę DLL. Odznaczone = zachowaj lokalną wersję i pomijaj update/usunięcie.\nStatus jest liczony osobno z SHA256 każdej DLL.",
                    9, Muted), 0, 0);

                var list = new CheckedListBox
                {
                    Dock = DockStyle.Fill,
                    CheckOnClick = true,
                    BackColor = Canvas,
                    ForeColor = Ink,
                    BorderStyle = BorderStyle.FixedSingle,
                    Font = new Font("Consolas", 9F),
                    HorizontalScrollbar = true
                };
                foreach (var row in lastDllInspection.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase))
                    list.Items.Add(row, IsDllUpdateEnabled(row.Name));
                root.Controls.Add(list, 0, 1);

                var buttons = Grid(4, 1);
                var enableAll = ActionButton(new Button(), "Włącz wszystkie");
                var disableAll = ActionButton(new Button(), "Wyłącz wszystkie");
                var cancel = ActionButton(new Button(), "Anuluj");
                var save = ActionButton(new Button(), "Zapisz", true);
                enableAll.Click += delegate { for (var i = 0; i < list.Items.Count; i++) list.SetItemChecked(i, true); };
                disableAll.Click += delegate { for (var i = 0; i < list.Items.Count; i++) list.SetItemChecked(i, false); };
                cancel.DialogResult = DialogResult.Cancel;
                save.DialogResult = DialogResult.OK;
                buttons.Controls.Add(enableAll, 0, 0);
                buttons.Controls.Add(disableAll, 1, 0);
                buttons.Controls.Add(cancel, 2, 0);
                buttons.Controls.Add(save, 3, 0);
                root.Controls.Add(buttons, 0, 2);

                dialog.Controls.Add(root);
                dialog.AcceptButton = save;
                dialog.CancelButton = cancel;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    for (var i = 0; i < list.Items.Count; i++)
                    {
                        var row = list.Items[i] as DllUpdateStatus;
                        if (row != null) dllUpdatePreferences[row.Name] = list.GetItemChecked(i);
                    }
                    SaveConfig(false);
                    ShowRemoteDllSummary();
                    status.Text = "Ustawienia aktualizacji DLL zapisane.";
                    Log("Zapisano indywidualne przełączniki aktualizacji DLL.");
                }
            }
        }

        private sealed class DllUpdateStatus
        {
            public readonly string Name;
            public readonly string State;
            public readonly bool HasChange;
            public readonly string LocalSha;
            public readonly string RemoteSha;
            public readonly bool RemovedUpstream;

            public DllUpdateStatus(string name, string state, bool hasChange, string localSha, string remoteSha, bool removedUpstream)
            {
                Name = name; State = state; HasChange = hasChange; LocalSha = localSha; RemoteSha = remoteSha; RemovedUpstream = removedUpstream;
            }

            public override string ToString()
            {
                var mode = RemovedUpstream ? "REMOVE" : State;
                var local = string.IsNullOrWhiteSpace(LocalSha) ? "-" : LocalSha.Substring(0, Math.Min(8, LocalSha.Length));
                var remote = string.IsNullOrWhiteSpace(RemoteSha) ? "-" : RemoteSha.Substring(0, Math.Min(8, RemoteSha.Length));
                return mode.PadRight(18) + "  " + Name + "  [" + local + " -> " + remote + "]";
            }
        }
    }
}
