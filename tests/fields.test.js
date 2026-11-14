// Every text field in omarock's QML is read-only to Qt, as a constant:
// on Qt 6.12 an editable field reads the whole clipboard each time anything
// sets it, so a huge or endless clipboard freezes the shell. GuardedField.qml
// does the editing itself; its owners take their keys through keyPressed.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const root = path.join(__dirname, "..")

// Qt's text inputs, under any qualifier (Ui.TextField is Omarchy's, a
// Controls TextField that doesn't set readOnly).
const native = new Set(["TextField", "TextInput", "TextArea", "TextEdit"])
// Omarchy's kit pieces with an editable input inside, which can't be made
// read-only from outside.
const forbidden = new Set(["FilterInput", "NumberField", "SearchableDropdown", "MultiSelect"])

// The QML with its comments blanked out (strings kept).
function stripComments(text) {
  let out = ""
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1
      out += text.slice(i, j + 1)
      i = j
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++
      out += "\n"
    } else if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2)
      out += text.slice(i, end < 0 ? text.length : end + 2).replace(/[^\n]/g, " ")
      i = end < 0 ? text.length : end + 1
    } else out += c
  }
  return out
}

// Where the block opened at `open` ends, and its own lines: nested blocks
// shown as {}.
function block(text, open) {
  let depth = 0
  let own = ""
  for (let i = open; i < text.length; i++) {
    const c = text[i]
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1
      while (j < text.length && text[j] !== c) j += text[j] === "\\" ? 2 : 1
      if (depth === 1) own += text.slice(i, j + 1)
      i = j
      continue
    }
    if (c === "{") {
      depth++
      if (depth === 2) own += "{"
      continue
    }
    if (c === "}") {
      depth--
      if (depth === 1) own += "}"
      if (depth === 0) return { end: i, own }
      continue
    }
    if (depth === 1) own += c
  }
  return { end: text.length, own }
}

