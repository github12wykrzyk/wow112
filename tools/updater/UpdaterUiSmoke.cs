using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        // Offline Windows rendering probe: no credentials, network or game writes.
        internal void CaptureUiSmoke(string folder)
        {
            Directory.CreateDirectory(folder);
            // Hosted runners may have a 1024x768 desktop. Allow off-screen bitmap
            // capture at the explicitly requested test viewport instead of OS track-size clamping.
            MaximumSize = new Size(4096, 4096);
            Show();
            System.Windows.Forms.Application.DoEvents();
            ClientSize = new Size(1040, 680);
            AssertExeInspection(folder);
            string[] cases = { "first-run", "long-path", "available", "current", "build-running", "network-error", "downloading", "installing", "game-running" };
            foreach (var state in cases)
            {
                SetBusy(false, "Gotowy");
                if (state != "first-run") gameDir.Text = @"C:\Gry\World of Warcraft 1.12.1\Bardzo długi katalog testowy\Profil gracza";
                if (state == "available" || state == "current")
                {
                    localInfo.Text = "TEST • run 123456789 • abcdef12 • 2026-09-18 08:30";
                    remoteInfo.Text = "TEST • abcdef12 • run 123456789\nBuild zakończony pomyślnie";
                    status.Text = state == "current" ? "Masz najnowszą wersję TEST." : "Dostępna aktualizacja TEST: abcdef12";
                }
                if (state == "build-running") { remoteInfo.Text = "Najnowszy build jest w toku. Spróbuj ponownie później."; status.Text = "Oczekiwanie na zakończenie builda"; }
                if (state == "network-error") { SetConnectionState("GitHub: błąd połączenia"); status.Text = "Błąd sprawdzania aktualizacji — szczegóły w logu"; }
                if (state == "downloading" || state == "installing")
                {
                    SetBusy(true, state == "downloading" ? "Pobieranie najnowszej paczki…" : "Instalowanie zweryfikowanych plików…");
                    if (featureControls.Values.Any(x => x.Enabled) || gameDir.Enabled || channel.Enabled) throw new Exception("Busy controls are enabled");
                }
                if (state == "game-running") status.Text = "Gra działa. Zamknij WoW przed aktualizacją.";
                log.Text = "[08:30:00] Updater gotowy.\n[08:30:01] Przykładowy wpis diagnostyczny — tryb testu GUI.";
                System.Windows.Forms.Application.DoEvents();
                SaveUiBitmap(Path.Combine(folder, state + ".png"));
                AssertDashboardLayout();
            }
            SetBusy(false, "Gotowy");
            if (!featureControls["verify"].Enabled || !featureControls["report"].Enabled) throw new Exception("Busy state did not restore actions");
            foreach (var dimensions in new[] { new Size(960, 620), new Size(1040, 680) })
            {
                MinimumSize = Size.Empty;
                ClientSize = dimensions;
                System.Windows.Forms.Application.DoEvents(); AssertDashboardLayout();
                SaveUiBitmap(Path.Combine(folder, "layout-" + dimensions.Width + "x" + dimensions.Height + ".png"));
            }
            // The hosted desktop is 1024x768 and clamps top-level HWND sizes.
            // Render the real dashboard on an off-screen WinForms surface for larger
            // logical viewports; assertions still check every button against its parents.
            var dashboard = Controls[0];
            Controls.Remove(dashboard);
            using (var viewport = new Panel { Size = new Size(1040, 680) })
            {
                viewport.Controls.Add(dashboard);
                foreach (float factor in new[] { 1.25F, 1.2F })
                {
                    float total = factor == 1.25F ? 1.25F : 1.5F;
                    var fonts = WalkControls(dashboard).Concat(new[] { dashboard }).ToDictionary(x => x, x => x.Font);
                    dashboard.Scale(new SizeF(factor, factor));
                    foreach (var pair in fonts) pair.Key.Font = new Font(pair.Value.FontFamily, pair.Value.Size * factor, pair.Value.Style);
                    viewport.Size = new Size((int)(1040 * total), (int)(680 * total));
                    viewport.CreateControl(); viewport.PerformLayout();
                    foreach (var control in WalkControls(viewport)) control.PerformLayout();
                    using (var bitmap = new Bitmap(viewport.Width, viewport.Height))
                    {
                        viewport.DrawToBitmap(bitmap, new Rectangle(Point.Empty, viewport.Size));
                        bitmap.Save(Path.Combine(folder, "scale-" + (int)(total * 100) + "-simulation.png"), ImageFormat.Png);
                    }
                    AssertDashboardLayout(viewport);
                }
                viewport.Controls.Remove(dashboard);
            }
            Controls.Add(dashboard);
            File.WriteAllText(Path.Combine(folder, "result.txt"), "PASS: Windows WinForms rendering; EXE SHA256 missing/current/changed; states, compact layout, busy-state restoration, 125/150% layout simulations. Native monitor DPI switching requires interactive validation.");
            Close();
        }
        private void AssertExeInspection(string folder)
        {
            // No GitHub token or actual game required: exercise the same EXE SHA256
            // comparison that "Sprawdź" performs on a verified candidate ZIP.
            var root = Path.Combine(folder, "exe-inspection-fixture");
            Directory.CreateDirectory(root);
            var exeName = "WoW_5875_SMOKE.exe";
            var exeBytes = new byte[] { 0x4d, 0x5a, 0x01, 0x02 };
            byte[] archive;
            using (var ms = new MemoryStream())
            {
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
                {
                    using (var output = zip.CreateEntry(exeName).Open()) output.Write(exeBytes, 0, exeBytes.Length);
                    using (var output = zip.CreateEntry("Smoke.dll").Open()) output.WriteByte(1);
                }
                archive = ms.ToArray();
            }
            InspectDllPackage(archive, root);
            if (lastExeInspection == null || lastExeInspection.State != "BRAK LOKALNIE" || !lastExeInspection.HasChange)
                throw new Exception("EXE smoke: missing local EXE was not detected");
            var local = Path.Combine(root, exeName);
            File.WriteAllBytes(local, exeBytes);
            InspectDllPackage(archive, root);
            if (lastExeInspection.State != "AKTUALNY" || lastExeInspection.HasChange)
                throw new Exception("EXE smoke: current local EXE was not detected");
            File.WriteAllBytes(local, new byte[] { 0x4d, 0x5a, 0x02, 0x03 });
            InspectDllPackage(archive, root);
            if (lastExeInspection.State != "AKTUALIZACJA" || !lastExeInspection.HasChange)
                throw new Exception("EXE smoke: changed local EXE was not detected");
            ResetDllUpdateInspection();
        }

        private void AssertDashboardLayout(Control viewport = null)
        {
            viewport = viewport ?? this;
            foreach (var button in WalkControls(viewport).OfType<Button>())
            {
                if (!button.Visible) continue;
                var bounds = viewport.RectangleToClient(button.RectangleToScreen(button.ClientRectangle));
                if (!viewport.ClientRectangle.Contains(bounds) || button.Height < 22) throw new Exception("Clipped button: " + button.Text + " " + bounds + " client " + ClientSize);
                var size = TextRenderer.MeasureText(button.Text, button.Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                if (size.Width + 12 > button.Width || size.Height + 4 > button.Height) throw new Exception("Button text does not fit: " + button.Text + " " + button.Size + " text " + size);
                for (Control parent = button.Parent; parent != null && parent != viewport; parent = parent.Parent)
                {
                    var relative = parent.RectangleToClient(button.RectangleToScreen(button.ClientRectangle));
                    if (!parent.ClientRectangle.Contains(relative)) throw new Exception("Button outside parent: " + button.Text + " relative " + relative + " parent " + parent.ClientSize + " client " + ClientSize);
                }
            }
            if (log.Height < 40) throw new Exception("Log too small");
        }
        private static System.Collections.Generic.IEnumerable<Control> WalkControls(Control parent)
        {
            foreach (Control child in parent.Controls)
            {
                yield return child;
                foreach (var descendant in WalkControls(child)) yield return descendant;
            }
        }
        private void SaveUiBitmap(string path)
        {
            using (var bitmap = new Bitmap(Width, Height)) { DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size)); bitmap.Save(path, ImageFormat.Png); }
        }
    }
}
