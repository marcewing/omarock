const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Any account on the machine can read every program's command line (ps), so
// omarock gives keys, tokens and files' contents to programs on stdin. The
// docs and the setup windows show commands people copy: they must do the same.

const root = path.join(__dirname, "..")

// The tracked docs (not private notes beside them), and the setup windows' text.
function texts() {
  const listed = require("node:child_process")
    .execFileSync("git", ["ls-files", "-z", "--", "*.md", "Setup.js"], { cwd: root, encoding: "utf8" })
  return listed.split("\0").filter(f => f && !f.startsWith("tools/capture/")).map(f => path.join(root, f))
}

const rules = [
  // A file's contents substituted into an argument: $(cat FILE), $(<FILE).
  [/\$\(\s*(cat\s|<)/, "a file's contents on a command line"],
  // A bearer token written out or substituted (<token> and … stand for one).
  [/Authorization:\s*Bearer\s+(?![<…])\S/, "a bearer token on a command line"],
  // Soloist's key: only @key, which the shim replaces.
  [/--api-key[ =]+(?!@key)(\$|["']|[0-9a-fA-F]{16})/, "Soloist's key on its command line"],
  // A login on curl's or anything's command line.
  [/(^|\s)(-u|--user)\s+\S+:\S+/, "a login on a command line"],
  [/--password[ =]\S/, "a password on a command line"],
]

test("no doc or setup window shows a secret on a command line", () => {
  const files = texts()
  assert.ok(files.some(f => f.endsWith("README.md")), "found the READMEs")
  const problems = []
  for (const file of files) {
    fs.readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      for (const [pattern, what] of rules)
        if (pattern.test(line)) problems.push(`${path.relative(root, file)}:${i + 1}: ${what}: ${line.trim()}`)
    })
  }
  assert.deepEqual(problems, [])
})

test("the rules catch what they're for", () => {
  const caught = line => rules.some(([pattern]) => pattern.test(line))
  assert.ok(caught('curl -X POST -H "Authorization: Bearer $(cat ~/.config/omarock/bridge-token)" http://mac:8710/v1/authorize'))
  assert.ok(caught("jq --arg s \"$(<~/.config/omarock/apple.json)\""))
  assert.ok(caught("soloist --api-key 0123456789abcdef0123456789abcdef"))
  assert.ok(caught("soloist --api-key \"$(<~/.config/omarock/soloist-key)\""))
  assert.ok(!caught("Soloist: \"login failed: make sure --api-key is valid\""))
  assert.ok(caught("curl -u admin:hackme http://127.0.0.1:8000/admin/stats"))
  assert.ok(!caught("Every request carries `Authorization: Bearer <token>`."))
  assert.ok(!caught("on a command line (`curl -H \"Authorization: Bearer …\"`)"))
  assert.ok(!caught("its unit passes `--api-key @key`"))
  assert.ok(!caught("tools/omarock-am authorize"))
})

// An Omarchy plugin install copies the whole repository into
// ~/.config/omarchy/plugins/: instructions for coding agents in it would be
// found, and followed, by an agent someone runs over ~/.config, without their
// opting in. The setup skill lives in docs/claude/ instead (DEVELOPING.md).
test("no coding-agent instructions in the tree", () => {
  const files = require("node:child_process")
    .execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" }).split("\0").filter(Boolean)
  const agents = files.filter(f =>
    /(^|\/)(CLAUDE|AGENTS|GEMINI)(\.local)?\.md$/i.test(f)
    || /(^|\/)\.(claude|agents|cursor|windsurf)\//.test(f)
    || /(^|\/)\.(cursorrules|windsurfrules|clinerules)$/.test(f)
    || /(^|\/)\.github\/(copilot-instructions\.md|instructions\/|prompts\/)/.test(f))
  assert.deepEqual(agents, [])
})
