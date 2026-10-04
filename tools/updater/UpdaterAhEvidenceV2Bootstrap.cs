using System;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal sealed partial class MainForm
    {
        // Install once during MainForm construction without adding another
        // lifecycle override. The actual V2 UI attaches on the first WinForms
        // Idle after Application.Run has opened the form.
        private readonly object ahEvidenceV2Bootstrap = AhEvidenceV2Feature.InstallDeferred();
    }

    internal static partial class AhEvidenceV2Feature
    {
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
    }
}
