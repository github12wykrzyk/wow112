using System;
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
    // trunk. Only the exact branch-ref lookup for /branches/parallel is rewritten
    // to /branches/parallel-testpoint. Actions queries still use branch=parallel,
    // so downloaded artifacts and attestations retain their original Parallel
    // provenance while the user-facing test point remains frozen.
    internal sealed class HttpClientHandler : System.Net.Http.HttpClientHandler
    {
        private const string ParallelBranchPath = "/repos/github12wykrzyk/wow112/branches/parallel";
        private const string TestPointBranchPath = "/repos/github12wykrzyk/wow112/branches/parallel-testpoint";

        public HttpClientHandler()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            try
            {
                RewriteParallelBranchLookup(request);
                return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                var root = ex.GetBaseException();
                var detail = root == null || string.IsNullOrWhiteSpace(root.Message) ? ex.Message : root.Message;
                throw new HttpRequestException("GitHub transport error: " + detail, ex);
            }
        }

        private static void RewriteParallelBranchLookup(HttpRequestMessage request)
        {
            if (request == null || request.RequestUri == null) return;
            var uri = request.RequestUri;
            if (!string.Equals(uri.Host, "api.github.com", StringComparison.OrdinalIgnoreCase)) return;
            if (!string.Equals(uri.AbsolutePath, ParallelBranchPath, StringComparison.OrdinalIgnoreCase)) return;

            var builder = new UriBuilder(uri) { Path = TestPointBranchPath };
            request.RequestUri = builder.Uri;
        }
    }
}
