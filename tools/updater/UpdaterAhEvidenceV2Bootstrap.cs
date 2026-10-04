using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        // Install once during MainForm construction without defining another
        // OnShown override. V2 attaches on the first WinForms Idle.
        private readonly object ahEvidenceV2Bootstrap = AhEvidenceV2Feature.InstallDeferred();
    }

    internal static partial class AhEvidenceV2Feature
    {
        private const string BaselineName = "ah_evidence_v2_baseline.json";
        private const string LegacyBaselineName = "ah_evidence_baseline.json";
        private const string ResultName = "ah_evidence_v2_result.txt";
        private const string Marker = "AH_EVIDENCE_V2";
        private static bool deferredInstalled;

        internal static object InstallDeferred()
        {
            if (deferredInstalled) return null;
            deferredInstalled = true;
            EventHandler handler = null;
            handler = delegate
            {
                foreach (Form open in System.Windows.Forms.Application.OpenForms)
                {
                    var main = open as MainForm;
                    if (main == null || main.IsDisposed) continue;
                    System.Windows.Forms.Application.Idle -= handler;
                    Attach(main);
                    break;
                }
            };
            System.Windows.Forms.Application.Idle += handler;
            return new object();
        }

        public static void Attach(MainForm form)
        {
            if (form == null || form.IsDisposed) return;
            foreach (var old in FindButtons(form).ToArray())
            {
                if (string.Equals(Convert.ToString(old.Tag), Marker, StringComparison.Ordinal)) continue;
                if (old.Parent != null) old.Parent.Controls.Remove(old);
                old.Dispose();
            }
            try
            {
                var root = (form.GameDirectory ?? "").Trim();
                var oldBase = Path.Combine(root, ".wow112_parallel_updater", LegacyBaselineName);
                if (Directory.Exists(root) && File.Exists(oldBase)) File.Delete(oldBase);
            }
            catch { }

            var button = new Button
            {
                Text = "AH EVIDENCE V2",
                Width = 150,
                Height = 30,
                Anchor = AnchorStyles.Right | AnchorStyles.Bottom,
                FlatStyle = FlatStyle.Flat,
                UseVisualStyleBackColor = false,
                BackColor = Color.FromArgb(50, 58, 75),
                ForeColor = Color.White,
                Tag = Marker
            };
            button.FlatAppearance.BorderColor = Color.FromArgb(223, 182, 115);
            button.Click += delegate { HandleClick(form, button); };
            form.Controls.Add(button);
            Place(form, button);
            button.BringToFront();
            Refresh(form, button);
            form.Resize += delegate
            {
                if (button.IsDisposed || button.Parent == null) return;
                Place(form, button);
                button.BringToFront();
            };
        }

        private static IEnumerable<Button> FindButtons(Control root)
        {
            var rows = new List<Button>();
            foreach (Control control in root.Controls)
            {
                var button = control as Button;
                if (button != null && (button.Text ?? "").StartsWith("AH EVIDENCE", StringComparison.OrdinalIgnoreCase))
                    rows.Add(button);
                if (control.HasChildren) rows.AddRange(FindButtons(control));
            }
            return rows;
        }

        private static void Place(Form form, Button button)
        {
            button.Left = Math.Max(8, form.ClientSize.Width - button.Width - 18);
            button.Top = Math.Max(8, form.ClientSize.Height - button.Height - 18);
        }
    }
}
