using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace WoW112Updater
{
    internal static class UpdaterAddonsTests
    {
        private const string Head = "0123456789abcdef0123456789abcdef01234567";

        public static int Main()
        {
            try
            {
                AcceptsFutureAddonWithoutNameWhitelist();
                RejectsTraversal();
                RejectsAddonWithoutRootToc();
                Console.WriteLine("UPDATER_ADDONS_TESTS: PASS");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("UPDATER_ADDONS_TESTS: FAIL " + ex);
                return 1;
            }
        }

        private static void AcceptsFutureAddonWithoutNameWhitelist()
        {
            var inner = BuildInner(new Dictionary<string, string>
            {
                { "Interface/AddOns/LazyScript/LazyScript.toc", "## Interface: 11200" },
                { "Interface/AddOns/LazyRogue/LazyRogue.toc", "## Interface: 11200" },
                { "Interface/AddOns/LazyWarlock/LazyWarlock.toc", "## Interface: 11200" },
                { "Interface/AddOns/FutureAddon/FutureAddon.toc", "## Interface: 11200" },
                { "Interface/AddOns/FutureAddon/README.md", "future addon" },
                { "Interface/AddOns/FutureAddon/UI/icon.blp", "asset" },
            });
            var outer = BuildOuter(inner, 6);
            var assets = UpdaterAddons.ReadFromArtifact(outer, true, Head);
            if (assets.Count != 6)
                throw new InvalidOperationException("future addon asset count mismatch");
        }

        private static void RejectsTraversal()
        {
            var inner = BuildInner(new Dictionary<string, string>
            {
                { "Interface/AddOns/LazyScript/LazyScript.toc", "x" },
                { "Interface/AddOns/LazyRogue/LazyRogue.toc", "x" },
                { "Interface/AddOns/LazyWarlock/LazyWarlock.toc", "x" },
                { "Interface/AddOns/FutureAddon/FutureAddon.toc", "x" },
                { "Interface/AddOns/FutureAddon/../escape.lua", "x" },
            });
            ExpectFailure(BuildOuter(inner, 5), "traversal");
        }

        private static void RejectsAddonWithoutRootToc()
        {
            var inner = BuildInner(new Dictionary<string, string>
            {
                { "Interface/AddOns/LazyScript/LazyScript.toc", "x" },
                { "Interface/AddOns/LazyRogue/LazyRogue.toc", "x" },
                { "Interface/AddOns/LazyWarlock/LazyWarlock.toc", "x" },
                { "Interface/AddOns/FutureAddon/README.md", "x" },
            });
            ExpectFailure(BuildOuter(inner, 4), "missing toc");
        }

        private static void ExpectFailure(byte[] outer, string label)
        {
            try
            {
                UpdaterAddons.ReadFromArtifact(outer, true, Head);
            }
            catch (InvalidOperationException)
            {
                return;
            }
            throw new InvalidOperationException("expected rejection: " + label);
        }

        private static byte[] BuildInner(Dictionary<string, string> files)
        {
            using (var output = new MemoryStream())
            {
                using (var zip = new ZipArchive(output, ZipArchiveMode.Create, true))
                {
                    foreach (var pair in files)
                    {
                        var entry = zip.CreateEntry(pair.Key, CompressionLevel.Optimal);
                        using (var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false)))
                            writer.Write(pair.Value);
                    }
                }
                return output.ToArray();
            }
        }

        private static byte[] BuildOuter(byte[] inner, int fileCount)
        {
            var meta = new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "zip_name", "WoW112_LAZYROGUE_HYBRID_ADDONS.zip" },
                { "addon_sha256", Sha256(inner) },
                { "file_count", fileCount },
                { "git_sha", Head },
            };
            var json = new JavaScriptSerializer().Serialize(meta);

            using (var output = new MemoryStream())
            {
                using (var zip = new ZipArchive(output, ZipArchiveMode.Create, true))
                {
                    var addon = zip.CreateEntry("WoW112_LAZYROGUE_HYBRID_ADDONS.zip", CompressionLevel.Optimal);
                    using (var stream = addon.Open())
                        stream.Write(inner, 0, inner.Length);

                    var manifest = zip.CreateEntry("addon_metadata.json", CompressionLevel.Optimal);
                    using (var writer = new StreamWriter(manifest.Open(), new UTF8Encoding(false)))
                        writer.Write(json);
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
