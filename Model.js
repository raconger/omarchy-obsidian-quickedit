// Pure helpers for the Obsidian quick note panel. Qt-free so the QML stays
// thin; the vault scan itself is a bash `find` via a Quickshell Process,
// because Quickshell.Io has no directory-listing API.
// Expand ~/ and $HOME/ prefixes; everything else is taken as-is so absolute
// and already-literal paths pass through unchanged.
function expandPath(value, home) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  if (text === "") return ""
  if (text.indexOf("~/") === 0) return home + text.substring(1)
  if (text.indexOf("$HOME/") === 0) return home + text.substring(6)
  return text
}

// Relative path of `full` inside `vaultPath`; when the file lives outside the
// vault, keep the caller's path untouched (the panel treats a leading "/" as
// an absolute path).
function toRel(vaultPath, full) {
  var v = String(vaultPath || "").replace(/\/+$/, "")
  var f = String(full || "")
  if (v !== "" && f === v) return ""
  var prefix = v + "/"
  if (v !== "" && f.indexOf(prefix) === 0) return f.substring(prefix.length)
  return f
}

function joinPath(vaultPath, rel) {
  var v = String(vaultPath || "").replace(/\/+$/, "")
  var r = String(rel || "")
  if (r === "") return v
  if (r.charAt(0) === "/") return r
  return v === "" ? r : v + "/" + r
}

// The scan prints one relative path per line ("find . -type f -name '*.md'").
// Drop the "./" prefix and dot-folders (.obsidian, .trash, .git, ...).
function parseNotes(raw, vaultPath) {
  var out = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var rel = lines[i].replace(/^\s+|\s+$/g, "")
    if (rel === "") continue
    if (rel.indexOf("./") === 0) rel = rel.substring(2)
    if (rel === "") continue
    var top = rel.split("/")[0]
    if (top.length > 0 && top.charAt(0) === ".") continue
    out.push({ rel: rel, label: rel.replace(/\.md$/i, ""), path: joinPath(vaultPath, rel) })
  }
  return out
}

// Case-insensitive substring match against the note label (the relative path
// without the .md suffix).
function filterNotes(notes, query) {
  var q = String(query || "").toLowerCase().trim()
  var out = []
  for (var i = 0; i < notes.length; i++) {
    if (q === "" || notes[i].label.toLowerCase().indexOf(q) !== -1) out.push(notes[i])
  }
  return out
}

// Notes that live directly in the vault, not inside a subfolder — the
// default browse view before anything is typed.
function rootNotes(notes) {
  var out = []
  for (var i = 0; i < notes.length; i++) {
    if (notes[i].rel.indexOf("/") === -1) out.push(notes[i])
  }
  return out
}

// One virtual, collapsed row per top-level subfolder that holds at least one
// note, sorted reverse-alphabetically (same convention as the note list) so
// they sit at the bottom of the browse view under the root notes. Activating
// a folder row fills the search box with "<name>/", which the ordinary
// recursive filter below turns into "show everything in this folder".
function folderRows(notes) {
  var seen = {}
  var names = []
  for (var i = 0; i < notes.length; i++) {
    var slash = notes[i].rel.indexOf("/")
    if (slash === -1) continue
    var top = notes[i].rel.substring(0, slash)
    if (seen[top]) continue
    seen[top] = true
    names.push(top)
  }
  names.sort()
  names.reverse()
  var out = []
  for (var j = 0; j < names.length; j++) {
    out.push({ rel: "", label: names[j] + "/", isFolder: true, folderQuery: names[j] + "/" })
  }
  return out
}

// True when `notes` already has an entry whose label (rel path minus .md)
// case-insensitively equals `query` — used to decide whether typed text is
// a real note (open it) or a new one (offer to create it).
function hasExactMatch(notes, query) {
  var q = String(query || "").toLowerCase().trim()
  if (q === "") return false
  for (var i = 0; i < notes.length; i++) {
    if (notes[i].label.toLowerCase() === q) return true
  }
  return false
}

// Turn free-typed picker text into a vault-relative note name: trim, allow
// "/" for subfolders (matching how existing notes already display their
// relative path), drop a trailing ".md" the user typed themselves, and
// refuse anything that would escape the vault ("..", empty segments).
// Empty return means "not a valid note name" — no create option offered.
function sanitizeNewNoteName(raw) {
  var text = String(raw || "").trim()
  if (text === "") return ""
  text = text.replace(/\\/g, "/").replace(/\/+/g, "/").replace(/^\/+|\/+$/g, "")
  text = text.replace(/\.md$/i, "")
  if (text === "") return ""
  var parts = text.split("/")
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return ""
  }
  return parts.join("/")
}

// The virtual "Create note" row appended to the picker list when the typed
// text doesn't match an existing note. Null when there's nothing sensible
// to create (empty/invalid name, or a note by that name already exists).
function makeCreateRow(rawQuery, notes) {
  var clean = sanitizeNewNoteName(rawQuery)
  if (clean === "") return null
  if (hasExactMatch(notes, clean)) return null
  return { rel: clean + ".md", label: "Create note \"" + clean + "\"", isCreate: true }
}

// lines like "/home/user/Documents/notes/.obsidian" -> "/home/user/Documents/notes".
// Sort keeps the most predictable candidate (Documents first) at the front.
function parseVaultCandidates(raw) {
  var seen = {}
  var out = []
  var lines = String(raw || "").split("\n")
  var marker = "/.obsidian"
  for (var i = 0; i < lines.length; i++) {
    var p = lines[i].replace(/^\s+|\s+$/g, "")
    if (p === "") continue
    if (p.lastIndexOf(marker) === p.length - marker.length)
      p = p.substring(0, p.length - marker.length)
    p = p.replace(/\/+$/, "")
    if (p === "" || seen[p]) continue
    seen[p] = true
    out.push(p)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    expandPath: expandPath,
    toRel: toRel,
    joinPath: joinPath,
    parseNotes: parseNotes,
    filterNotes: filterNotes,
    rootNotes: rootNotes,
    folderRows: folderRows,
    hasExactMatch: hasExactMatch,
    sanitizeNewNoteName: sanitizeNewNoteName,
    makeCreateRow: makeCreateRow,
    parseVaultCandidates: parseVaultCandidates
  }
}
