using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

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

        private const uint CreateSuspended = 0x00000004u;
        private const uint CreateUnicodeEnvironment = 0x00000400u;
        private const uint ResumeFailed = 0xFFFFFFFFu;
        private static readonly IntPtr ConfigNameAddress = new IntPtr(0x0082E580);
        private static readonly byte[] ExpectedConfigName = Encoding.ASCII.GetBytes("Config.wtf\0");

        [StructLayout(LayoutKind.Sequential)]
        private struct STARTUPINFO
        {
            public uint cb;
            public IntPtr lpReserved;
            public IntPtr lpDesktop;
            public IntPtr lpTitle;
            public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public ushort wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(
            string lpApplicationName, StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles,
            uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadProcessMemory(
            IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out IntPtr lpNumberOfBytesRead);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteProcessMemory(
            IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out IntPtr lpNumberOfBytesWritten);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private static void ResolveGameExecutable(ProcessStartInfo startInfo)
        {
            if (startInfo == null) throw new ArgumentNullException("startInfo");
            var requestedName = Path.GetFileName(startInfo.FileName);
            if (IsGameExecutableName(requestedName)) return;
            var gameExe = FindGameExecutable(startInfo.WorkingDirectory);
            if (gameExe == null)
                throw new InvalidOperationException("Nie znalazłem WoW.exe ani WoW_*.exe w wybranym katalogu.");
            startInfo.FileName = gameExe;
        }

        public static System.Diagnostics.Process Start(ProcessStartInfo startInfo)
        {
            ResolveGameExecutable(startInfo);
            return System.Diagnostics.Process.Start(startInfo);
        }

        public static System.Diagnostics.Process Start(ProcessStartInfo startInfo, string configName)
        {
            ResolveGameExecutable(startInfo);
            if (string.IsNullOrWhiteSpace(configName)) return System.Diagnostics.Process.Start(startInfo);
            if (configName.Length > 10 || !configName.EndsWith(".wtf", StringComparison.OrdinalIgnoreCase)
                || Path.GetFileName(configName) != configName)
                throw new InvalidDataException("Nieprawidłowa nazwa LOW Config.wtf: " + configName);

            startInfo.UseShellExecute = false;
            var environment = BuildEnvironmentBlock(startInfo);
            var si = new STARTUPINFO { cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO)) };
            var pi = new PROCESS_INFORMATION();
            var commandLine = new StringBuilder(""" + startInfo.FileName + """ +
                (string.IsNullOrWhiteSpace(startInfo.Arguments) ? string.Empty : " " + startInfo.Arguments));
            var created = false;
            var resumed = false;
            System.Diagnostics.Process managed = null;
            try
            {
                created = CreateProcessW(
                    startInfo.FileName, commandLine, IntPtr.Zero, IntPtr.Zero, false,
                    CreateSuspended | CreateUnicodeEnvironment, environment,
                    startInfo.WorkingDirectory, ref si, out pi);
                if (!created)
                    throw new InvalidOperationException("CreateProcessW(LOW) failed, Win32=" + Marshal.GetLastWin32Error());

                var actual = new byte[ExpectedConfigName.Length];
                IntPtr read;
                if (!ReadProcessMemory(pi.hProcess, ConfigNameAddress, actual, actual.Length, out read)
                    || read.ToInt64() != actual.Length || !BytesEqual(actual, ExpectedConfigName))
                    throw new InvalidOperationException(
                        "LOW fail-closed: build 5875 nie ma oczekiwanego Config.wtf pod 0x82E580.");

                var replacement = new byte[ExpectedConfigName.Length];
                var encoded = Encoding.ASCII.GetBytes(configName);
                Buffer.BlockCopy(encoded, 0, replacement, 0, encoded.Length);
                IntPtr written;
                if (!WriteProcessMemory(pi.hProcess, ConfigNameAddress, replacement, replacement.Length, out written)
                    || written.ToInt64() != replacement.Length)
                    throw new InvalidOperationException("LOW: nie udało się przypisać osobnego pliku WTF, Win32=" + Marshal.GetLastWin32Error());

                managed = System.Diagnostics.Process.GetProcessById((int)pi.dwProcessId);
                if (ResumeThread(pi.hThread) == ResumeFailed)
                    throw new InvalidOperationException("LOW: ResumeThread failed, Win32=" + Marshal.GetLastWin32Error());
                resumed = true;
                return managed;
            }
            catch
            {
                if (managed != null && !resumed) managed.Dispose();
                if (created && !resumed && pi.hProcess != IntPtr.Zero) TerminateProcess(pi.hProcess, 1u);
                throw;
            }
            finally
            {
                if (created)
                {
                    if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
                    if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
                }
                if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            }
        }

        private static IntPtr BuildEnvironmentBlock(ProcessStartInfo startInfo)
        {
            var rows = new List<string>();
            foreach (string key in startInfo.EnvironmentVariables.Keys)
            {
                if (string.IsNullOrEmpty(key) || key.IndexOf('\0') >= 0) continue;
                var value = startInfo.EnvironmentVariables[key] ?? string.Empty;
                if (value.IndexOf('\0') >= 0) throw new InvalidDataException("NUL w zmiennej środowiskowej " + key);
                rows.Add(key + "=" + value);
            }
            rows.Sort(StringComparer.OrdinalIgnoreCase);
            return Marshal.StringToHGlobalUni(string.Join("\0", rows.ToArray()) + "\0\0");
        }

        private static bool BytesEqual(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            for (var i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
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
