# ptydrive.py RULES.json LOG -- COMMAND...: run COMMAND in a 40x120 pty, and
# each time a rule's pattern shows up in new output, send its keys. Rules:
# [[regex, keys], ...]; keys use Python escapes ("\r", "\x03"). Each rule
# fires at most once. Writes everything seen, ANSI stripped, to LOG.
import json, os, pty, re, select, sys, time, fcntl, termios, struct

rules_file, log_file = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index("--") + 1:]
rules = [[re.compile(p), k.encode().decode("unicode_escape").encode("latin1"), False]
         for p, k in json.load(open(rules_file))]
ansi = re.compile(r"\x1b\[[0-9;?=>$]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>]")

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
raw, seen, deadline = b"", 0, time.time() + 1800
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        raw += chunk
        # Answer terminal queries as a terminal would: cursor position, background colour.
        if b"\x1b[6n" in chunk:
            os.write(fd, b"\x1b[1;1R")
        if b"\x1b]11;?" in chunk:
            os.write(fd, b"\x1b]11;rgb:0000/0000/0000\x07")
    text = ansi.sub("", raw.decode("utf-8", "replace"))
    for rule in rules:
        if not rule[2] and rule[0].search(text, seen):
            time.sleep(0.6)
            os.write(fd, rule[1])
            rule[2] = True
            seen = len(text)
            print("sent", repr(rule[1]), "for", rule[0].pattern, flush=True)
_, status = os.waitpid(pid, 0)
open(log_file, "w").write(ansi.sub("", raw.decode("utf-8", "replace")).replace("\r\n", "\n"))
print("exit", os.waitstatus_to_exitcode(status))
