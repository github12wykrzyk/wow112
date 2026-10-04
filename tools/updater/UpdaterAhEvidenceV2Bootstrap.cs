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
        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            AhEvidenceV2Feature.Attach(this);
        }
    }

    internal static partial class AhEvidenceV2Feature
    {
        private const string BaselineName = "ah_evidence_v2_baseline.json";
        private const string LegacyBaselineName = "ah_evidence_baseline.json";
        private const string ResultName = "ah_evidence_v2_result.txt";
        private const string Marker = "AH_EVIDENCE_V2";

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

            var button = new Button {
                Text = "AH EVIDENCE V2", Width = 150, Height = 30,
                Anchor = AnchorStyles.Right | AnchorStyles.Bottom,
                FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = false,
                BackColor = Color.FromArgb(50, 58, 75), ForeColor = Color.White, Tag = Marker
            };
            button.FlatAppearance.BorderColor = Color.FromArgb(223, 182, 115);
            button.Click += delegate { HandleClick(form, button); };
            form.Controls.Add(button);
            Place(form, button);
            button.BringToFront();
            Refresh(form, button);
            form.Resize += delegate { if (!button.IsDisposed && button.Parent != null) { Place(form, button); button.BringToFront(); } };
        }

        private static IEnumerable<Button> FindButtons(Control root)
        {
            var rows = new List<Button>();
            foreach (Control c in root.Controls)
            {
                var b = c as Button;
                if (b != null && (b.Text ?? "").StartsWith("AH EVIDENCE", StringComparison.OrdinalIgnoreCase)) rows.Add(b);
                if (c.HasChildren) rows.AddRange(FindButtons(c));
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
