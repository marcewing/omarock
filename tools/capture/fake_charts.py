#!/usr/bin/python3
"""A fake Wikipedia (its API's action=parse), for testing Time Machine's
Top 100 away from the real one: Billboard's year-end chart for 1985 as a
page of wikitext, in the shapes Wikipedia's pages use (a rowspan, a row
header, a sort value, a reference, a double A-side), with songs the fake
bridge's catalog has (one only as a later version: 1989's), and some it
doesn't. Every other year's page is missing. Every request is logged (path, query and Api-User-Agent).

    fake_charts.py <port-file> <request-log>
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlparse

CHART_1985 = """Some words about the year.

{| class="wikitable sortable" style="text-align: center"
|-
! scope="col" style="background:#dde;"| {{Abbr|No.|Number}}
! scope="col" style="background:#dde;"| Title
! scope="col" style="background:#dde;"| Artist(s)
|-
|1 || "[[New Day Rising (song)|New Day Rising]]" || rowspan="2"| [[Hüsker Dü]]
|-
|2 || "[[Celebrated Summer]]"<ref>{{cite web|url=https://example.org|title=x}}</ref>
|-
| scope="row" | 3
| "[[Keep On Loving You]]" ||data-sort-value="REO"| [[REO Speedwagon]]
|-
|4 || "[[Careless Whisper]]" || [[Wham!]] featuring [[George Michael]]
|-
|5 || "[[Makes No Sense at All]]" / "[[Love Is All Around (Mary Tyler Moore Theme)|Love Is All Around]]" || [[Hüsker Dü]]
|-
|6 || "See a Little Light" || [[Bob Mould]]
""" + "".join(f"|-\n|{n} || \"[[Chart Song {n}]]\" || [[The Chart Band {n}]]\n" for n in range(7, 13)) + """|}

== References ==
{{reflist}}
"""

PAGES = {"Billboard Year-End Hot 100 singles of 1985": CHART_1985}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        with open(self.server.log_path, "a") as log:
            log.write(json.dumps({"path": url.path, "query": query,
                                  "agent": self.headers.get("Api-User-Agent", "")}) + "\n")
        if url.path != "/w/api.php" or query.get("action") != "parse":
            return self.reply(404, {"error": {"code": "badroute", "info": "No such route"}})
        page = query.get("page", "")
        if page not in PAGES:
            return self.reply(200, {"error": {"code": "missingtitle", "info": "The page you specified doesn't exist."}})
        return self.reply(200, {"parse": {"title": page, "pageid": 1, "wikitext": PAGES[page]}})


def main():
    port_file, log = Path(sys.argv[1]), Path(sys.argv[2])
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.log_path = log
    port_file.write_text(str(server.server_address[1]))
    print("fake charts ready", flush=True)
    server.serve_forever()


if __name__ == "__main__": main()
