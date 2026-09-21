using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112Updater
{
    // Game credentials are NEVER sent to GitHub, stored in the game directory or
    // included in updater diagnostics. The encrypted vault is tied to Windows CurrentUser.
    internal sealed class WowAccount
    {
        public string Id { get; set; }
        public string Label { get; set; }
        public string Login { get; set; }
        public string ProtectedPassword { get; set; }
    }

    internal sealed class WowAccountData
    {
        public int Version { get; set; }
        public string SelectedId { get; set; }
        public List<WowAccount> Accounts { get; set; }
    }

    internal sealed class WowAccountVault
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("WoW112Updater-wow-accounts-v1");
        private readonly string path;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        public WowAccountData Data { get; private set; }

        public WowAccountVault(string path)
        {
            this.path = path;
            Data = new WowAccountData { Version = 1, SelectedId = "", Accounts = new List<WowAccount>() };
        }

        public void Load()
        {
            if (!File.Exists(path)) return;
            if (new FileInfo(path).Length > 1024 * 1024)
                throw new InvalidDataException("Magazyn kont jest zbyt duży.");
            var loaded = serializer.Deserialize<WowAccountData>(File.ReadAllText(path, Encoding.UTF8));
            if (loaded == null || loaded.Version != 1 || loaded.Accounts == null || loaded.Accounts.Count > 128
                || loaded.Accounts.Any(a => a == null || string.IsNullOrWhiteSpace(a.Id)
                    || string.IsNullOrWhiteSpace(a.Label) || string.IsNullOrWhiteSpace(a.Login)
                    || string.IsNullOrWhiteSpace(a.ProtectedPassword))
                || loaded.Accounts.Select(a => a.Id).Distinct(StringComparer.Ordinal).Count() != loaded.Accounts.Count)
                throw new InvalidDataException("Nieprawidłowy magazyn kont. Nie nadpisano danych.");
            Data = loaded;
        }

        public string Protect(string password)
        {
            if (string.IsNullOrEmpty(password)) throw new ArgumentException("Hasło nie może być puste.");
            return Convert.ToBase64String(ProtectedData.Protect(
                Encoding.UTF8.GetBytes(password), Entropy, DataProtectionScope.CurrentUser));
        }

        public string Unprotect(WowAccount account)
        {
            if (account == null) throw new ArgumentNullException("account");
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(
                Convert.FromBase64String(account.ProtectedPassword), Entropy, DataProtectionScope.CurrentUser));
        }

        public void Save()
        {
            Data.Version = 1;
            UpdaterSafety.WriteUtf8Atomic(path, serializer.Serialize(Data), ".tmp", ".previous");
        }

        public WowAccount Selected
        {
            get { return Data.Accounts.FirstOrDefault(a => a.Id == Data.SelectedId); }
        }
    }

    internal sealed class WowAccountSession
    {
        public System.Diagnostics.Process Game;
        public string AccountId;
    }

    internal sealed partial class MainForm
    {
        private readonly Button accountsButton = new Button();
        private WowAccountVault accountVault;
        private readonly List<WowAccountSession> accountSessions = new List<WowAccountSession>();

        internal void AttachAccounts()
        {
            accountsButton.Click += delegate { ShowAccounts(); };
            ((IUpdaterHost)this).RegisterUiControl("accounts", accountsButton);
            try
            {
                accountVault = new WowAccountVault(Path.Combine(configDir, "wow_accounts.json"));
                accountVault.Load();
            }
            catch (Exception ex)
            {
                // Never silently discard a damaged vault or overwrite an inaccessible one.
                accountVault = null;
                Log("Magazyn kont niedostępny (dane zachowane): " + ex.GetType().Name);
            }
        }

        private void RememberGameSession(System.Diagnostics.Process game)
        {
            if (game == null || accountVault == null || accountVault.Selected == null) return;
            accountSessions.RemoveAll(s => { try { return s.Game.HasExited; } catch { return true; } });
            accountSessions.Add(new WowAccountSession { Game = game, AccountId = accountVault.Selected.Id });
            Log("Uruchomiono klienta dla profilu: " + accountVault.Selected.Label + " (PID " + game.Id + ").");
        }

        private void ShowAccounts()
        {
            if (busy) return;
            if (accountVault == null)
            {
                MessageBox.Show(this, "Magazyn kont nie jest dostępny. Sprawdź uprawnienia do %APPDATA%\\WoW112ParallelUpdater. Istniejące konta nie zostały nadpisane.",
                    "Konta WoW", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            using (var dialog = new Form
            {
                Text = "Konta WoW — lokalne profile",
                ClientSize = new Size(690, 456),
                MinimumSize = new Size(706, 495),
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                StartPosition = FormStartPosition.CenterParent,
                AutoScaleMode = AutoScaleMode.Dpi,
                Font = new Font("Segoe UI", 9F)
            })
            {
                var list = new ListBox { Location = new Point(14, 37), Size = new Size(202, 312) };
                var label = new TextBox { Location = new Point(237, 60), Width = 432, MaxLength = 80 };
                var login = new TextBox { Location = new Point(237, 120), Width = 432, MaxLength = 128 };
                var password = new TextBox { Location = new Point(237, 183), Width = 432, UseSystemPasswordChar = true, MaxLength = 256 };
                var hint = new Label { Location = new Point(237, 210), Size = new Size(430, 35),
                    Text = "Przy edycji pozostaw hasło puste, aby zachować dotychczasowe.\nHasło nie pojawia się w logach ani w paczkach diagnostycznych." };
                var newButton = new Button { Text = "Nowe", Location = new Point(14, 360), Size = new Size(96, 32) };
                var deleteButton = new Button { Text = "Usuń", Location = new Point(120, 360), Size = new Size(96, 32) };
                var saveButton = new Button { Text = "Zapisz profil", Location = new Point(237, 253), Size = new Size(142, 32) };
                var defaultButton = new Button { Text = "Ustaw domyślne", Location = new Point(386, 253), Size = new Size(138, 32) };
                var launchProfile = new Button { Text = "Uruchom grę z profilem", Location = new Point(237, 306), Size = new Size(209, 36) };
                var fillButton = new Button { Text = "Wpisz dane do gry", Location = new Point(453, 306), Size = new Size(216, 36) };
                var info = new Label { Location = new Point(14, 402), Size = new Size(660, 44),
                    Text = "Zapisane hasła: Windows DPAPI / bieżący użytkownik. Aby wpisać dane, uruchom grę z profilem, otwórz ekran logowania i ustaw kursor w polu loginu." };
                dialog.Controls.AddRange(new Control[] {
                    new Label { Text = "Zapisane profile", Location = new Point(14, 12), AutoSize = true },
                    list, newButton, deleteButton,
                    new Label { Text = "Nazwa profilu", Location = new Point(237, 38), AutoSize = true }, label,
                    new Label { Text = "Login", Location = new Point(237, 98), AutoSize = true }, login,
                    new Label { Text = "Hasło", Location = new Point(237, 160), AutoSize = true }, password,
                    hint, saveButton, defaultButton, launchProfile, fillButton, info
                });

                WowAccount editing = null;
                Action refresh = delegate
                {
                    var selectedId = editing == null ? "" : editing.Id;
                    list.Items.Clear();
                    foreach (var account in accountVault.Data.Accounts)
                        list.Items.Add(new WowAccountListItem(account, account.Id == accountVault.Data.SelectedId));
                    for (int i = 0; i < list.Items.Count; i++)
                        if (((WowAccountListItem)list.Items[i]).Account.Id == selectedId) { list.SelectedIndex = i; break; }
                    deleteButton.Enabled = editing != null;
                    defaultButton.Enabled = editing != null;
                    fillButton.Enabled = editing != null;
                };
                list.SelectedIndexChanged += delegate
                {
                    var item = list.SelectedItem as WowAccountListItem;
                    editing = item == null ? null : item.Account;
                    label.Text = editing == null ? "" : editing.Label;
                    login.Text = editing == null ? "" : editing.Login;
                    password.Clear(); // Never put the decrypted password into a UI text box.
                    deleteButton.Enabled = editing != null;
                    defaultButton.Enabled = editing != null;
                    fillButton.Enabled = editing != null;
                };
                newButton.Click += delegate
                {
                    list.ClearSelected(); editing = null;
                    label.Clear(); login.Clear(); password.Clear();
                    label.Focus();
                };
                saveButton.Click += delegate
                {
                    try
                    {
                        var name = label.Text.Trim();
                        var username = login.Text.Trim();
                        if (name.Length == 0 || username.Length == 0)
                            throw new InvalidOperationException("Wpisz nazwę profilu i login.");
                        if (editing == null && accountVault.Data.Accounts.Count >= 128)
                            throw new InvalidOperationException("Limit 128 kont został osiągnięty.");
                        var protectedPassword = password.Text.Length == 0
                            ? (editing == null ? "" : editing.ProtectedPassword)
                            : accountVault.Protect(password.Text);
                        if (protectedPassword.Length == 0)
                            throw new InvalidOperationException("Wpisz hasło nowego konta.");
                        if (editing == null)
                        {
                            editing = new WowAccount { Id = Guid.NewGuid().ToString("N") };
                            accountVault.Data.Accounts.Add(editing);
                        }
                        editing.Label = name; editing.Login = username;
                        editing.ProtectedPassword = protectedPassword;
                        if (accountVault.Selected == null) accountVault.Data.SelectedId = editing.Id;
                        accountVault.Save();
                        password.Clear(); refresh();
                        Log("Zapisano profil WoW: " + name + ".");
                    }
                    catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "Konta WoW", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                };
                defaultButton.Click += delegate
                {
                    if (editing == null) return;
                    try
                    {
                        accountVault.Data.SelectedId = editing.Id;
                        accountVault.Save(); refresh();
                    }
                    catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "Konta WoW", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                };
                deleteButton.Click += delegate
                {
                    if (editing == null) return;
                    if (MessageBox.Show(dialog, "Usunąć profil " + editing.Label + "?", "Konta WoW",
                        MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                    try
                    {
                        accountVault.Data.Accounts.Remove(editing);
                        if (accountVault.Data.SelectedId == editing.Id)
                            accountVault.Data.SelectedId = accountVault.Data.Accounts.Count == 0 ? "" : accountVault.Data.Accounts[0].Id;
                        editing = null;
                        accountVault.Save(); refresh();
                        label.Clear(); login.Clear(); password.Clear();
                    }
                    catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "Konta WoW", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                };
                launchProfile.Click += delegate
                {
                    if (editing == null) { MessageBox.Show(dialog, "Wybierz zapisany profil."); return; }
                    try
                    {
                        accountVault.Data.SelectedId = editing.Id;
                        accountVault.Save();
                        dialog.Close();
                        LaunchGame();
                    }
                    catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "Konta WoW", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                };
                fillButton.Click += delegate
                {
                    if (editing == null) return;
                    var session = accountSessions.LastOrDefault(s =>
                    {
                        if (s.AccountId != editing.Id) return false;
                        try { return !s.Game.HasExited; } catch { return false; }
                    });
                    if (session == null)
                    {
                        MessageBox.Show(dialog, "Najpierw uruchom grę dla tego profilu z updatera.", "Konta WoW");
                        return;
                    }
                    if (MessageBox.Show(dialog,
                        "Czy wybrany klient WoW jest na ekranie logowania, a kursor znajduje się w polu LOGINU?\n\n" +
                        "Updater wyśle login, TAB i hasło TYLKO do tego uruchomionego procesu. Nie naciśnie Enter. " +
                        "Nie używaj tej funkcji w grze, na czacie ani w innym oknie.",
                        "Potwierdź ekran logowania", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                    try
                    {
                        FillCredentials(session.Game, editing, accountVault.Unprotect(editing));
                        Log("Dane konta wpisano do klienta PID " + session.Game.Id + ". Potwierdź logowanie w grze.");
                        dialog.Close();
                    }
                    catch (Exception ex)
                    {
                        MessageBox.Show(dialog, "Nie wpisano danych: " + ex.Message, "Konta WoW",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                };
                editing = accountVault.Selected;
                refresh();
                dialog.ShowDialog(this);
            }
        }

        internal void AccountSmoke(string folder)
        {
            var path = Path.Combine(folder, "account-vault-smoke.json");
            var vault = new WowAccountVault(path);
            if (vault.Selected != null) throw new Exception("Account smoke: empty vault is not empty");
            var accountA = new WowAccount { Id = "a", Label = "Rogue", Login = "rogue_login", ProtectedPassword = vault.Protect("vault-test-secret-A") };
            var accountB = new WowAccount { Id = "b", Label = "Priest", Login = "priest_login", ProtectedPassword = vault.Protect("vault-test-secret-B") };
            vault.Data.Accounts.Add(accountA); vault.Data.Accounts.Add(accountB);
            vault.Data.SelectedId = "b";
            vault.Save();
            var stored = File.ReadAllText(path);
            if (stored.Contains("vault-test-secret") || stored.Contains("DPAPI plaintext"))
                throw new Exception("Account smoke: password leaked to local vault");
            var loaded = new WowAccountVault(path);
            loaded.Load();
            if (loaded.Selected == null || loaded.Selected.Id != "b" || loaded.Data.Accounts.Count != 2
                || loaded.Unprotect(loaded.Data.Accounts[0]) != "vault-test-secret-A"
                || loaded.Unprotect(loaded.Data.Accounts[1]) != "vault-test-secret-B")
                throw new Exception("Account smoke: encrypted profile roundtrip failed");
            loaded.Data.Accounts.RemoveAt(0);
            loaded.Save();
            var afterDelete = new WowAccountVault(path); afterDelete.Load();
            if (afterDelete.Data.Accounts.Count != 1 || afterDelete.Selected.Id != "b")
                throw new Exception("Account smoke: account deletion/default persistence failed");
            if (!featureControls.ContainsKey("accounts"))
                throw new Exception("Account smoke: accounts UI not registered");
        }

        private sealed class WowAccountListItem
        {
            public readonly WowAccount Account;
            public readonly bool Default;
            public WowAccountListItem(WowAccount account, bool isDefault) { Account = account; Default = isDefault; }
            public override string ToString() { return Account.Label + (Default ? "  [domyślne]" : ""); }
        }

        // A password is sent only after the user explicitly confirms the login screen.
        // Each key is preceded by a foreground PID check; no clipboard or command line is used.
        private static void FillCredentials(System.Diagnostics.Process process, WowAccount account, string password)
        {
            if (process == null || process.HasExited) throw new InvalidOperationException("Klient jest zamknięty.");
            process.Refresh();
            var window = process.MainWindowHandle;
            if (window == IntPtr.Zero) throw new InvalidOperationException("Okno gry nie jest jeszcze gotowe.");
            if (!SetForegroundWindow(window))
                throw new InvalidOperationException("Nie udało się aktywować okna gry.");
            Thread.Sleep(180);
            EnsureGameForeground(process.Id);
            SendVirtual(process.Id, 0x11, false); // CTRL down
            SendVirtual(process.Id, 0x41, false); // A down
            SendVirtual(process.Id, 0x41, true);
            SendVirtual(process.Id, 0x11, true);
            SendUnicode(process.Id, account.Login);
            SendVirtual(process.Id, 0x09, false); // TAB
            SendVirtual(process.Id, 0x09, true);
            SendVirtual(process.Id, 0x11, false);
            SendVirtual(process.Id, 0x41, false);
            SendVirtual(process.Id, 0x41, true);
            SendVirtual(process.Id, 0x11, true);
            SendUnicode(process.Id, password);
            // No Enter: human remains in control of the login action.
        }

        private static void EnsureGameForeground(int expectedPid)
        {
            uint actual;
            var window = GetForegroundWindow();
            if (window == IntPtr.Zero) throw new InvalidOperationException("Okno gry straciło fokus.");
            GetWindowThreadProcessId(window, out actual);
            if (actual != (uint)expectedPid)
                throw new InvalidOperationException("Aktywny jest inny proces. Wpisywanie przerwano.");
        }

        private static void SendUnicode(int pid, string value)
        {
            foreach (var ch in value)
            {
                EnsureGameForeground(pid);
                SendKey(pid, 0, ch, 0x0004);
                SendKey(pid, 0, ch, 0x0004 | 0x0002);
            }
        }

        private static void SendVirtual(int pid, ushort key, bool keyUp)
        {
            SendKey(pid, key, 0, keyUp ? 0x0002u : 0u);
        }

        private static void SendKey(int pid, ushort key, ushort scan, uint flags)
        {
            EnsureGameForeground(pid);
            var input = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = key, wScan = scan, dwFlags = flags } };
            if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
                throw new InvalidOperationException("Windows odrzucił wysłanie klawisza (sprawdź uprawnienia klienta).");
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx, dy, mouseData, dwFlags, time;
            public IntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk, wScan;
            public uint dwFlags, time;
            public IntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Explicit)]
        private struct INPUT
        {
            [FieldOffset(0)] public int type;
            [FieldOffset(4)] public MOUSEINPUT mi;
            [FieldOffset(4)] public KEYBDINPUT ki;
        }
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    }
}
