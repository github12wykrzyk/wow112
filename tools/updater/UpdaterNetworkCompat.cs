using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace WoW112Updater
{
    // GitHub requires modern TLS. On some Windows/.NET Framework configurations
    // HttpClient otherwise inherits an older system default and fails before an
    // HTTP response is received with only "An error occurred while sending the request."
    //
    // This type intentionally shadows System.Net.Http.HttpClientHandler inside
    // the WoW112Updater namespace, so the existing updater source picks it up
    // without changing its networking call sites.
    //
    // Delivery is intentionally decoupled from the moving Parallel development
    // trunk. Branch identity is resolved through parallel-testpoint. The STANDARD
    // candidate lookup is also narrowed to build_work_candidate.yml so unrelated
    // high-volume Actions runs can never push the exact testpoint run out of the
    // updater's result window. Artifact provenance still remains branch=parallel.
    internal sealed class HttpClientHandler : System.Net.Http.HttpClientHandler
    {
        private const string ParallelBranchPath = "/repos/github12wykrzyk/wow112/branches/parallel";
        private const string TestPointBranchPath = "/repos/github12wykrzyk/wow112/branches/parallel-testpoint";
        private const string ActionsRunsPath = "/repos/github12wykrzyk/wow112/actions/runs";
        private const string CandidateWorkflowRunsPath = "/repos/github12wykrzyk/wow112/actions/workflows/build_work_candidate.yml/runs";

        public HttpClientHandler()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            try
            {
                RewriteParallelDeliveryLookup(request);
                return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                var root = ex.GetBaseException();
                var detail = root == null || string.IsNullOrWhiteSpace(root.Message) ? ex.Message : root.Message;
                throw new HttpRequestException("GitHub transport error: " + detail, ex);
            }
        }

        private static void RewriteParallelDeliveryLookup(HttpRequestMessage request)
        {
            if (request == null || request.RequestUri == null) return;
            var uri = request.RequestUri;
            if (!string.Equals(uri.Host, "api.github.com", StringComparison.OrdinalIgnoreCase)) return;

            if (string.Equals(uri.AbsolutePath, ParallelBranchPath, StringComparison.OrdinalIgnoreCase))
            {
                var branchBuilder = new UriBuilder(uri) { Path = TestPointBranchPath };
                request.RequestUri = branchBuilder.Uri;
                return;
            }

            // The STANDARD/ANGLE/AUTO-REAR candidate path asks for branch=parallel&per_page=50.
            // Keep the query intact but scope it to the authoritative workflow endpoint.
            // The GitHub monitor uses per_page=30/100 and ECONOMY has its own route, so this
            // rewrite is deliberately narrow and does not alter those consumers.
            if (string.Equals(uri.AbsolutePath, ActionsRunsPath, StringComparison.OrdinalIgnoreCase)
                && QueryContains(uri.Query, "branch=parallel")
                && QueryContains(uri.Query, "per_page=50"))
            {
                var candidateBuilder = new UriBuilder(uri) { Path = CandidateWorkflowRunsPath };
                request.RequestUri = candidateBuilder.Uri;
            }
        }

        private static bool QueryContains(string query, string token)
        {
            if (string.IsNullOrEmpty(query) || string.IsNullOrEmpty(token)) return false;
            var text = query[0] == '?' ? query.Substring(1) : query;
            foreach (var part in text.Split('&'))
                if (string.Equals(part, token, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
    }

    // MainForm historically resolves the updater-local WoW112Updater.Process guard before
    // System.Diagnostics.Process. That guard is correct for WoW launches but wrong for the
    // Android terminal backend, where adb.exe must be executed as a normal Windows process.
    // Keep every legacy call fail-closed through the guard and bypass it only for adb.exe.
    internal sealed partial class MainForm
    {
        private static class Process
        {
            public static global::WoW112Updater.Process[] GetProcesses()
            {
                return global::WoW112Updater.Process.GetProcesses();
            }

            public static System.Diagnostics.Process Start(System.Diagnostics.ProcessStartInfo startInfo)
            {
                if (startInfo != null
                    && string.Equals(Path.GetFileName(startInfo.FileName), "adb.exe", StringComparison.OrdinalIgnoreCase))
                    return System.Diagnostics.Process.Start(startInfo);

                return global::WoW112Updater.Process.Start(startInfo);
            }

            public static System.Diagnostics.Process Start(System.Diagnostics.ProcessStartInfo startInfo, string configName)
            {
                return global::WoW112Updater.Process.Start(startInfo, configName);
            }

            public static System.Diagnostics.Process Start(System.Diagnostics.ProcessStartInfo startInfo, string configName, bool backgroundSound)
            {
                return global::WoW112Updater.Process.Start(startInfo, configName, backgroundSound);
            }
        }
    }
}
