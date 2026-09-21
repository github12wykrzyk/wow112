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
                var hint = new Label { Location = new Point(237, 210), Size = new Size(430, 40),
                    Text = "Nowy profil: wpisz hasło i kliknij Zapisz profil." };
                var newButton = new Button { Text = "Nowe", Location = new Point(14, 360), Size = new Size(96, 32) };
                var deleteButton = new Button { Text = "Usuń", Location = new Point(120, 360), Size = new Size(96, 32) };
                var saveButton = new Button { Text = "Zapisz profil", Location = new Point(237, 253), Size = new Size(142, 32) };
                var defaultButton = new Button { Text = "Ustaw domyślne", Location = new Point(386, 253), Size = new Size(138, 32) };
                var launchProfile = new Button { Text = "Uruchom grę z profilem", Location = new Point(237, 306), Size = new Size(209, 36) };
                var fillButton = new Button { Text = "Wpisz dane do gry", Location = new Point(453, 306), Size = new Size(216, 36) };
                var info = new Label { Location = new Point(14, 402), Size = new Size(660, 44),
                    Text = "Zapisane hasła są szyfrowane. Uruchom grę z profilem, ustaw kursor w polu loginu, wróć tutaj i kliknij Wpisz dane do gry." };
                dialog.Controls.AddRange(new Control[] {
                    new Label { Text = "Zapisane profile", Location = new Point(14, 12), AutoSize = true },
                    list, newButton, deleteButton,
                    new Label { Text = "Nazwa profilu", Location = new Point(237, 38), AutoSize = true }, label,
                    new Label { Text = "Login", Location = new Point(237, 98), AutoSize = true }, login,
                    new Label { Text = "Hasło", Location = new Point(237, 160), AutoSize = true }, password,
                    hint, saveButton, defaultButton, launchProfile, fillButton, info
                });

                WowAccount editing = null;
                password.TextChanged += delegate
                {
                    if (password.Text.Length > 0)
                    {
                        hint.Text = "Nowe hasło zostanie zapisane po kliknięciu Zapisz profil.";
                        hint.ForeColor = SystemColors.ControlText;
                    }
                };
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
                    password.Clear(); // Displaying a blank field does NOT mean the saved password is missing.
                    ShowPasswordStatus(hint, accountVault, editing);
                    deleteButton.Enabled = editing != null;
                    defaultButton.Enabled = editing != null;
                    fillButton.Enabled = editing != null;
                };
                newButton.Click += delegate
                {
                    list.ClearSelected(); editing = null;
                    label.Clear(); login.Clear(); password.Clear();
                    ShowPasswordStatus(hint, accountVault, null);
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
                        // Re-open the on-disk vault and decrypt it before reporting success.
                        var diskVault = new WowAccountVault(Path.Combine(configDir, "wow_accounts.json"));
                        diskVault.Load();
                        var diskAccount = diskVault.Data.Accounts.FirstOrDefault(a => a.Id == editing.Id);
                        if (diskAccount == null || !string.Equals(diskAccount.Login, username, StringComparison.Ordinal)
                            || (password.Text.Length > 0 && diskVault.Unprotect(diskAccount) != password.Text)
                            || string.IsNullOrEmpty(diskVault.Unprotect(diskAccount)))
                            throw new IOException("Nie udało się potwierdzić zapisu i odczytu hasła.");
                        accountVault = diskVault;
                        editing = diskAccount;
                        password.Clear(); refresh();
                        ShowPasswordStatus(hint, accountVault, editing);
                        Log("Potwierdzono zapis i odczyt hasła profilu WoW: " + name + ".");
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
                    WowAccountSession session;
                    try { session = ResolveAccountSession(editing, dialog); }
                    catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "Konta WoW", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
                    if (session == null) return;
                    if (MessageBox.Show(dialog,
                        "Czy wybrany klient WoW jest na ekranie logowania, a kursor znajduje się w polu LOGINU?\n\n" +
                        "Updater aktywuje wskazane okno WoW, sprawdzi jego PID przed każdym klawiszem i wprowadzi login, TAB oraz hasło. " +
                        "Nie naciśnie Enter. Nie uruchamiaj tej funkcji na czacie ani po zalogowaniu.",
                        "Potwierdź ekran logowania", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                    try
                    {
                        FillCredentials(session.Game, editing, accountVault.Unprotect(editing));
                        Log("Wysłano klawisze logowania do WoW (PID " + session.Game.Id + "); sprawdź oba pola przed zatwierdzeniem.");
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
            // Validate the physical-key translator using a test string only; no real accounts or focus changes.
            if (PrepareKeys("Ab9@!.-", GetKeyboardLayout(0)).Count != 7)
                throw new Exception("Account smoke: keyboard translation failed");
        }

        private sealed class WowAccountListItem
        {
            public readonly WowAccount Account;
            public readonly bool Default;
            public WowAccountListItem(WowAccount account, bool isDefault) { Account = account; Default = isDefault; }
            public override string ToString() { return Account.Label + (Default ? "  [domyślne]" : ""); }
        }

        private static void ShowPasswordStatus(Label hint, WowAccountVault vault, WowAccount account)
        {
            if (account == null)
            {
                hint.Text = "Nowy profil: wpisz hasło i kliknij Zapisz profil.";
                hint.ForeColor = SystemColors.ControlText;
                return;
            }
            try
            {
                if (string.IsNullOrEmpty(vault.Unprotect(account)))
                    throw new InvalidDataException("Puste hasło.");
                hint.Text = "Hasło zapisane i możliwe do odczytu (DPAPI). Pole powyżej celowo pozostaje puste.";
                hint.ForeColor = Color.DarkGreen;
            }
            catch
            {
                hint.Text = "Hasło jest nieczytelne. Wpisz nowe i kliknij Zapisz profil.";
                hint.ForeColor = Color.DarkRed;
            }
        }

        private WowAccountSession ResolveAccountSession(WowAccount account, IWin32Window owner)
        {
            var root = gameDir.Text.Trim();
            if (!Directory.Exists(root))
                throw new InvalidOperationException("Wybierz istniejący katalog gry w updaterze.");
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var candidates = new List<System.Diagnostics.Process>();
            foreach (var process in System.Diagnostics.Process.GetProcesses())
            {
                try
                {
                    if (process.HasExited || process.MainWindowHandle == IntPtr.Zero) continue;
                    var fullPath = Path.GetFullPath(process.MainModule.FileName);
                    var name = Path.GetFileName(fullPath);
                    if (!fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)
                        || !name.StartsWith("WoW", StringComparison.OrdinalIgnoreCase)
                        || !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
                    candidates.Add(process);
                }
                catch (System.ComponentModel.Win32Exception) { }
                catch (InvalidOperationException) { }
                finally { if (!candidates.Contains(process)) process.Dispose(); }
            }
            if (candidates.Count == 0)
                throw new InvalidOperationException("Nie znaleziono uruchomionego okna WoW w wybranym katalogu gry.");

            var existing = accountSessions.LastOrDefault(session =>
                session.AccountId == account.Id && candidates.Any(p => p.Id == session.Game.Id));
            var chosen = existing == null ? null : candidates.FirstOrDefault(p => p.Id == existing.Game.Id);
            if (chosen == null && candidates.Count == 1) chosen = candidates[0];
            if (chosen == null)
            {
                using (var picker = new Form
                {
                    Text = "Wybierz klienta WoW dla profilu: " + account.Label,
                    ClientSize = new Size(420, 128), StartPosition = FormStartPosition.CenterParent,
                    FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false
                })
                {
                    var selector = new ComboBox { Location = new Point(12, 13), Width = 395, DropDownStyle = ComboBoxStyle.DropDownList };
                    foreach (var process in candidates.OrderBy(p => p.Id))
                        selector.Items.Add(new RunningGameItem(process));
                    selector.SelectedIndex = 0;
                    var ok = new Button { Text = "Użyj tego okna", DialogResult = DialogResult.OK, Location = new Point(226, 74), Width = 180 };
                    picker.Controls.Add(selector); picker.Controls.Add(ok);
                    picker.AcceptButton = ok;
                    if (picker.ShowDialog(owner) == DialogResult.OK)
                        chosen = ((RunningGameItem)selector.SelectedItem).Game;
                }
            }
            foreach (var process in candidates)
                if (process != chosen) process.Dispose();
            if (chosen == null) return null;
            var sessionResult = new WowAccountSession { Game = chosen, AccountId = account.Id };
            accountSessions.RemoveAll(old => old.AccountId == account.Id);
            accountSessions.Add(sessionResult);
            return sessionResult;
        }

        private sealed class RunningGameItem
        {
            internal readonly System.Diagnostics.Process Game;
            internal RunningGameItem(System.Diagnostics.Process process) { Game = process; }
            public override string ToString() { return "WoW • PID " + Game.Id + " • " + Game.MainWindowTitle; }
        }

        // The 5875 client may ignore KEYEVENTF_UNICODE; emit physical scancodes instead.
        // All mappings are checked before touching either login field.
        private static void FillCredentials(System.Diagnostics.Process process, WowAccount account, string password)
        {
            if (process == null || process.HasExited)
                throw new InvalidOperationException("Wybrany klient WoW jest zamknięty.");
            process.Refresh();
            var window = process.MainWindowHandle;
            if (window == IntPtr.Zero)
                throw new InvalidOperationException("Okno WoW nie jest jeszcze gotowe.");
            uint pid;
            uint thread = GetWindowThreadProcessId(window, out pid);
            if (pid != (uint)process.Id || thread == 0)
                throw new InvalidOperationException("Nie udało się potwierdzić procesu WoW.");
            var layout = GetKeyboardLayout(thread);
            var loginKeys = PrepareKeys(account.Login, layout);
            var passwordKeys = PrepareKeys(password, layout);
            // Confirm modal has just closed. Windows may refuse activation: fail closed.
            SetForegroundWindow(window);
            Thread.Sleep(240);
            EnsureGameForeground(process.Id);
            SendChord(process.Id, new KeyStroke { Scan = 0x1e, Modifiers = 2 }); // CTRL+A: scan 'A'
            SendPrepared(process.Id, loginKeys);
            SendScan(process.Id, 0x0f, false, false); // TAB down
            Thread.Sleep(45);
            SendScan(process.Id, 0x0f, true, false);
            Thread.Sleep(70);
            SendChord(process.Id, new KeyStroke { Scan = 0x1e, Modifiers = 2 }); // CTRL+A
            SendPrepared(process.Id, passwordKeys);
            // No Enter. User verifies fields and submits manually.
        }

        private struct KeyStroke
        {
            public ushort Scan;
            public byte Modifiers;
            public bool Extended;
        }

        private static List<KeyStroke> PrepareKeys(string text, IntPtr keyboardLayout)
        {
            if (string.IsNullOrEmpty(text))
                throw new InvalidOperationException("Login lub hasło jest puste.");
            var keys = new List<KeyStroke>(text.Length);
            foreach (char ch in text)
            {
                var mapped = VkKeyScanEx(ch, keyboardLayout);
                if (mapped == -1 || (((int)mapped >> 8) & ~7) != 0)
                    throw new InvalidOperationException("Login lub hasło zawiera znak nieobsługiwany przez aktualny układ klawiatury. Nie wysłano danych.");
                var vk = (ushort)((ushort)mapped & 0xff);
                var scan = MapVirtualKeyEx(vk, 0, keyboardLayout);
                if (scan == 0 || scan > ushort.MaxValue)
                    throw new InvalidOperationException("Nie znaleziono fizycznego klawisza dla loginu lub hasła.");
                keys.Add(new KeyStroke { Scan = (ushort)scan, Modifiers = (byte)((mapped >> 8) & 7), Extended = false });
            }
            return keys;
        }

        private static void SendPrepared(int pid, List<KeyStroke> keys)
        {
            foreach (var key in keys) SendChord(pid, key);
        }

        private static void SendChord(int pid, KeyStroke key)
        {
            // For AltGr layouts use the right Alt physical key, otherwise Ctrl/Shift.
            bool shift = (key.Modifiers & 1) != 0;
            bool altGr = (key.Modifiers & 6) == 6;
            bool ctrl = (key.Modifiers & 2) != 0 && !altGr;
            bool alt = (key.Modifiers & 4) != 0 && !altGr;
            try
            {
                if (shift) SendScan(pid, 0x2a, false, false);
                if (ctrl) SendScan(pid, 0x1d, false, false);
                if (alt) SendScan(pid, 0x38, false, false);
                if (altGr) SendScan(pid, 0x38, false, true);
                SendScan(pid, key.Scan, false, key.Extended);
                Thread.Sleep(40);
                SendScan(pid, key.Scan, true, key.Extended);
                Thread.Sleep(22);
            }
            finally
            {
                // Never leave held modifiers on a focus-loss or partial-input error.
                if (altGr) ReleaseScan(0x38, true);
                if (alt) ReleaseScan(0x38, false);
                if (ctrl) ReleaseScan(0x1d, false);
                if (shift) ReleaseScan(0x2a, false);
            }
        }

        private static void EnsureGameForeground(int expectedPid)
        {
            uint actual;
            var window = GetForegroundWindow();
            if (window == IntPtr.Zero)
                throw new InvalidOperationException("Okno WoW nie jest aktywne.");
            GetWindowThreadProcessId(window, out actual);
            if (actual != (uint)expectedPid)
                throw new InvalidOperationException("Zmieniło się aktywne okno; wpisywanie przerwano.");
        }

        private static void SendScan(int pid, ushort scan, bool up, bool extended)
        {
            EnsureGameForeground(pid);
            SendScanUnchecked(scan, up, extended);
        }

        private static void ReleaseScan(ushort scan, bool extended)
        {
            // Key-up only, even after a focus switch; no credentials are sent.
            SendScanUnchecked(scan, true, extended);
        }

        private static void SendScanUnchecked(ushort scan, bool up, bool extended)
        {
            uint flags = 0x0008u | (up ? 0x0002u : 0u) | (extended ? 0x0001u : 0u);
            var input = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = 0, wScan = scan, dwFlags = flags } };
            if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
                throw new InvalidOperationException("Windows odrzucił klawisz (możliwa różnica uprawnień klienta/updatera).");
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
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern short VkKeyScanEx(char character, IntPtr keyboardLayout);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern uint MapVirtualKeyEx(uint key, uint mapType, IntPtr keyboardLayout);
        [DllImport("user32.dll")]
        private static extern IntPtr GetKeyboardLayout(uint threadId);
    }
}
