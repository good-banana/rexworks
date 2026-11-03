# md-viewer

`md-viewer` lets you preview Markdown files in a dedicated pane in Rex. Click a Markdown path in any Rex pane and a rendered preview opens in a pane beside it. md-viewer lays out and draws each page itself, then shows it in the terminal using the kitty graphics protocol. Its colors follow your Rex theme automatically, including when you switch themes or between light and dark.

<p>
  <img src="docs/preview-dark.png" alt="md-viewer preview in a dark terminal theme" width="49%">
  <img src="docs/preview-light.png" alt="md-viewer preview in a light terminal theme" width="49%">
</p>

## Features

- **Click to preview.** Click any Markdown path in any Rex pane, from `ls`, `git status`, a build log or a coding agent's reply, and the rendered page opens beside it. Click another and it opens in its own pane.
- **Real typography in the terminal.** Proportional fonts, true heading sizes, tables with header rows, syntax-highlighted code, task lists, footnotes, GitHub alerts like `[!NOTE]` and `[!WARNING]`, and frontmatter shown as a compact table.
- **Everything GitHub renders.** GitHub Flavored Markdown, the same safe HTML GitHub allows (centered logos, `<details>` sections, light and dark `<picture>` variants, side-by-side images), Mermaid diagrams, animated GIFs, SVGs and inline images.
- **A document, not a picture.** Select and copy text, copy code blocks with one click, find with `/` or Cmd-F, follow links and anchors with back and forward history, scroll wide code and tables sideways, and zoom.
- **Matches your Rex theme.** Every color comes from your current Rex theme and updates when you switch themes or between light and dark.
- **Stays in sync.** The preview reloads when the file changes and keeps your place, so you can watch a plan or README update as you or an agent edits it.
- **Works with coding agents.** One command teaches Claude Code, Codex, Pi, OpenCode, the Devin CLI and cursor-agent to open the Markdown they write for you in a preview.
- **Leaves everything else alone.** Markdown files opened from Finder or any other app still open in your usual editor.

## Requirements

- macOS 14 or later
- Rex
- Xcode Command Line Tools with Swift 6 (Xcode 16 or later CLT). The formula builds from source.

## Install

```
brew install good-banana/rexworks/md-viewer && md-viewer setup
```

`md-viewer setup` installs the background handler app and makes it the default handler for Markdown files when you click them in Rex. Clicking a Markdown file in any other app will open it in your normal default Markdown app.

`md-viewer setup` also adds a Cmd-F binding to your Rex config (`~/.config/rex/init.lua`, or the file `REX_CONFIG` names). It opens md-viewer's find in a preview pane and keeps Rex's normal Find everywhere else.

`md-viewer setup` installs a copy of the handler app, so rerun `md-viewer setup` after `brew upgrade md-viewer`.

## How it works

- A click on a Markdown path in a Rex pane opens the preview beside that pane.
- Opens from any other app are forwarded to the Markdown app you used before running `md-viewer setup`.

## Agents

Coding agents can open Markdown deliverables in a Rex preview pane. Run:

```
md-viewer agents install
```

This writes a small skill into each supported agent's skills directory, only where that agent is already installed:

| Directory | Agents |
| --- | --- |
| `~/.claude/skills/md-viewer/` | Claude Code |
| `~/.agents/skills/md-viewer/` | Codex, Pi, OpenCode, Devin CLI |
| `~/.cursor/skills/md-viewer/` | cursor-agent |

The skill tells the agent to run `md-viewer open FILE` after it writes or substantially updates a Markdown file for you. The preview opens beside the pane focused in Rex and reuses that tab's preview. The guidance ships in the binary (`md-viewer agent-guide`), so upgrading md-viewer updates it without rewriting the skill.

`md-viewer agents status` shows each directory as current, outdated, missing, skipped or foreign. `md-viewer agents remove` deletes only skills that md-viewer installed. `md-viewer setup` offers to install them, and `md-viewer uninstall` removes them.

## Commands

### Setup
```
md-viewer setup
```
macOS may ask you to confirm the change of default app for Markdown files.

### Doctor
```
md-viewer doctor
```
`md-viewer doctor` diagnoses the installation: handler app, highlighting and diagram resource bundles, and default handler registration.

The handler log is at `~/Library/Application Support/md-viewer/handler.log`.

### View Files
```
md-viewer view <file>
```

### Open Files
```
md-viewer open <file>
```

### Uninstall
```
md-viewer uninstall && brew uninstall md-viewer
```
`md-viewer uninstall` removes the handler app, restores the previous Markdown handler and removes the Cmd-F binding from your Rex config. macOS may ask you to confirm the change of default app for Markdown files.

## Settings

By default each file gets its own preview pane. To keep a single preview per tab that switches to each file you open, add `"previews": "single"` to `~/Library/Application Support/md-viewer/config.json`. Set it to `"perFile"`, or remove it, for one preview per file again.

## Mouse

- Wheel scrolls. Shift+wheel or a sideways swipe scrolls a wide code block or table.
- Click follows a link, opens or closes a details section, or copies a code block with its Copy button.
- Drag selects text. Double-click selects a word, and triple-click selects a paragraph, list item or table cell.

<p>
  <img src="docs/copy-code-block.gif" alt="Clicking the Copy button on a code block in md-viewer copies the code" width="100%">
</p>

## Links

- Links to other Markdown files open in the preview. Backspace goes back.
- Web and mailto links open in your browser or mail app.
- Links to local files open only when the target is an image, audio or video, a PDF, or plain text. Scripts, apps, HTML, and SVG are blocked.

## Keys

| Key | Action |
| --- | --- |
| j, Down | Scroll down |
| k, Up | Scroll up |
| d | Scroll down half a page |
| u | Scroll up half a page |
| Space, Page Down | Scroll down a page |
| b, Page Up | Scroll up a page |
| g, Home | Top |
| G, End | Bottom |
| Tab, Shift-Tab | Focus the next or previous link, details section, code block or wide table |
| h, l, Left, Right | Scroll the focused code block or table sideways |
| Enter | Follow the focused link, open or close the focused details section, or copy the focused code block |
| c | Copy the focused code block |
| Esc | Close find, then clear the selection, then clear focus |
| Backspace, h | Go back |
| L, Shift-Backspace | Go forward |
| /, Cmd-F | Find (Cmd-F works through the Rex binding that `md-viewer setup` installs) |
| n, N | Next or previous match |
| y, Cmd-C | Copy the selection as plain text |
| Y | Copy the selection as Markdown |
| Cmd-A | Select everything |
| +, -, 0 | Zoom in, zoom out, reset zoom |
| r | Refresh: reload the file and re-read the theme |
| ? | Show all keys and mouse actions |
| q, Ctrl-Q, Ctrl-C | Quit |

## Credits

Vendored libraries and their licenses are listed in `Sources/MDViewerRender/Resources/THIRD_PARTY_NOTICES` (highlight.js) and `Sources/MDViewerMermaid/Resources/mermaid/THIRD_PARTY_NOTICES` (mermaid).

## Releasing

1. Tag with `git tag md-viewer-vX.Y.Z`, then push the commit and the tag to `good-banana/rexworks`.
2. Run `md-viewer/scripts/release.sh X.Y.Z`. It downloads the tag archive, computes its SHA-256, and writes `homebrew-rexworks/Formula/md-viewer.rb`.
3. Commit and push the `homebrew-rexworks` repository.

To test the formula before tagging, run `md-viewer/scripts/release.sh --local X.Y.Z`. It builds a tarball from `HEAD` and writes a formula with a `file://` URL to `$TMPDIR/md-viewer.rb`. That formula is for local testing only.
