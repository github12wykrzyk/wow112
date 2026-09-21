using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace WoW112Updater
{
    internal static class UpdaterBuildInfo
    {
        public const string Version = "2.5";
    }

    internal static class UpdaterSafety
    {
        public static Dictionary<string, object> RequireLatestSuccessfulRun(object[] runs, string workflowName, string branch)
        {
            Dictionary<string, object> chosen = null;
            if (runs != null)
            {
                foreach (var item in runs)
                {
                    var row = item as Dictionary<string, object>;
                    if (row == null) continue;
                    if (string.Equals(GetString(row, "name"), workflowName, StringComparison.Ordinal))
                    {
                        chosen = row;
                        break;
                    }
                }
            }

            if (chosen == null)
                throw new InvalidOperationException("Nie znaleziono workflow '" + workflowName + "' na branchu " + branch + ".");

            var status = GetString(chosen, "status");
            var conclusion = GetString(chosen, "conclusion");
            if (!string.Equals(status, "completed", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Najnowszy run workflow '" + workflowName + "' na branchu " + branch +
                    " nie jest jeszcze zakończony (status: " + EmptyAsUnknown(status) + "). " +
                    "Updater nie użyje automatycznie starszego artefaktu.");
            }
            if (!string.Equals(conclusion, "success", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Najnowszy run workflow '" + workflowName + "' na branchu " + branch +
                    " nie zakończył się sukcesem (conclusion: " + EmptyAsUnknown(conclusion) + "). " +
                    "Updater nie użyje automatycznie starszego artefaktu.");
            }

            return chosen;
        }

        public static bool IsSha256Hex(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length != 64) return false;
            for (var i = 0; i < value.Length; i++)
            {
                var c = value[i];
                var hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
                if (!hex) return false;
            }
            return true;
        }

        public static void WriteUtf8Atomic(string path, string text, string tempSuffix, string previousSuffix)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("Brak ścieżki pliku.", "path");
            if (tempSuffix == null) tempSuffix = ".tmp";
            if (previousSuffix == null) previousSuffix = ".previous";

            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);

            var temp = path + tempSuffix;
            var previous = path + previousSuffix;
            if (File.Exists(temp)) File.Delete(temp);

            File.WriteAllText(temp, text ?? string.Empty, Encoding.UTF8);
            var readBack = File.ReadAllText(temp, Encoding.UTF8);
            if (!string.Equals(readBack, text ?? string.Empty, StringComparison.Ordinal))
                throw new IOException("Weryfikacja pliku tymczasowego po zapisie nie powiodła się: " + Path.GetFileName(path));

            if (File.Exists(path)) File.Copy(path, previous, true);
            ReplaceFile(temp, path, ".wow112atomicreplace");
        }

        public static void ReplaceFile(string temp, string destination, string backupSuffix)
        {
            if (!File.Exists(temp)) throw new FileNotFoundException("Brak pliku tymczasowego do podmiany.", temp);
            if (backupSuffix == null) backupSuffix = ".wow112replace";

            if (!File.Exists(destination))
            {
                File.Move(temp, destination);
                return;
            }

            var backup = destination + backupSuffix;
            if (File.Exists(backup)) File.Delete(backup);
            try
            {
                try
                {
                    File.Replace(temp, destination, backup, true);
                }
                catch
                {
                    if (!File.Exists(destination) && File.Exists(backup))
                        File.Copy(backup, destination, true);
                    File.Copy(temp, destination, true);
                    File.Delete(temp);
                }
            }
            finally
            {
                if (File.Exists(backup)) File.Delete(backup);
            }
        }

        private static string GetString(Dictionary<string, object> dict, string key)
        {
            object value;
            return dict != null && dict.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : string.Empty;
        }

        private static string EmptyAsUnknown(string value)
        {
            return string.IsNullOrWhiteSpace(value) ? "unknown" : value;
        }
    }
}

