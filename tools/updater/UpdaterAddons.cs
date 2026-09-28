using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace WoW112Updater
{
    internal sealed class UpdaterAddonAsset
    {
        public readonly string Name;
        public readonly byte[] Bytes;
        public UpdaterAddonAsset(string name, byte[] bytes) { Name = name; Bytes = bytes; }
    }

    // Addons are a separately SHA-verified archive inside the SAME successful
    // work candidate artifact; the strict root-only EXE/DLL ZIP is unchanged.
    internal static class UpdaterAddons
    {
        private const string ZipName = "WoW112_LAZYROGUE_HYBRID_ADDONS.zip";
        private const string MetadataName = "addon_metadata.json";
        private const int MaxAddonBytes = 2 * 1024 * 1024;
        private const int MaxAddonZipBytes = 8 * 1024 * 1024;

        public static List<UpdaterAddonAsset> ReadFromArtifact(byte[] outerBytes, bool requireAddon, string expectedHeadSha)
        {
            using (var stream = new MemoryStream(outerBytes, false))
            using (var outer = new ZipArchive(stream, ZipArchiveMode.Read, false))
            {
                var zipEntries = outer.Entries.Where(e => string.Equals(e.FullName, ZipName, StringComparison.OrdinalIgnoreCase)).ToArray();
                var metaEntries = outer.Entries.Where(e => string.Equals(e.FullName, MetadataName, StringComparison.OrdinalIgnoreCase)).ToArray();
                if (zipEntries.Length == 0 && metaEntries.Length == 0 && !requireAddon)
                    return new List<UpdaterAddonAsset>();
                if (zipEntries.Length != 1 || metaEntries.Length != 1)
                    throw new InvalidOperationException("Artifact nie zawiera kompletnej, jednoznacznej paczki LS + LazyRogue + LazyWarlock + SummonScout i addon_metadata.json.");

                var serializer = new JavaScriptSerializer();
                var metaBytes = ReadBounded(metaEntries[0], 4096);
                var meta = serializer.DeserializeObject(Encoding.UTF8.GetString(metaBytes)) as Dictionary<string, object>;
                if (meta == null) throw new InvalidOperationException("Nieprawidłowy addon_metadata.json.");
                object value;
                var sha = meta.TryGetValue("addon_sha256", out value) ? Convert.ToString(value) : string.Empty;
                var gitSha = meta.TryGetValue("git_sha", out value) ? Convert.ToString(value) : string.Empty;
                var name = meta.TryGetValue("zip_name", out value) ? Convert.ToString(value) : string.Empty;
                if (!UpdaterSafety.IsSha256Hex(sha) ||
                    !string.Equals(name, ZipName, StringComparison.Ordinal) ||
                    !string.Equals(gitSha, expectedHeadSha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Niezgodny SHA/commit/format manifestu dodatków.");

                var addonZip = ReadBounded(zipEntries[0], MaxAddonZipBytes);
                if (!string.Equals(Sha256(addonZip), sha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("SHA256 ZIP-a dodatków nie zgadza się z addon_metadata.json.");

                var files = new List<UpdaterAddonAsset>();
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                using (var inner = new MemoryStream(addonZip, false))
                using (var addons = new ZipArchive(inner, ZipArchiveMode.Read, false))
                {
                    foreach (var entry in addons.Entries)
                    {
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            // Only canonical folder entries, never a payload in a non-whitelisted directory.
                            if (!entry.FullName.EndsWith("/", StringComparison.Ordinal) ||
                                !IsWhitelistedDirectory(entry.FullName.TrimEnd('/')))
                                throw new InvalidOperationException("Niebezpieczny katalog w paczce dodatków: " + entry.FullName);
                            continue;
                        }
                        ValidateAddonName(entry.FullName);
                        if (!names.Add(entry.FullName))
                            throw new InvalidOperationException("Duplikat pliku dodatku: " + entry.FullName);
                        files.Add(new UpdaterAddonAsset(entry.FullName, ReadBounded(entry, MaxAddonBytes)));
                        if (files.Count > 120)
                            throw new InvalidOperationException("Nadmierna liczba plików w paczce dodatków.");
                    }
                }
                var count = meta.TryGetValue("file_count", out value) ? Convert.ToInt32(value) : 0;
                if (count != files.Count || files.Count < 22 ||
                    !names.Contains("Interface/AddOns/LazyScript/LazyScript.toc") ||
                    !names.Contains("Interface/AddOns/LazyRogue/LazyRogue.toc") ||
                    !names.Contains("Interface/AddOns/LazyWarlock/LazyWarlock.toc") ||
                    !names.Contains("Interface/AddOns/SummonScout/SummonScout.toc"))
                    throw new InvalidOperationException("Niekompletna lub niespójna paczka LS/LazyRogue/LazyWarlock/SummonScout.");
                return files;
            }
        }

        public static bool IsAddonPath(string name)
        {
            return name != null && name.StartsWith("Interface/", StringComparison.OrdinalIgnoreCase);
        }

        public static string SafeAddonDestination(string root, string name)
        {
            ValidateAddonName(name);
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var path = fullRoot;
            foreach (var part in name.Split('/'))
            {
                path = Path.Combine(path, part);
                if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidOperationException("Katalog dodatku jest łączem/reparse point: " + name);
            }
            var dest = Path.GetFullPath(path);
            if (!dest.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Plik dodatku poza katalogiem gry: " + name);
            return dest;
        }

        private static bool IsWhitelistedDirectory(string name)
        {
            var segments = name.Split('/');
            if (segments.Length < 1 || segments.Length > 4) return false;
            var prefix = new[] { "Interface", "AddOns" };
            for (var i = 0; i < segments.Length; i++)
            {
                if (string.IsNullOrEmpty(segments[i]) || segments[i] == "." || segments[i] == "..") return false;
                if (i < 2 && !string.Equals(segments[i], prefix[i], StringComparison.Ordinal)) return false;
            }
            return segments.Length <= 2 ||
                string.Equals(segments[2], "LazyScript", StringComparison.Ordinal) ||
                string.Equals(segments[2], "LazyRogue", StringComparison.Ordinal) ||
                string.Equals(segments[2], "LazyWarlock", StringComparison.Ordinal) ||
                string.Equals(segments[2], "SummonScout", StringComparison.Ordinal);
        }

        private static void ValidateAddonName(string name)
        {
            if (string.IsNullOrWhiteSpace(name) || name.Length > 220 || name.IndexOf('\\') >= 0 ||
                name.IndexOf(':') >= 0 || name.IndexOf('\0') >= 0)
                throw new InvalidOperationException("Nieprawidłowa ścieżka dodatku: " + name);
            var segments = name.Split('/');
            if (segments.Length < 4 || segments.Length > 8 ||
                !string.Equals(segments[0], "Interface", StringComparison.Ordinal) ||
                !string.Equals(segments[1], "AddOns", StringComparison.Ordinal) ||
                !(string.Equals(segments[2], "LazyScript", StringComparison.Ordinal) ||
                  string.Equals(segments[2], "LazyRogue", StringComparison.Ordinal) ||
                  string.Equals(segments[2], "LazyWarlock", StringComparison.Ordinal) ||
                  string.Equals(segments[2], "SummonScout", StringComparison.Ordinal)))
                throw new InvalidOperationException("Addon poza dozwolonymi folderami: " + name);
            foreach (var segment in segments)
            {
                if (string.IsNullOrWhiteSpace(segment) || segment == "." || segment == ".." ||
                    segment.EndsWith(".", StringComparison.Ordinal) || segment.EndsWith(" ", StringComparison.Ordinal) ||
                    segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                    segment.IndexOfAny(new[] { '<', '>', '"', '|', '?', '*' }) >= 0)
                    throw new InvalidOperationException("Niebezpieczna nazwa pliku dodatku: " + name);
            }
            var extension = Path.GetExtension(name).ToLowerInvariant();
            if (!new[] { ".lua", ".toc", ".xml", ".md", ".tga" }.Contains(extension))
                throw new InvalidOperationException("Nieobsługiwany typ pliku dodatku: " + name);
        }

        private static byte[] ReadBounded(ZipArchiveEntry entry, int maxBytes)
        {
            if (entry.Length > maxBytes) throw new InvalidOperationException("Plik dodatku przekracza limit: " + entry.FullName);
            using (var input = entry.Open())
            using (var output = new MemoryStream())
            {
                var buffer = new byte[16384];
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (output.Length + count > maxBytes)
                        throw new InvalidOperationException("Rozpakowany plik dodatku przekracza limit: " + entry.FullName);
                    output.Write(buffer, 0, count);
                }
                return output.ToArray();
            }
        }

        private static string Sha256(byte[] bytes)
        {
            using (var hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
    }
}
