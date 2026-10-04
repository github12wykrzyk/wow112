using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace WoW112Updater
{
    internal static partial class AhEvidenceV2Feature
    {
        private static string InstalledHead(string root)
        {
            try
            {
                var path = Path.Combine(root, ".wow112_parallel_updater", "installed.json");
                if (!File.Exists(path)) return "";
                var match = Regex.Match(File.ReadAllText(path), "\\\"head_sha\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
                return match.Success ? match.Groups[1].Value : "";
            }
            catch { return ""; }
        }

        private static string BasePath(string root)
        {
            return Path.Combine(root, ".wow112_parallel_updater", BaselineName);
        }

        private static void Refresh(IUpdaterHost host, Button button)
        {
            try
            {
                var root = (host.GameDirectory ?? "").Trim();
                button.Text = Directory.Exists(root) && File.Exists(BasePath(root))
                    ? "AH EVIDENCE V2: CHECK"
                    : "AH EVIDENCE V2";
            }
            catch { button.Text = "AH EVIDENCE V2"; }
        }
    }
}
