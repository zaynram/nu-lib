# Serve a directory on an ephemeral localhost port, for the pman `bump-nu` tests.
#
# Usage: python3 -I serve.py ROOT PORT_FILE LOG_FILE
# Writes the port to PORT_FILE once listening, appends "<path>\t<Authorization header>" to LOG_FILE for every GET,
# and exits on its own after two minutes in case the test that started it never stops it.
import functools
import http.server
import os
import sys
import threading

root, port_file, log_file = sys.argv[1:4]


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(log_file, "a") as log:
            log.write(f"{self.path}\t{self.headers.get('Authorization', '')}\n")
        super().do_GET()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=root))
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.replace(port_file + ".tmp", port_file)
deadline = threading.Timer(120, lambda: os._exit(0))
deadline.daemon = True
deadline.start()
server.serve_forever()