// Every object declared: { file, line, type (unqualified), component (an
// inline component's name), own (its own lines) }.
function declarations(file, source) {
  const text = stripComments(source)
  const found = []
  const re = /(?:\bcomponent\s+([A-Z]\w*)\s*:\s*)?\b(?:[A-Za-z_]\w*\.)?([A-Z]\w*)\s*\{/g
  let m
  while ((m = re.exec(text))) {
    const open = m.index + m[0].length - 1
    const line = text.slice(0, m.index).split("\n").length
    found.push({ file, line, type: m[2], component: m[1] || "", own: block(text, open).own })
  }
  return found
}

// A property set directly on the object: its value, or undefined.
function own(decl, name) {
  const m = new RegExp("(?:^|[\\n;])\\s*" + name.replace(".", "\\.") + "\\s*:\\s*([^\\n;]*)").exec(decl.own)
  return m ? m[1].trim() : undefined
}

// What's wrong in these files ({ name: source }), as messages.
function check(files) {
  const all = []
  const roots = {}
  for (const [file, source] of Object.entries(files)) {
    const decls = declarations(file, source)
    if (decls.length) roots[path.basename(file, ".qml")] = decls[0].type
    all.push(...decls)
  }
  // The repo's own field types: a file or inline component whose base is a
  // field, to any depth (GuardedField, then SearchBox).
  const derived = new Set()
  for (let grew = true; grew;) {
    grew = false
    const isField = type => native.has(type) || derived.has(type)
    for (const [name, base] of Object.entries(roots))
      if (isField(base) && !derived.has(name)) { derived.add(name); grew = true }
    for (const d of all)
      if (d.component && isField(d.type) && !derived.has(d.component)) { derived.add(d.component); grew = true }
  }
  const problems = []
  for (const d of all) {
    const where = d.file + ":" + d.line + " " + d.type
    const readOnly = own(d, "readOnly")
    if (forbidden.has(d.type)) problems.push(where + " has an editable field inside")
    if (/^(SpinBox|ComboBox|DoubleSpinBox)$/.test(d.type) && own(d, "editable") !== undefined && own(d, "editable") !== "false")
      problems.push(where + " is editable")
    if (native.has(d.type) && readOnly !== "true") problems.push(where + " isn't readOnly: true (" + readOnly + ")")
    if (derived.has(d.type) && readOnly !== undefined && readOnly !== "true") problems.push(where + " sets readOnly: " + readOnly)
    if (derived.has(d.type) && (own(d, "Keys.onPressed") !== undefined || /(?:^|\n)\s*Keys\s*\{/.test(d.own)))
      problems.push(where + " handles Keys.onPressed, which runs after the field's editing: use onKeyPressed")
  }
  return { problems, derived, all }
}

function trackedQml() {
  const names = execFileSync("git", ["ls-files", "-z", "*.qml"], { cwd: root }).toString().split("\0").filter(Boolean)
  return Object.fromEntries(names.map(name => [name, fs.readFileSync(path.join(root, name), "utf8")]))
}

test("every text field is read-only to Qt, as a constant", () => {
  const files = trackedQml()
  const { problems, derived, all } = check(files)
  assert.deepEqual(problems, [])
  // It found them: GuardedField's own field and the setup window's line to copy.
  const natives = all.filter(d => native.has(d.type)).map(d => d.file + " " + d.type)
  assert.ok(natives.includes("GuardedField.qml TextField"), natives.join(", "))
  assert.ok(natives.includes("SetupView.qml TextEdit"), natives.join(", "))
  assert.ok(derived.has("GuardedField") && derived.has("SearchBox"), [...derived].join(", "))
})

test("the fields that are typed in are GuardedFields", () => {
  const files = trackedQml()
  const { derived, all } = check(files)
  const used = new Set(all.filter(d => derived.has(d.type)).map(d => d.file))
  for (const file of ["Panel.qml", "PlaylistPicker.qml", "YearPicker.qml", "SettingsView.qml", "SetupView.qml"])
    assert.ok(used.has(file), file + " has no GuardedField")
  assert.match(files["GuardedField.qml"], /\n {2}readOnly: true\n/)
  assert.match(files["GuardedField.qml"], /ContextMenu\.menu: null/)
})

test("the check catches what it's for", () => {
  const caught = source => check({ "Bad.qml": source }).problems
  assert.equal(caught("Item {\n  TextField {\n    text: \"x\"\n  }\n}").length, 1)
  assert.equal(caught("Item { Ui.TextField { readOnly: !activeFocus } }").length, 1)
  assert.equal(caught("Item { TextInput { readOnly: false } }").length, 1)
  assert.equal(caught("Item { TextEdit { readOnly: true } }").length, 0)
  assert.equal(caught("Item { TextArea {\n  readOnly: true\n  Rectangle { readOnly: false }\n} }").length, 0)
  assert.equal(caught("Item { TextArea {\n  Rectangle { readOnly: true }\n} }").length, 1)
  assert.equal(caught("Item {\n  // TextField {\n  Text { text: \"TextField\" }\n}").length, 0)
  assert.equal(caught("Item { FilterInput {} }").length, 1)
  assert.equal(caught("Item { ComboBox { editable: true } }").length, 1)
  // A type of the repo's own, made from a field.
  const files = {
    "GuardedField.qml": "Ui.TextField {\n  readOnly: true\n}",
    "Use.qml": "Item {\n  component Box: GuardedField { id: f }\n  Box { readOnly: false }\n"
      + "  GuardedField { Keys.onPressed: function(event) {} }\n  GuardedField { onKeyPressed: function(event) {} }\n}",
    "Loose.qml": "TextField {\n  placeholderText: \"x\"\n}"
  }
  const { problems } = check(files)
  assert.equal(problems.length, 3, problems.join("\n"))
  assert.ok(problems.some(p => p.startsWith("Use.qml:3 Box sets readOnly")))
  assert.ok(problems.some(p => p.startsWith("Use.qml:4 GuardedField handles Keys.onPressed")))
  assert.ok(problems.some(p => p.startsWith("Loose.qml:1 TextField isn't readOnly")))
})
