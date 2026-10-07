using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace WoW112.OperatorConsole
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WoW112", "OperatorConsole");
            var smokeDir = GetArg(args, "--ui-smoke");
            var demo = args.Any(x => string.Equals(x, "--demo", StringComparison.OrdinalIgnoreCase)) || !string.IsNullOrEmpty(smokeDir);
            using (var app = new OperatorApplication(root))
            using (var form = new OperatorConsoleForm(app))
            {
                if (demo) app.EmitDemoEvents();
                if (!string.IsNullOrEmpty(smokeDir))
                {
                    form.Shown += delegate
                    {
                        try
                        {
                            Directory.CreateDirectory(smokeDir);
                            using (var bitmap = new Bitmap(form.Width, form.Height))
                            {
                                form.DrawToBitmap(bitmap, new Rectangle(0, 0, bitmap.Width, bitmap.Height));
                                bitmap.Save(Path.Combine(smokeDir, "operator-console.png"));
                            }
                            File.WriteAllText(Path.Combine(smokeDir, "result.txt"), "PASS Operator Console UI rendered.\r\n", Encoding.UTF8);
                        }
                        catch (Exception ex)
                        {
                            File.WriteAllText(Path.Combine(smokeDir, "failure.txt"), SecretSanitizer.Sanitize(ex.ToString()), Encoding.UTF8);
                            Environment.ExitCode = 2;
                        }
                        finally { form.BeginInvoke(new Action(form.Close)); }
                    };
                }
                Application.Run(form);
            }
        }

        private static string GetArg(string[] args, string name)
        {
            for (int i = 0; i + 1 < args.Length; i++) if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            return "";
        }
    }

    internal sealed class OperatorApplication : IDisposable
    {
        private readonly object gate = new object();
        private readonly List<OperatorEvent> events = new List<OperatorEvent>();
        private readonly string root;
        public readonly OperatorEventBus Bus = new OperatorEventBus();
        public readonly OperatorStateStore State = new OperatorStateStore();
        public readonly JsonlOperatorStore Store;
        public readonly FileOperatorBridge Bridge;
        public event Action Changed;

        public OperatorApplication(string rootDirectory)
        {
            root = rootDirectory;
            Directory.CreateDirectory(root);
            Store = new JsonlOperatorStore(Path.Combine(root, "history"));
            foreach (var e in Store.Load(50000)) { State.Apply(e); events.Add(e); }
            Bridge = new FileOperatorBridge(Path.Combine(root, "bridge"), Bus);
            Bus.Published += OnEvent;
        }

        private void OnEvent(OperatorEvent e)
        {
            State.Apply(e);
            Store.Append(e);
            lock (gate)
            {
                events.Add(e);
                if (events.Count > 50000) events.RemoveRange(0, events.Count - 50000);
            }
            var changed = Changed; if (changed != null) changed();
        }

        public List<OperatorEvent> EventsSnapshot()
        {
            lock (gate) return events.ToList();
        }

        public void SendManualWhisper(string player, string text, SessionState target)
        {
            if (target == null) throw new InvalidOperationException("Select an active session before sending a whisper.");
            if (string.IsNullOrWhiteSpace(player)) throw new InvalidOperationException("Select a player conversation.");
            if (string.IsNullOrWhiteSpace(text)) return;
            if (text.Length > 240) throw new InvalidOperationException("Whisper exceeds the 240 character operator safety limit.");
            var corr = Guid.NewGuid().ToString("N");
            Bridge.Submit(new OperatorCommand {
                CommandType = OperatorCommandType.ReplyToWhisper, Account = target.Account, Profile = target.Profile, Character = target.Character,
                SessionId = target.SessionId, Player = player.Trim(), Text = text, CorrelationId = corr
            });
            Bus.Publish(new OperatorEvent {
                Severity = OperatorSeverity.Info, Category = "Whisper", EventType = "OperatorCommandQueued", Module = "OperatorConsole",
                Account = target.Account, Profile = target.Profile, Character = target.Character, SessionId = target.SessionId, CorrelationId = corr,
                Message = "Manual whisper queued for backend acknowledgement.", Direction = OperatorDirection.System,
                Metadata = new Dictionary<string, object> { { "player", player.Trim() }, { "command", "ReplyToWhisper" } }
            });
        }

        public string DebugSnapshot()
        {
            var sb = new StringBuilder();
            sb.AppendLine("WoW112 Operator Console debug snapshot");
            sb.AppendLine("generated_utc=" + DateTime.UtcNow.ToString("O"));
            var counters = State.Counters();
            sb.AppendLine("whispers total=" + counters.Total + " understood=" + counters.Understood + " ignored=" + counters.IgnoredIntentionally + " unhandled=" + counters.Unhandled);
            foreach (var s in State.Sessions())
                sb.AppendLine("session=" + s.SessionId + " char=" + s.Character + " connected=" + s.Connected + " world=" + s.World + " ah=" + s.Ah + " summon=" + s.Summon + " mail=" + s.Mail + " coordinator=" + s.Coordinator + " last=" + s.LastEvent + " error=" + s.LastError);
            foreach (var e in EventsSnapshot().Where(x => x.Severity >= OperatorSeverity.Warn).TakeLastCompat(50))
                sb.AppendLine(e.TimestampUtc.ToString("O") + " " + e.Severity + " " + e.Character + " " + e.Module + " " + e.EventType + " " + e.Message);
            return SecretSanitizer.Sanitize(sb.ToString());
        }

        public void EmitDemoEvents()
        {
            var sid = "demo-smokinpole";
            Bus.Publish(E("SessionStarted", "Core", "Demo session started", sid, "Smokinpole"));
            Bus.Publish(E("LoginSucceeded", "World", "Connected to world", sid, "Smokinpole"));
            var whisper = E("WhisperReceived", "Whisper", "need hyjal pls", sid, "Smokinpole");
            whisper.Direction = OperatorDirection.Incoming;
            whisper.Metadata["player"] = "PlayerX";
            whisper.Metadata["parser"] = new Dictionary<string, object> { { "sender", "PlayerX" }, { "raw", "need hyjal pls" }, { "normalized", "need hyjal pls" }, { "result", "summon" }, { "destination", "Hyjal" }, { "intent", "request" }, { "keywords", "need,hyjal" }, { "matched_rule", "destination+request" }, { "reason", "recognized summon request" }, { "confidence", 1.0 }, { "competition", false }, { "summon_request", true } };
            Bus.Publish(whisper);
            Bus.Publish(E("WhisperParsed", "Whisper", "PlayerX classified as Hyjal summon request", sid, "Smokinpole", "PlayerX"));
            Bus.Publish(E("SummonQueued", "Summon", "PlayerX queued for Hyjal", sid, "Smokinpole", "PlayerX"));
            var payment = E("PaymentReceived", "Payment", "Received 4g from PlayerX", sid, "Smokinpole", "PlayerX"); payment.Metadata["copper"] = 40000; payment.Metadata["destination"] = "Hyjal"; Bus.Publish(payment);
            var uncertain = E("MutationCoordinatorUncertain", "Mutation", "Example hard-stop visibility", sid, "Smokinpole"); uncertain.Severity = OperatorSeverity.Warn; uncertain.OperationId = "demo-op-uncertain"; Bus.Publish(uncertain);
        }

        private static OperatorEvent E(string type, string module, string message, string sid, string character, string player = "")
        {
            var e = new OperatorEvent { EventType = type, Category = module, Module = module, Message = message, SessionId = sid, Character = character, Account = "demo-account", Profile = "demo", CorrelationId = Guid.NewGuid().ToString("N") };
            if (!string.IsNullOrEmpty(player)) e.Metadata["player"] = player;
            return e;
        }

        public void Dispose() { Bridge.Dispose(); Store.Dispose(); }
    }

    internal sealed class OperatorConsoleForm : Form
    {
        private readonly OperatorApplication app;
        private readonly TabControl tabs = new TabControl();
        private readonly DataGridView overview = Grid();
        private readonly DataGridView eventsGrid = Grid();
        private readonly DataGridView summonGrid = Grid();
        private readonly DataGridView mutationGrid = Grid();
        private readonly ListBox conversations = new ListBox();
        private readonly ListBox transcript = new ListBox();
        private readonly TextBox reply = new TextBox();
        private readonly TextBox search = new TextBox();
        private readonly ComboBox severity = new ComboBox();
        private readonly ComboBox module = new ComboBox();
        private readonly CheckBox autoScroll = new CheckBox();
        private readonly CheckBox pauseView = new CheckBox();
        private readonly Label whisperStats = new Label();
        private readonly TextBox parserDebug = new TextBox();
        private readonly TextBox debugText = new TextBox();
        private readonly TextBox logsText = new TextBox();
        private string selectedPlayer = "";

        public OperatorConsoleForm(OperatorApplication application)
        {
            app = application;
            Text = "WoW112 Operator Console V1";
            Width = 1550; Height = 900; StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(24, 26, 31); ForeColor = Color.Gainsboro;
            Font = new Font("Segoe UI", 9F);
            tabs.Dock = DockStyle.Fill;
            tabs.Appearance = TabAppearance.Normal;
            Controls.Add(tabs);
            BuildOverview(); BuildWhispers(); BuildWhisperDebug(); BuildEvents(); BuildDebug(); BuildLogs(); BuildSummons(); BuildMutations();
            app.Changed += OnAppChanged;
            FormClosed += delegate { app.Changed -= OnAppChanged; };
            RefreshAll();
        }

        private void BuildOverview()
        {
            var page = Page("OVERVIEW");
            overview.Dock = DockStyle.Fill;
            AddColumns(overview, "Character", "Account/Profile", "Connected", "World", "AH", "Summon", "Mail", "Coordinator", "Current task", "Last activity", "Last event", "Last error");
            page.Controls.Add(overview); tabs.TabPages.Add(page);
        }

        private void BuildWhispers()
        {
            var page = Page("WHISPERS");
            var split = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 340, BackColor = BackColor };
            conversations.Dock = DockStyle.Fill; StyleList(conversations); conversations.SelectedIndexChanged += delegate { selectedPlayer = Convert.ToString(conversations.SelectedItem) ?? ""; RefreshConversation(); };
            split.Panel1.Controls.Add(conversations);
            var right = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, BackColor = BackColor };
            right.RowStyles.Add(new RowStyle(SizeType.Absolute, 30)); right.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); right.RowStyles.Add(new RowStyle(SizeType.Absolute, 90));
            whisperStats.Dock = DockStyle.Fill; whisperStats.ForeColor = Color.Gainsboro; right.Controls.Add(whisperStats, 0, 0);
            transcript.Dock = DockStyle.Fill; StyleList(transcript); transcript.Font = new Font("Consolas", 9F); right.Controls.Add(transcript, 0, 1);
            var compose = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = BackColor };
            compose.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); compose.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
            reply.Dock = DockStyle.Fill; reply.Multiline = true; reply.AcceptsReturn = true; reply.BackColor = Color.FromArgb(35, 38, 45); reply.ForeColor = Color.White; reply.KeyDown += ReplyKeyDown;
            var send = Button("SEND"); send.Dock = DockStyle.Fill; send.Click += delegate { SendReply(); };
            compose.Controls.Add(reply, 0, 0); compose.Controls.Add(send, 1, 0); right.Controls.Add(compose, 0, 2);
            split.Panel2.Controls.Add(right); page.Controls.Add(split); tabs.TabPages.Add(page);
        }

        private void BuildWhisperDebug()
        {
            var page = Page("WHISPER DEBUG");
            parserDebug.Dock = DockStyle.Fill; parserDebug.Multiline = true; parserDebug.ReadOnly = true; parserDebug.ScrollBars = ScrollBars.Both; parserDebug.Font = new Font("Consolas", 9F); parserDebug.BackColor = Color.FromArgb(19, 21, 25); parserDebug.ForeColor = Color.Gainsboro;
            page.Controls.Add(parserDebug); tabs.TabPages.Add(page);
        }

        private void BuildEvents()
        {
            var page = Page("EVENTS");
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, BackColor = BackColor };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            var filters = new FlowLayoutPanel { Dock = DockStyle.Fill, BackColor = BackColor, Padding = new Padding(6) };
            search.Width = 260; search.BackColor = Color.FromArgb(35, 38, 45); search.ForeColor = Color.White; search.TextChanged += delegate { RefreshEvents(); };
            severity.DropDownStyle = ComboBoxStyle.DropDownList; severity.Items.AddRange(new object[] { "INFO+", "WARN+", "ERROR", "DEBUG+", "TRACE" }); severity.SelectedIndex = 0; severity.SelectedIndexChanged += delegate { RefreshEvents(); };
            module.DropDownStyle = ComboBoxStyle.DropDownList; module.Width = 160; module.SelectedIndexChanged += delegate { RefreshEvents(); };
            autoScroll.Text = "Auto-scroll"; autoScroll.Checked = true; autoScroll.ForeColor = ForeColor;
            pauseView.Text = "Pause view"; pauseView.ForeColor = ForeColor;
            var clear = Button("Clear VIEW"); clear.Click += delegate { eventsGrid.Rows.Clear(); };
            filters.Controls.Add(new Label { Text = "Search", AutoSize = true, ForeColor = ForeColor, Padding = new Padding(0, 5, 0, 0) }); filters.Controls.Add(search); filters.Controls.Add(severity); filters.Controls.Add(module); filters.Controls.Add(autoScroll); filters.Controls.Add(pauseView); filters.Controls.Add(clear);
            eventsGrid.Dock = DockStyle.Fill; AddColumns(eventsGrid, "Time", "Severity", "Character", "Module", "Event", "Summary", "Operation ID");
            layout.Controls.Add(filters, 0, 0); layout.Controls.Add(eventsGrid, 0, 1); page.Controls.Add(layout); tabs.TabPages.Add(page);
        }

        private void BuildDebug()
        {
            var page = Page("DEBUG");
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, BackColor = BackColor };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            var copy = Button("Copy debug snapshot"); copy.Dock = DockStyle.Left; copy.Width = 190; copy.Click += delegate { var text = app.DebugSnapshot(); Clipboard.SetText(text); debugText.Text = text; };
            debugText.Dock = DockStyle.Fill; debugText.Multiline = true; debugText.ReadOnly = true; debugText.ScrollBars = ScrollBars.Both; debugText.Font = new Font("Consolas", 9F); debugText.BackColor = Color.FromArgb(19, 21, 25); debugText.ForeColor = Color.Gainsboro;
            layout.Controls.Add(copy, 0, 0); layout.Controls.Add(debugText, 0, 1); page.Controls.Add(layout); tabs.TabPages.Add(page);
        }

        private void BuildLogs()
        {
            var page = Page("LOGS"); logsText.Dock = DockStyle.Fill; logsText.Multiline = true; logsText.ReadOnly = true; logsText.ScrollBars = ScrollBars.Both; logsText.Font = new Font("Consolas", 9F); logsText.BackColor = Color.FromArgb(19, 21, 25); logsText.ForeColor = Color.Gainsboro; page.Controls.Add(logsText); tabs.TabPages.Add(page);
        }

        private void BuildSummons()
        {
            var page = Page("SUMMON / PAYMENTS"); summonGrid.Dock = DockStyle.Fill; AddColumns(summonGrid, "Time", "Client", "Destination", "Character", "Event", "Expected", "Actual", "Status", "Summary"); page.Controls.Add(summonGrid); tabs.TabPages.Add(page);
        }

        private void BuildMutations()
        {
            var page = Page("AH / MUTATIONS"); mutationGrid.Dock = DockStyle.Fill; AddColumns(mutationGrid, "Time", "Character", "Module", "Operation ID", "Event", "State", "Summary"); page.Controls.Add(mutationGrid); tabs.TabPages.Add(page);
        }

        private void OnAppChanged()
        {
            if (IsDisposed) return;
            try { BeginInvoke(new Action(RefreshAll)); } catch { }
        }

        private void RefreshAll()
        {
            RefreshOverview(); RefreshConversations(); RefreshConversation(); RefreshEvents(); RefreshDebug(); RefreshLogs(); RefreshSummons(); RefreshMutations();
        }

        private void RefreshOverview()
        {
            overview.Rows.Clear();
            foreach (var s in app.State.Sessions()) overview.Rows.Add(s.Character, s.Account + "/" + s.Profile, s.Connected ? "ONLINE" : "OFFLINE", s.World, s.Ah, s.Summon, s.Mail, s.Coordinator, s.CurrentAction, LocalTime(s.LastActivityUtc), s.LastEvent, s.LastError);
            foreach (DataGridViewRow row in overview.Rows) if (Convert.ToString(row.Cells[7].Value) == "Uncertain") row.DefaultCellStyle.BackColor = Color.DarkRed;
        }

        private void RefreshConversations()
        {
            var players = app.EventsSnapshot().Where(IsWhisper).Select(x => x.ConversationPlayer).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x).ToArray();
            var keep = selectedPlayer;
            conversations.BeginUpdate(); conversations.Items.Clear(); conversations.Items.AddRange(players.Cast<object>().ToArray()); conversations.EndUpdate();
            if (!string.IsNullOrEmpty(keep)) { var idx = conversations.FindStringExact(keep); if (idx >= 0) conversations.SelectedIndex = idx; }
            var c = app.State.Counters(); whisperStats.Text = "Total: " + c.Total + "    Understood: " + c.Understood + "    Ignored intentionally: " + c.IgnoredIntentionally + "    UNHANDLED: " + c.Unhandled;
        }

        private void RefreshConversation()
        {
            transcript.Items.Clear(); parserDebug.Clear();
            if (string.IsNullOrWhiteSpace(selectedPlayer)) return;
            var list = app.EventsSnapshot().Where(x => string.Equals(x.ConversationPlayer, selectedPlayer, StringComparison.OrdinalIgnoreCase) || (x.Metadata != null && Convert.ToString(x.Metadata.ContainsKey("player") ? x.Metadata["player"] : "") == selectedPlayer)).OrderBy(x => x.TimestampUtc).ToList();
            foreach (var e in list)
            {
                var prefix = e.Direction == OperatorDirection.Incoming ? "<<" : e.Direction == OperatorDirection.OutgoingManual ? ">> MANUAL" : e.Direction == OperatorDirection.OutgoingAutomation ? ">> AUTO" : "--";
                transcript.Items.Add(LocalTime(e.TimestampUtc) + " " + prefix + " " + e.Message);
            }
            var last = list.LastOrDefault(x => app.State.ParserFor(x.EventId) != null);
            if (last != null) RenderParser(app.State.ParserFor(last.EventId));
        }

        private void RenderParser(ParserDiagnostic p)
        {
            if (p == null) return;
            parserDebug.Text = "sender: " + p.Sender + "\r\nraw: " + p.RawText + "\r\nnormalized: " + p.NormalizedText + "\r\nresult: " + p.Result + "\r\ndestination: " + p.Destination + "\r\nintent: " + p.Intent + "\r\nkeywords: " + p.Keywords + "\r\ncompetition: " + p.Competition + "\r\nsummon_request: " + p.SummonRequest + "\r\nconfidence: " + p.Confidence.ToString("0.###") + "\r\nmatched_rule: " + p.MatchedRule + "\r\nreason: " + p.Reason + "\r\nignore_reason: " + p.IgnoreReason;
        }

        private void RefreshEvents()
        {
            if (pauseView.Checked) return;
            var events = app.EventsSnapshot();
            var modules = events.Select(x => x.Module ?? "").Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x).ToList(); modules.Insert(0, "ALL");
            var selectedModule = module.SelectedItem == null ? "ALL" : Convert.ToString(module.SelectedItem);
            module.BeginUpdate(); module.Items.Clear(); module.Items.AddRange(modules.Cast<object>().ToArray()); module.EndUpdate(); var mi = module.FindStringExact(selectedModule); module.SelectedIndex = mi >= 0 ? mi : 0;
            var min = MinimumSeverity(); var q = events.Where(x => x.Severity >= min);
            if (module.SelectedIndex > 0) q = q.Where(x => string.Equals(x.Module, Convert.ToString(module.SelectedItem), StringComparison.OrdinalIgnoreCase));
            var term = search.Text.Trim(); if (term.Length > 0) q = q.Where(x => (x.Message + " " + x.EventType + " " + x.Character + " " + x.Module).IndexOf(term, StringComparison.OrdinalIgnoreCase) >= 0);
            eventsGrid.Rows.Clear(); foreach (var e in q.TakeLastCompat(5000)) { var i = eventsGrid.Rows.Add(LocalTime(e.TimestampUtc), e.Severity, e.Character, e.Module, e.EventType, e.Message, e.OperationId); if (e.EventType.IndexOf("Uncertain", StringComparison.OrdinalIgnoreCase) >= 0) eventsGrid.Rows[i].DefaultCellStyle.BackColor = Color.DarkRed; }
            if (autoScroll.Checked && eventsGrid.Rows.Count > 0) eventsGrid.FirstDisplayedScrollingRowIndex = eventsGrid.Rows.Count - 1;
        }

        private OperatorSeverity MinimumSeverity()
        {
            var s = Convert.ToString(severity.SelectedItem) ?? "INFO+"; if (s == "TRACE") return OperatorSeverity.Trace; if (s == "DEBUG+") return OperatorSeverity.Debug; if (s == "WARN+") return OperatorSeverity.Warn; if (s == "ERROR") return OperatorSeverity.Error; return OperatorSeverity.Info;
        }

        private void RefreshDebug() { debugText.Text = app.DebugSnapshot(); }
        private void RefreshLogs() { logsText.Text = string.Join("\r\n", app.EventsSnapshot().TakeLastCompat(2000).Select(e => LocalTime(e.TimestampUtc) + " " + e.Severity + " " + e.Character + " " + e.Module + " " + e.EventType + " " + e.Message)); }

        private void RefreshSummons()
        {
            summonGrid.Rows.Clear();
            foreach (var e in app.EventsSnapshot().Where(x => x.Category == "Summon" || x.Category == "Payment" || x.EventType.StartsWith("Summon") || x.EventType.StartsWith("Payment")).TakeLastCompat(5000))
            {
                object d, exp, actual; var destination = e.Metadata.TryGetValue("destination", out d) ? Convert.ToString(d) : ""; var expected = e.Metadata.TryGetValue("expected_copper", out exp) ? Money(exp) : ""; var got = e.Metadata.TryGetValue("copper", out actual) ? Money(actual) : "";
                var status = e.EventType == "PaymentReceived" ? "PAID" : e.EventType == "PaymentMissing" ? "UNPAID" : e.EventType == "SummonCompleted" ? "SUMMONED" : e.EventType == "SummonFailed" ? "FAILED" : e.EventType == "SummonStarted" ? "SUMMONING" : "WAITING";
                summonGrid.Rows.Add(LocalTime(e.TimestampUtc), e.ConversationPlayer, destination, e.Character, e.EventType, expected, got, status, e.Message);
            }
        }

        private void RefreshMutations()
        {
            mutationGrid.Rows.Clear();
            foreach (var e in app.EventsSnapshot().Where(x => x.Category == "Mutation" || x.EventType.IndexOf("Mutation", StringComparison.OrdinalIgnoreCase) >= 0 || x.EventType.StartsWith("Buy") || x.EventType.StartsWith("MailMutation") || x.EventType.StartsWith("Auction")).TakeLastCompat(5000))
            {
                var state = e.EventType.IndexOf("Uncertain", StringComparison.OrdinalIgnoreCase) >= 0 ? "UNCERTAIN" : e.EventType.EndsWith("Confirmed") ? "CONFIRMED" : e.EventType.EndsWith("Started") ? "START" : e.EventType;
                var i = mutationGrid.Rows.Add(LocalTime(e.TimestampUtc), e.Character, e.Module, e.OperationId, e.EventType, state, e.Message); if (state == "UNCERTAIN") mutationGrid.Rows[i].DefaultCellStyle.BackColor = Color.DarkRed;
            }
        }

        private void ReplyKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter && !e.Shift) { e.SuppressKeyPress = true; SendReply(); }
        }

        private void SendReply()
        {
            try
            {
                var target = app.State.Sessions().Where(x => x.Connected).OrderByDescending(x => x.LastActivityUtc).FirstOrDefault();
                app.SendManualWhisper(selectedPlayer, reply.Text.Trim(), target); reply.Clear();
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "Operator command rejected", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        }

        private static bool IsWhisper(OperatorEvent e) { return e.EventType.IndexOf("Whisper", StringComparison.OrdinalIgnoreCase) >= 0 || e.Category == "Whisper"; }
        private static string LocalTime(DateTime utc) { return utc.ToLocalTime().ToString("HH:mm:ss"); }
        private static string Money(object copperObj) { long c; if (!long.TryParse(Convert.ToString(copperObj), out c)) return Convert.ToString(copperObj); return (c / 10000) + "g " + ((c / 100) % 100) + "s " + (c % 100) + "c"; }

        private TabPage Page(string title) { return new TabPage(title) { BackColor = BackColor, ForeColor = ForeColor, Padding = new Padding(4) }; }
        private static Button Button(string text) { return new Button { Text = text, FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(45, 49, 58), ForeColor = Color.White }; }
        private static void StyleList(ListBox box) { box.BackColor = Color.FromArgb(28, 31, 37); box.ForeColor = Color.Gainsboro; box.BorderStyle = BorderStyle.FixedSingle; }
        private static DataGridView Grid()
        {
            var g = new DataGridView { AllowUserToAddRows = false, AllowUserToDeleteRows = false, AllowUserToResizeRows = false, ReadOnly = true, RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, SelectionMode = DataGridViewSelectionMode.FullRowSelect, BackgroundColor = Color.FromArgb(24, 26, 31), ForeColor = Color.Gainsboro, BorderStyle = BorderStyle.None, EnableHeadersVisualStyles = false };
            g.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(40, 43, 51); g.ColumnHeadersDefaultCellStyle.ForeColor = Color.White; g.DefaultCellStyle.BackColor = Color.FromArgb(28, 31, 37); g.DefaultCellStyle.ForeColor = Color.Gainsboro; g.DefaultCellStyle.SelectionBackColor = Color.FromArgb(62, 68, 82); return g;
        }
        private static void AddColumns(DataGridView grid, params string[] names) { foreach (var n in names) grid.Columns.Add(new DataGridViewTextBoxColumn { HeaderText = n, Name = n.Replace(" ", "") }); }
    }
}
