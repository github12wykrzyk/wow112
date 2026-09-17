using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        protected override void OnShown(EventArgs e)
        {
            ApplyLauncherPolish();
            base.OnShown(e);
        }

        private void ApplyLauncherPolish()
        {
            SuspendLayout();
            try
            {
                FormBorderStyle = FormBorderStyle.FixedSingle;
                MaximizeBox = false;
                MinimizeBox = true;
                SizeGripStyle = SizeGripStyle.Hide;
                ClientSize = new Size(1100, 720);
                StartPosition = FormStartPosition.CenterScreen;

                updatePlayButton.UseMnemonic = false;
                updatePlayButton.Text = "UPDATE & PLAY";

                var frame = Controls.OfType<TableLayoutPanel>()
                    .FirstOrDefault(x => x.Dock == DockStyle.Fill && x.ColumnCount == 2 && x.RowCount == 1);
                if (frame == null) return;

                frame.SuspendLayout();
                try
                {
                    frame.ColumnStyles[0].SizeType = SizeType.Absolute;
                    frame.ColumnStyles[0].Width = 610F;
                    frame.ColumnStyles[1].SizeType = SizeType.Percent;
                    frame.ColumnStyles[1].Width = 100F;

                    var shell = frame.GetControlFromPosition(0, 0) as Panel;
                    if (shell != null)
                        shell.Padding = new Padding(24, 20, 20, 24);

                    if (stableTokenBadge != null)
                    {
                        var nav = stableTokenBadge.Parent;
                        var body = nav != null ? nav.Parent as TableLayoutPanel : null;
                        if (body != null && body.ColumnStyles.Count >= 2)
                        {
                            body.ColumnStyles[0].SizeType = SizeType.Absolute;
                            body.ColumnStyles[0].Width = 132F;
                        }
                    }

                    ReplaceHeroWithNativePicture(frame);
                }
                finally
                {
                    frame.ResumeLayout(true);
                }

                var title = Descendants(this).OfType<Label>()
                    .FirstOrDefault(x => string.Equals(x.Text, "WoW112 Updater", StringComparison.Ordinal));
                if (title != null)
                {
                    title.Font = new Font("Georgia", 24F, FontStyle.Bold);
                    title.Location = new Point(8, 4);
                }

                var hint = Descendants(this).OfType<Label>()
                    .FirstOrDefault(x => (x.Text ?? string.Empty).StartsWith("TEST follows work", StringComparison.Ordinal));
                if (hint != null)
                    hint.Text = "TEST = work   •   STABLE = main   •   Only verified workflow builds are installed.";
            }
            finally
            {
                ResumeLayout(true);
            }
        }

        private static IEnumerable<Control> Descendants(Control root)
        {
            foreach (Control child in root.Controls)
            {
                yield return child;
                foreach (var nested in Descendants(child))
                    yield return nested;
            }
        }

        private void ReplaceHeroWithNativePicture(TableLayoutPanel frame)
        {
            var oldHero = frame.GetControlFromPosition(1, 0);
            var source = LoadUpdaterArtwork();
            if (source == null) return;

            Bitmap portrait = null;
            try
            {
                var cropX = Math.Max(0, source.Width / 2);
                var cropWidth = Math.Max(1, source.Width - cropX);
                portrait = new Bitmap(cropWidth, source.Height);
                using (var g = Graphics.FromImage(portrait))
                {
                    g.Clear(CBack);
                    g.DrawImage(
                        source,
                        new Rectangle(0, 0, portrait.Width, portrait.Height),
                        new Rectangle(cropX, 0, cropWidth, source.Height),
                        GraphicsUnit.Pixel);
                }
            }
            finally
            {
                source.Dispose();
            }

            var picture = new PictureBox
            {
                Dock = DockStyle.Fill,
                Margin = Padding.Empty,
                BackColor = CBack,
                Image = portrait,
                SizeMode = PictureBoxSizeMode.StretchImage,
                TabStop = false
            };
            picture.Disposed += delegate
            {
                if (picture.Image != null)
                {
                    var image = picture.Image;
                    picture.Image = null;
                    image.Dispose();
                }
            };

            var heroHost = new Panel
            {
                Dock = DockStyle.Fill,
                Margin = Padding.Empty,
                Padding = new Padding(1, 0, 0, 0),
                BackColor = CBorder
            };
            heroHost.Controls.Add(picture);

            if (oldHero != null)
            {
                frame.Controls.Remove(oldHero);
                oldHero.Dispose();
            }
            frame.Controls.Add(heroHost, 1, 0);
        }
    }
}
