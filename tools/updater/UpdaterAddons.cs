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
    // candidate artifact. The archive is commit-bound by addon_metadata.json.
    //
    // Important: addon folder names are intentionally NOT hard-coded here.
    // Any safely named Interface/AddOns/<Addon>/ tree is accepted if that addon
    // owns a root-level .toc file. This keeps future repo-managed addons from
    // requiring an updater release just to extend a name whitelist.
    internal static class UpdaterAddons
    {
        private const string ZipName = "WoW112_LAZYROGUE_HYBRID_ADDONS.zip";
        private const string MetadataName = "addon_metadata.json";
        private const int MaxAddonBytes = 8 * 1024 * 1024;
        private const int MaxAddonZipBytes = 64 * 1024 * 1024;
        private const int MaxAddonFiles = 2000;

        private static readonly string[] RequiredCoreAddons =
        {
            "LazyScript",
            "LazyRogue",
            "LazyWarlock",
        };

        private static readonly HashSet<string> AllowedExtensions =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                ".lua", ".toc", ".xml",
                ".tga", ".blp", ".ttf",
                ".txt", ".md",
                ".wav", ".mp3", ".ogg",
                ".jpg", ".jpeg", ".png",
            };

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
                    throw new InvalidOperationException("Artifact nie zawiera kompletnej, jednoznacznej paczki addonow i addon_metadata.json.");

                var serializer = new JavaScriptSerializer();
                var metaBytes = ReadBounded(metaEntries[0], 16 * 1024);
                var meta = serializer.DeserializeObject(Encoding.UTF8.GetString(metaBytes)) as Dictionary<string, object>;
                if (meta == null) throw new InvalidOperationException("Nieprawidlowy addon_metadata.json.");

                object value;
                var sha = meta.TryGetValue("addon_sha256", out value) ? Convert.ToString(value) : string.Empty;
                var gitSha = meta.TryGetValue("git_sha", out value) ? Convert.ToString(value) : string.Empty;
                var name = meta.TryGetValue("zip_name", out value) ? Convert.ToString(value) : string.Empty;
                if (!UpdaterSafety.IsSha256Hex(sha) ||
                    !string.Equals(name, ZipName, StringComparison.Ordinal) ||
                    !string.Equals(gitSha, expectedHeadSha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Niezgodny SHA/commit/format manifestu dodatkow.");

                var addonZip = ReadBounded(zipEntries[0], MaxAddonZipBytes);
                if (!string.Equals(Sha256(addonZip), sha, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("SHA256 ZIP-a dodatkow nie zgadza sie z addon_metadata.json.");

                var files = new List<UpdaterAddonAsset>();
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var addonRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                using (var inner = new MemoryStream(addonZip, false))
                using (var addons = new ZipArchive(inner, ZipArchiveMode.Read, false))
                {
                    foreach (var entry in addons.Entries)
                    {
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            ValidateAddonDirectory(entry.FullName);
                            continue;
                        }

                        var root = ValidateAddonName(entry.FullName);
                        addonRoots.Add(root);
                        if (!names.Add(entry.FullName))
                            throw new InvalidOperationException("Duplikat pliku dodatku: " + entry.FullName);

                        files.Add(new UpdaterAddonAsset(entry.FullName, ReadBounded(entry, MaxAddonBytes)));
                        if (files.Count > MaxAddonFiles)
                            throw new InvalidOperationException("Nadmierna liczba plikow w paczce dodatkow.");
                    }
                }

                var count = meta.TryGetValue("file_count", out value) ? Convert.ToInt32(value) : -1;
                if (count != files.Count || files.Count == 0 || addonRoots.Count == 0)
                    throw new InvalidOperationException("Niekompletna lub niespojna paczka addonow.");

                foreach (var root in addonRoots)
                {
                    if (!HasRootToc(names, root))
                        throw new InvalidOperationException("Addon bez glownego pliku .toc: " + root);
                }

                foreach (var required in RequiredCoreAddons)
                {
                    if (!addonRoots.Contains(required) || !HasRootToc(names, required))
                        throw new InvalidOperationException("Brak wymaganego bazowego addonu: " + required);
                }

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
                    throw new InvalidOperationException("Katalog dodatku jest laczem/reparse point: " + name);
            }

            var dest = Path.GetFullPath(path);
            if (!dest.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Plik dodatku poza katalogiem gry: " + name);
            return dest;
        }

        private static void ValidateAddonDirectory(string name)
        {
            if (string.IsNullOrWhiteSpace(name) || !name.EndsWith("/", StringComparison.Ordinal) ||
                name.IndexOf('\\') >= 0 || name.IndexOf(':') >= 0 || name.IndexOf('\0') >= 0)
                throw new InvalidOperationException("Nieprawidlowy katalog dodatku: " + name);

            var trimmed = name.TrimEnd('/');
            var segments = trimmed.Split('/');
            if (segments.Length < 1 || segments.Length > 8 ||
                !string.Equals(segments[0], "Interface", StringComparison.Ordinal) ||
                (segments.Length >= 2 && !string.Equals(segments[1], "AddOns", StringComparison.Ordinal)))
                throw new InvalidOperationException("Katalog poza Interface/AddOns: " + name);

            for (var i = 2; i < segments.Length; i++)
                ValidateSafeSegment(segments[i], name);
        }

        private static string ValidateAddonName(string name)
        {
            if (string.IsNullOrWhiteSpace(name) || name.Length > 260 || name.IndexOf('\\') >= 0 ||
                name.IndexOf(':') >= 0 || name.IndexOf('\0') >= 0)
                throw new InvalidOperationException("Nieprawidlowa sciezka dodatku: " + name);

            var segments = name.Split('/');
            if (segments.Length < 4 || segments.Length > 8 ||
                !string.Equals(segments[0], "Interface", StringComparison.Ordinal) ||
                !string.Equals(segments[1], "AddOns", StringComparison.Ordinal))
                throw new InvalidOperationException("Addon poza Interface/AddOns: " + name);

            for (var i = 2; i < segments.Length; i++)
                ValidateSafeSegment(segments[i], name);

            var extension = Path.GetExtension(name);
            if (!AllowedExtensions.Contains(extension))
                throw new InvalidOperationException("Nieobslugiwany typ pliku dodatku: " + name);

            return segments[2];
        }

        private static void ValidateSafeSegment(string segment, string fullName)
        {
            if (string.IsNullOrWhiteSpace(segment) || segment == "." || segment == ".." ||
                segment.Length > 100 ||
                segment.EndsWith(".", StringComparison.Ordinal) || segment.EndsWith(" ", StringComparison.Ordinal) ||
                segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                segment.IndexOfAny(new[] { '<', '>', '"', '|', '?', '*' }) >= 0)
                throw new InvalidOperationException("Niebezpieczna nazwa w sciezce dodatku: " + fullName);
        }

        private static bool HasRootToc(HashSet<string> names, string root)
        {
            var prefix = "Interface/AddOns/" + root + "/";
            foreach (var name in names)
            {
                if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    continue;
                var rest = name.Substring(prefix.Length);
                if (rest.IndexOf('/') < 0 && string.Equals(Path.GetExtension(rest), ".toc", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            return false;
        }

        private static byte[] ReadBounded(ZipArchiveEntry entry, int maxBytes)
        {
            if (entry.Length > maxBytes)
                throw new InvalidOperationException("Plik dodatku przekracza limit: " + entry.FullName);

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
