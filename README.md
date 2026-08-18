# Obsidian Quick Note

Quick-edit an Obsidian note straight from the Omarchy bar. One click opens a
popup with a searchable note picker and a plain text editor — write a line,
hit `Ctrl+S`, close.

No external dependencies. Notes are plain `.md` files read and written in
place (atomic writes), so Obsidian itself picks the changes up.

## Features

- Bar icon opens the popup; the last-edited note opens directly on next click
- Searchable note list (scans the vault for `*.md`, skips dot-folders)
- Notational-velocity style create-on-search: type a name that doesn't match
  any existing note and a "Create note" entry appears in the list — press
  Enter or click it to jump straight into a blank editor. Nothing is written
  to disk until you actually save, so an unused create just disappears.
  Typing `Projects/todo` creates the note inside a `Projects` subfolder.
- Multi-line editor: `Ctrl+S` saves, `Esc` saves and closes, unsaved changes
  are warned about, saves are confirmed with a "Saved" flash
- Vault auto-detection: with no vault configured, common locations
  (`~/Documents`, `~/Notes`, `~/Obsidian`, shallow `$HOME` sweep) are scanned
  for an `.obsidian` marker
- Vault path can be typed directly in the panel — it gets pinned to your
  config on use, so nothing is hardcoded and detection only runs as a fallback
- Clicking a note from a detected vault pins the vault too

## Install

```bash
omarchy plugin add https://github.com/mykcib/omarchy-obsidian-quickedit --enable --yes
omarchy bar move mykcib.obsidian-quickedit --section right
```

## Configuration

Both settings are optional and empty by default.

| Setting | Meaning |
| --- | --- |
| `vaultPath` | Absolute path to your Obsidian vault, e.g. `~/Documents/MyVault`. When empty, the plugin tries to detect one. |
| `notePath` | Note to open by default, relative to the vault without the `.md` suffix (e.g. `Inbox/todo`). Leave empty to always land on the picker. |

The vault path can also be typed straight into the popup (input field at the
top of the picker, or the footer's **Change** button once pinned) — it is
persisted to the widget's settings immediately.

## Usage

1. Click the icon in the bar.
2. Search for a note or press Enter on the highlighted one. If nothing
   matches, press Enter (or click "Create note …") to start a new one at
   that name.
3. Edit; `Ctrl+S` saves, `Esc` closes (saving any pending edits).
4. The back arrow in the editor header returns to the picker.

## Removal

```bash
omarchy plugin remove mykcib.obsidian-quickedit --yes
```

## License

MIT — see [LICENSE](LICENSE).
