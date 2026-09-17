using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

namespace WoW112Updater
{
    // Compatibility guard for the V1 updater. The main form historically used
    // Process.GetProcesses() as a broad "anything from the game directory"
    // lock. That makes the updater block itself when WoW112Updater.exe is kept
    // in the WoW directory. This local Process type intentionally shadows
    // System.Diagnostics.Process for the two call sites in WoW112Updater.cs.
    // It exposes only real WoW executables (WoW.exe or the project's WoW_*.exe)
    // to the running-game check and prevents LaunchGame from recursively
    // starting the updater if the fallback file scan happens to select it.
    internal sealed class Process : IDisposable
    {
        private readonly System.Diagnostics.Process inner;

        private Process(System.Diagnostics.Process innerProcess)
        {
            inner = innerProcess;
        }

        public ProcessModule MainModule
        {
            get { return inner.MainModule; }
        }

        public static Process[] GetProcesses()
        {
            var result = new List<Process>();
            int selfId = -1;
            using (var self = System.Diagnostics.Process.GetCurrentProcess())
            {
                selfId = self.Id;
            }

            foreach (var candidate in System.Diagnostics.Process.GetProcesses())
            {
                if (candidate.Id == selfId)
                {
                    candidate.Dispose();
                    continue;
                }

                try
                {
                    var module = candidate.MainModule;
                    var fileName = module == null ? null : module.FileName;
                    if (IsGameExecutableName(Path.GetFileName(fileName)))
                        result.Add(new Process(candidate));
                    else
                        candidate.Dispose();
                }
                catch
                {
                    candidate.Dispose();
                }
            }

            return result.ToArray();
        }

        public static System.Diagnostics.Process Start(ProcessStartInfo startInfo)
        {
            if (startInfo == null) throw new ArgumentNullException("startInfo");

            var requestedName = Path.GetFileName(startInfo.FileName);
            if (!IsGameExecutableName(requestedName))
            {
                var root = startInfo.WorkingDirectory;
                var gameExe = FindGameExecutable(root);
                if (gameExe == null)
                    throw new InvalidOperationException("Nie znalazłem WoW.exe ani WoW_*.exe w wybranym katalogu.");
                startInfo.FileName = gameExe;
            }

            return System.Diagnostics.Process.Start(startInfo);
        }

        public void Dispose()
        {
            inner.Dispose();
        }

        private static bool IsGameExecutableName(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return false;
            if (string.Equals(name, "WoW.exe", StringComparison.OrdinalIgnoreCase)) return true;
            return name.StartsWith("WoW_", StringComparison.OrdinalIgnoreCase)
                && name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
        }

        private static string FindGameExecutable(string root)
        {
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)) return null;

            var standard = Path.Combine(root, "WoW.exe");
            if (File.Exists(standard)) return standard;

            var candidates = Directory.GetFiles(root, "WoW_*.exe");
            Array.Sort(candidates, StringComparer.OrdinalIgnoreCase);
            return candidates.Length == 0 ? null : candidates[0];
        }
    }
}
