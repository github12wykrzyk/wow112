using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace WoW112UpdaterBootstrap
{
    internal static class BootstrapProgram
    {
        private static int Main(string[] args)
        {
            string source = null;
            string target = null;
            string expectedSha = null;
            int waitPid = 0;
            bool restart = false;
            string logPath = null;

            try
            {
                var parsed = ParseArgs(args);
                source = Get(parsed, "--source");
                target = Get(parsed, "--target");
                expectedSha = Get(parsed, "--sha256");
                restart = parsed.ContainsKey("--restart");
                int.TryParse(Get(parsed, "--wait-pid"), out waitPid);

                if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(target) || string.IsNullOrWhiteSpace(expectedSha))
                    throw new InvalidOperationException("Missing required self-update arguments.");

                source = Path.GetFullPath(source);
                target = Path.GetFullPath(target);
                var stageDir = Path.GetDirectoryName(source);
                Directory.CreateDirectory(stageDir);
                logPath = Path.Combine(stageDir, "bootstrap.log");
                Log(logPath, "Bootstrap start. pid=" + waitPid + " target=" + target);

                WaitForProcess(waitPid, 30000);

                if (!File.Exists(source)) throw new FileNotFoundException("Staged updater missing.", source);
                if (!string.Equals(Sha256File(source), expectedSha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Staged updater SHA256 mismatch.");

                var previous = Path.Combine(stageDir, "previous_updater.exe");
                if (File.Exists(target)) File.Copy(target, previous, true);

                var temp = target + ".selfupdate.tmp";
                if (File.Exists(temp)) File.Delete(temp);
                File.Copy(source, temp, true);
                if (!string.Equals(Sha256File(temp), expectedSha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Temporary target SHA256 mismatch.");

                try
                {
                    if (File.Exists(target)) File.Replace(temp, target, null, true);
                    else File.Move(temp, target);
                }
                catch
                {
                    File.Copy(temp, target, true);
                    File.Delete(temp);
                }

                if (!string.Equals(Sha256File(target), expectedSha, StringComparison.OrdinalIgnoreCase))
                {
                    if (File.Exists(previous)) File.Copy(previous, target, true);
                    throw new InvalidOperationException("Installed updater SHA256 mismatch; previous updater restored.");
                }

                Log(logPath, "Self-update installed successfully.");
                if (restart)
                {
                    Process.Start(new ProcessStartInfo(target)
                    {
                        WorkingDirectory = Path.GetDirectoryName(target),
                        UseShellExecute = true
                    });
                    Log(logPath, "Updater restarted.");
                }
                return 0;
            }
            catch (Exception ex)
            {
                try
                {
                    if (logPath == null && !string.IsNullOrWhiteSpace(source))
                        logPath = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(source)), "bootstrap_error.log");
                    if (logPath != null) Log(logPath, "ERROR: " + ex);
                }
                catch { }
                return 1;
            }
        }

        private static Dictionary<string, string> ParseArgs(string[] args)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < args.Length; i++)
            {
                var arg = args[i];
                if (!arg.StartsWith("--", StringComparison.Ordinal)) continue;
                if (string.Equals(arg, "--restart", StringComparison.OrdinalIgnoreCase))
                {
                    result[arg] = "true";
                    continue;
                }
                if (i + 1 >= args.Length) throw new InvalidOperationException("Missing value for " + arg);
                result[arg] = args[++i];
            }
            return result;
        }

        private static string Get(Dictionary<string, string> dict, string key)
        {
            string value;
            return dict.TryGetValue(key, out value) ? value : string.Empty;
        }

        private static void WaitForProcess(int pid, int timeoutMs)
        {
            if (pid <= 0) return;
            try
            {
                using (var process = Process.GetProcessById(pid))
                {
                    if (!process.WaitForExit(timeoutMs))
                        throw new TimeoutException("Updater process did not exit within timeout.");
                }
            }
            catch (ArgumentException)
            {
            }
        }

        private static string Sha256File(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                var hash = sha.ComputeHash(stream);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (var b in hash) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        private static void Log(string path, string message)
        {
            File.AppendAllText(path, "[" + DateTime.UtcNow.ToString("o") + "] " + message + Environment.NewLine, Encoding.UTF8);
        }
    }
}
