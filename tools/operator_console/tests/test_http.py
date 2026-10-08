import json,tempfile,threading,unittest,urllib.error,urllib.request
from pathlib import Path
from http.server import ThreadingHTTPServer
from service_adapter import ConsoleApp,handler_factory

class HttpTests(unittest.TestCase):
    def test_manual_whisper_validation(self):
        with tempfile.TemporaryDirectory() as d:
            app=ConsoleApp(Path(d)/'db.sqlite3','127.0.0.1',9,Path(__file__).resolve().parents[1]/'web')
            server=ThreadingHTTPServer(('127.0.0.1',0),handler_factory(app)); t=threading.Thread(target=server.serve_forever,daemon=True);t.start(); port=server.server_address[1]
            req=urllib.request.Request(f'http://127.0.0.1:{port}/api/command',data=json.dumps({'type':'ManualWhisper','customer':'Alice','text':'hi'}).encode(),headers={'Content-Type':'application/json'},method='POST')
            with self.assertRaises(urllib.error.HTTPError) as cm: urllib.request.urlopen(req,timeout=2)
            self.assertEqual(cm.exception.code,400)
            server.shutdown();server.server_close();app.store.close()
if __name__=='__main__':unittest.main()
