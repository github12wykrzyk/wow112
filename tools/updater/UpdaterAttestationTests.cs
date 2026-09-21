using System;
using System.Collections.Generic;

namespace WoW112Updater
{
    internal static class UpdaterAttestationTests
    {
        private const string Head = "b3012ceeb3850064f327f20b5c9a9e4b4d96ff19";
        private const string Hash = "9a735271283a49d16ca670d6a6fc8bb12937deca07221087c608b27c2ffd42a2";
        private static int checks;

        private static Dictionary<string, object> Valid()
        {
            return new Dictionary<string, object>
            {
                { "schema_version", 1 },
                { "branch", "parallel" },
                { "commit_sha", Head },
                { "package_sha256", Hash },
                { "package_size", 12345L },
                { "result", "PASS" },
                { "source_check", "SOURCE_CHECK_PASS" },
                { "native_build", "X86_BUILD_PASS" },
                { "package_status", "PACKAGE_VERIFIED" },
                { "delivery_status", "READY_FOR_GAME_TEST" },
                { "game_test_accepted", false }
            };
        }

        private static void Accept(Dictionary<string, object> proof)
        {
            UpdaterSafety.RequireCandidateAttestation(proof, Head, Hash, 12345L);
            ++checks;
        }

        private static void Reject(Dictionary<string, object> proof)
        {
            try
            {
                UpdaterSafety.RequireCandidateAttestation(proof, Head, Hash, 12345L);
            }
            catch (InvalidOperationException)
            {
                ++checks;
                return;
            }
            throw new Exception("Attestation gate accepted a corrupt, stale or partial candidate");
        }

        private static void Bad(string field, object value)
        {
            var proof = Valid();
            proof[field] = value;
            Reject(proof);
            proof.Remove(field);
            Reject(proof);
        }

        private static void HeadAccept(string candidate, string current)
        {
            UpdaterSafety.RequireCurrentParallelHead(candidate, current);
            ++checks;
        }

        private static void HeadReject(string candidate, string current)
        {
            try { UpdaterSafety.RequireCurrentParallelHead(candidate, current); }
            catch (InvalidOperationException) { ++checks; return; }
            throw new Exception("Updater accepted a stale, unknown or malformed parallel HEAD");
        }

        private static Dictionary<string, object> Run(string branch, string status, string conclusion)
        {
            return new Dictionary<string, object> {
                {"name", "Build work candidate"}, {"head_branch", branch},
                {"status", status}, {"conclusion", conclusion}
            };
        }

        private static void LatestRunTests()
        {
            var selected = UpdaterSafety.RequireLatestSuccessfulRun(
                new object[] { Run("work", "completed", "success"), Run("parallel", "completed", "success") },
                "Build work candidate", "parallel");
            if (selected["head_branch"].ToString() != "parallel")
                throw new Exception("A successful work build was selected for parallel");
            ++checks;
            foreach (var invalid in new[] {
                Run("parallel", "queued", ""),
                Run("parallel", "completed", "failure"),
                Run("parallel", "completed", "cancelled")
            })
            {
                try {
                    UpdaterSafety.RequireLatestSuccessfulRun(
                        new object[] { invalid, Run("parallel", "completed", "success") },
                        "Build work candidate", "parallel");
                }
                catch (InvalidOperationException) { ++checks; continue; }
                throw new Exception("Updater fell back to an older successful parallel run");
            }
        }

        private static void UpdaterProvenanceTests()
        {
            var valid = new Dictionary<string, object> {
                {"git_sha", Head}, {"channel", "parallel"}, {"name", "WoW112ParallelUpdater.exe"},
                {"bootstrap_name", "WoW112UpdaterBootstrap.exe"}, {"self_update_protocol", 1},
                {"updater_version", "2.6-parallel.1"}, {"sha256", Hash}, {"bootstrap_sha256", Hash},
                {"size", 8192L}, {"bootstrap_size", 4096L},
                {"pe_machine", "0x014C"}, {"bootstrap_pe_machine", "0x014C"}
            };
            Action<Dictionary<string, object>, string, string> reject = (meta, sha, name) => {
                try { UpdaterSafety.RequireUpdaterArtifactProvenance(meta, sha, name); }
                catch (InvalidOperationException) { ++checks; return; }
                throw new Exception("Updater accepted mismatched build provenance");
            };
            var nameOk = "WoW112ParallelUpdater-" + Head;
            UpdaterSafety.RequireUpdaterArtifactProvenance(valid, Head, nameOk); ++checks;
            reject(valid, "0000000000000000000000000000000000000000", nameOk);
            reject(valid, Head, "WoW112ParallelUpdater-" + Hash.Substring(0, 40));
            foreach (var field in new[] { "git_sha", "channel", "name", "bootstrap_name",
                "self_update_protocol", "updater_version", "sha256", "bootstrap_sha256",
                "size", "bootstrap_size", "pe_machine", "bootstrap_pe_machine" })
            {
                var invalid = new Dictionary<string, object>(valid);
                invalid.Remove(field); reject(invalid, Head, nameOk);
            }
            var wrongChannel = new Dictionary<string, object>(valid);
            wrongChannel["channel"] = "work"; reject(wrongChannel, Head, nameOk);
            var wrongSha = new Dictionary<string, object>(valid);
            wrongSha["git_sha"] = "0000000000000000000000000000000000000000";
            reject(wrongSha, Head, nameOk);
        }

        public static int Main()
        {
            try
            {
                Accept(Valid());
                var noRebuild = Valid();
                noRebuild["native_build"] = "X86_BUILD_NOT_REQUIRED";
                Accept(noRebuild);
                Bad("branch", "work");
                Bad("commit_sha", "0000000000000000000000000000000000000000");
                Bad("package_sha256", "0000000000000000000000000000000000000000000000000000000000000000");
                Bad("package_size", 12344L);
                Bad("schema_version", 0);
                Bad("result", "FAIL");
                Bad("source_check", "SOURCE_CHECK_FAIL");
                Bad("native_build", "X86_BUILD_FAIL");
                Bad("package_status", "PACKAGE_UNVERIFIED");
                Bad("delivery_status", "GAME_TEST_ACCEPTED");
                Bad("game_test_accepted", true);
                Bad("game_test_accepted", "false");
                Reject(null);
                HeadAccept(Head, Head);
                HeadAccept(Head.ToUpperInvariant(), Head);
                HeadReject(Head, "0000000000000000000000000000000000000000");
                HeadReject(Head, "");
                HeadReject("", Head);
                HeadReject(Head, "X" + Head.Substring(1));
                LatestRunTests();
                UpdaterProvenanceTests();
                Console.WriteLine("UPDATER_ATTESTATION_TESTS: PASS (" + checks + " assertions)");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("UPDATER_ATTESTATION_TESTS: FAIL: " + ex.Message);
                return 1;
            }
        }
    }
}
