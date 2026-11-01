# md-viewer

Preview Markdown files from Rex terminal panes. Click a Markdown path in any Rex pane and a WebKit-rendered preview opens in a pane beside it. The preview is drawn in the terminal using the kitty graphics protocol.

## Requirements

- macOS 14 or later
- Rex
- Xcode Command Line Tools (the formula builds from source)

## Install

```
brew install good-banana/rexworks/md-viewer
md-viewer setup
```

`md-viewer setup` installs the background handler app and makes it the default handler for Markdown files.

## How routing works

- A click on a Markdown path in a Rex pane opens the preview beside that pane.
- Opens from any other app are forwarded to the Markdown app you used before running `md-viewer setup`.

## Keys

| Key | Action |
| --- | --- |
| j, Down | Scroll down a line |
| k, Up | Scroll up a line |
| d | Scroll down half a page |
| u | Scroll up half a page |
| Space, Page Down | Scroll down a page |
| b, Page Up | Scroll up a page |
| g, Home | Top |
| G, End | Bottom |
| r | Reload |
| Tab, Shift-Tab | Focus next or previous link |
| Enter | Follow the focused link |
| Esc | Clear link focus |
| Backspace, h | Go back |
| / | Search |
| n, N | Next or previous match |
| q, Ctrl-Q, Ctrl-C | Quit |

## Mouse

- Wheel scrolls.
- Click follows a link.

## Local file links

Links to local files open only when the target is an image, audio or video, a PDF, or plain text. Scripts, apps, HTML, and SVG are blocked.

## Commands

```
md-viewer view <file>
md-viewer open <file>
md-viewer setup
md-viewer uninstall
md-viewer doctor
```

`md-viewer doctor` diagnoses the installation: handler app, web resources, and default handler registration.

The handler log is at `~/Library/Application Support/md-viewer/handler.log`.

## Uninstall

```
md-viewer uninstall
brew uninstall md-viewer
```

`md-viewer uninstall` removes the handler app and restores the previous Markdown handler.

## Credits

Inspired by [rex-markdown](https://github.com/jal-co/jalco-dotfiles/tree/main/tools/rex-markdown) by jal-co.

Vendored web libraries and their licenses are listed in `Sources/MDViewerWeb/Resources/web/THIRD_PARTY_NOTICES`.

## Releasing

1. Tag with `git tag md-viewer-vX.Y.Z`, then push the commit and the tag to `good-banana/rexworks`.
2. Run `md-viewer/scripts/release.sh X.Y.Z`. It downloads the tag archive, computes its SHA-256, and writes `homebrew-rexworks/Formula/md-viewer.rb`.
3. Commit and push the `homebrew-rexworks` repository.

To test the formula before tagging, run `md-viewer/scripts/release.sh --local X.Y.Z`. It builds a tarball from `HEAD` and writes a formula with a `file://` URL to `$TMPDIR/md-viewer.rb`. That formula is for local testing only.
