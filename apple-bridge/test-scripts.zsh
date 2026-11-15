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

# The stand-in: answers /v1/health with the JSON in $scratch/health, and anything else 404.
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I - "$port" "$scratch/health" <<'EOF' &
import http.server, sys
port, body = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = open(body, "rb").read() if self.path == "/v1/health" else b""
        self.send_response(200 if data else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
server=$!
support=$scratch/support
mkdir -p "$support"
print -r -- "{\"port\": $port}" >"$support/config.json"
export OMAROCK_BRIDGE_SUPPORT=$support
print -r -- '{}' >"$scratch/health"
for _ in {1..50}; do curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/v1/health" && break; sleep 0.1; done

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

# The payload works: unchecked, it runs.
serve "\"path[\$(touch ${(q)mark})]\""
raw=$(curl -s -m 5 "http://127.0.0.1:$port/v1/health" | plutil -extract listeners raw -o - - 2>/dev/null)
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

exit $failed
