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
    internal sealed class HttpClientHandler : System.Net.Http.HttpClientHandler
    {
        public HttpClientHandler()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            try
            {
                return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                var root = ex.GetBaseException();
                var detail = root == null || string.IsNullOrWhiteSpace(root.Message) ? ex.Message : root.Message;
                throw new HttpRequestException("GitHub transport error: " + detail, ex);
            }
        }
    }
}
