#!/bin/zsh
# The Mac scripts' helpers against a stand-in bridge on a scratch port (never 8710), with
# a scratch support folder and no control socket, so they fall back to TCP, as they do
# when the bridge is down and something else holds its port. zsh's math runs any $(…) in
# an array subscript (path[$(cmd)]), so a value from it must never reach (( )) unless
# it's digits.
#
#   apple-bridge/test-scripts.zsh
setopt nounset pipefail
bridge_dir=${0:A:h}
scratch=$(mktemp -d)
trap 'kill $server 2>/dev/null; rm -rf "$scratch"' EXIT
mark=$scratch/ran
failed=0
check() {  # NAME CONDITION...
  local name=$1; shift
  if "$@"; then print -r -- "ok   $name"; else print -r -- "FAIL $name"; failed=1; fi
}
no_mark() { [[ ! -e $mark ]]; }

# The stand-in: answers /v1/health with the JSON in $scratch/health, and anything else
# 404, each reply with this run's nonce. It binds the port itself (port 0, no address
# reuse) and only then reports it, so there's no moment when another account could take
# the port first; and nothing is probed before the listener is known to be the stand-in.
nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
python3 -I - "$scratch/health" "$scratch/port" "$nonce" <<'EOF' &
import http.server, os, sys
body, port_file, nonce = sys.argv[1:]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = open(body, "rb").read() if self.path == "/v1/health" else b""
        self.send_response(200 if data else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Stand-In", nonce)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
class Server(http.server.HTTPServer):
    allow_reuse_address = False
server = Server(("127.0.0.1", 0), H)
with open(port_file + ".new", "w") as f: f.write(str(server.server_address[1]))
os.rename(port_file + ".new", port_file)
server.serve_forever()
EOF
server=$!
for _ in {1..50}; do [[ -s $scratch/port ]] && break; sleep 0.1; done
port=$(<$scratch/port)
[[ $port == <-> ]] || { print "the stand-in didn't start"; exit 1; }
listener=$(lsof -nP -a -iTCP@127.0.0.1:$port -sTCP:LISTEN -t 2>/dev/null)
[[ $listener == $server ]] || { print "127.0.0.1:$port isn't the stand-in's (pid ${listener:-none}, not $server)"; exit 1; }
support=$scratch/support
mkdir -p "$support"
print -r -- "{\"port\": $port}" >"$support/config.json"
export OMAROCK_BRIDGE_SUPPORT=$support
print -r -- '{}' >"$scratch/health"
ours() { curl -s -m 5 -o /dev/null -D - "http://127.0.0.1:$port/v1/health" | grep -qi "^X-Stand-In: $nonce"; }
ours || { print "127.0.0.1:$port doesn't answer with this run's nonce"; exit 1; }

# The helpers: install's by sourcing it without its last line (main "$@"), build.sh's by
# its function definitions, since its top level builds.
[[ $(tail -1 "$bridge_dir/install") == 'main "$@"; exit' ]] || { print "install's last line changed"; exit 1; }
source <(sed '$d' "$bridge_dir/install")
yellow= reset= green= red= bold= dim=
install_listeners() { listeners; }
build_sh_functions=$(awk '/^(bridge_health|listeners)\(\) \{/,/^\}/' "$bridge_dir/app/build.sh")
[[ $build_sh_functions == *'bridge_health()'* && $build_sh_functions == *'listeners()'* ]] ||
  { print "build.sh's bridge_health or listeners isn't where this test looks"; exit 1; }
build_sh_listeners() { (eval "$build_sh_functions"; listeners); }

serve() { print -r -- "{\"listeners\": $1}" >"$scratch/health"; }

# The payload works: unchecked, it runs. (From the JSON here, not over the network.)
raw=$(print -r -- "{\"listeners\": \"path[\$(touch ${(q)mark})]\"}" | plutil -extract listeners raw -o - - 2>/dev/null)
(( ${raw:-0} > 0 )) 2>/dev/null
check "unchecked, the stand-in's value runs a command (the test can see it)" test -e "$mark"
rm -f "$mark"

for payload in \
  "\"path[\$(touch ${(q)mark})]\"" \
  "\"1+path[\$(touch ${(q)mark})]\"" \
  "\"argv[\$(touch ${(q)mark})]\"" \
  "\"\$(touch ${(q)mark})\"" \
  '"2 > 1"' '"-1"' '""' 'null' '"x"'; do
  serve "$payload"
  for helper in install_listeners build_sh_listeners; do
    got=$($helper)
    (( ${got:-0} > 0 )) 2>/dev/null
    check "$helper: $payload gives nothing, and nothing runs" eval '[[ -z $got ]] && no_mark'
    rm -f "$mark"
  done
done
# install's --uninstall line itself, as written.
serve "\"path[\$(touch ${(q)mark})]\""
(( ${$(listeners):-0} > 0 )) 2>/dev/null
check "install's --uninstall check runs nothing" no_mark

for n in 0 3; do
  serve $n
  for helper in install_listeners build_sh_listeners; do
    check "$helper: $n listeners gives $n" eval '[[ $($helper) == $n ]]'
  done
done

# The pairing counts (from the control socket, which only this account answers on).
pair_state="{\"triesLeft\": \"path[\$(touch ${(q)mark})]\", \"tries\": 5, \"expiresIn\": \"60*\"}"
check "pair_number: an expression gives nothing" eval '[[ -z $(pair_number triesLeft) && -z $(pair_number expiresIn) ]] && no_mark'
check "pair_number: a count gives it" eval '[[ $(pair_number tries) == 5 ]]'

# Text from the bridge reaches the terminal with only printable characters.
esc=$'a\e]52;c;aGk=\ab\e[2Jc\x7fd\u009be‮f\tg\nh\r'
check "printable: no control characters, C1 or format characters" eval '[[ $(printable "$esc") == "a]52;c;aGk=b[2Jcdefgh" ]]'
check "printable: other text as it is" eval '[[ $(printable "0.14.0 Marc’s M2 Pro é") == "0.14.0 Marc’s M2 Pro é" ]]'
# ./install pair, with an old (or impostor) bridge over TCP, prints its version without them.
app=$scratch/OmarockBridge.app
mkdir -p "$app"
print -r -- "{\"version\": \"0.13.0\\u001b]52;c;aGk=\\u0007\\u001b[2J\\u009b\"}" >"$scratch/health"
said=$( (pair_only) 2>&1 )
check "pair_only: the version, without the escapes" eval '[[ $said == *"the bridge here (0.13.0]52;c;aGk=[2J) is too old"* && $said != *$'"'"'\e'"'"'* && $said != *$'"'"'\a'"'"'* ]]'
check "the stand-in was ours throughout" ours

exit $failed
