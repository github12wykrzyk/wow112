using System;
using System.Linq;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        private readonly Timer terminalPortalLayoutTimer = CreateTerminalPortalLayoutTimer();

        private static Timer CreateTerminalPortalLayoutTimer()
        {
            var timer = new Timer { Interval = 180 };
            timer.Tick += delegate
            {
                var form = System.Windows.Forms.Application.OpenForms.OfType<MainForm>().FirstOrDefault();
                if (form == null || form.IsDisposed || form.Disposing) return;
                if (!form.terminalPortalAttached) return;
                var multibox = form.featureControls.ContainsKey("multibox") ? form.featureControls["multibox"] as Button : null;
                var tools = multibox == null ? null : multibox.Parent as TableLayoutPanel;
                if (tools == null) return;
                timer.Stop();
                tools.SuspendLayout();
                tools.ColumnCount = 8;
                tools.ColumnStyles.Clear();
                for (var i = 0; i < 7; i++) tools.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 14.285714F));
                tools.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 64F));
                form.terminalPortalButton.Text = "TERM";
                tools.ResumeLayout(true);
            };
            timer.Start();
            return timer;
        }
    }
}
