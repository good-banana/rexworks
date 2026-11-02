#!/bin/sh
set -eu

usage() {
  echo "usage: release.sh [--local] <version>" >&2
  exit 64
}

local_mode=0
if [ "${1:-}" = "--local" ]; then
  local_mode=1
  shift
fi
[ "$#" -eq 1 ] || usage

version=$1
case "$version" in
  *[!0-9.]* | "") usage ;;
esac

root=$(cd "$(dirname "$0")/../.." && pwd)
declared=$(sed -n 's/^public let mdViewerVersion = "\(.*\)"$/\1/p' "$root/md-viewer/Sources/MDViewerCore/Version.swift")
if [ "$declared" != "$version" ]; then
  echo "Version.swift declares $declared; update it to $version and commit before releasing." >&2
  exit 1
fi
tag="md-viewer-v$version"
prefix="rexworks-$tag"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$local_mode" -eq 1 ]; then
  tarball="$work/$tag.tar.gz"
  git -C "$root" archive --format=tar.gz --prefix="$prefix/" -o "$tarball" HEAD
  stable="${TMPDIR:-/tmp}/$tag.tar.gz"
  cp "$tarball" "$stable"
  url="file://$stable"
  formula="${TMPDIR:-/tmp}/md-viewer.rb"
else
  url="https://github.com/good-banana/rexworks/archive/refs/tags/$tag.tar.gz"
  tarball="$work/$tag.tar.gz"
  curl --fail --location --silent --show-error --output "$tarball" "$url"
  formula="$root/homebrew-rexworks/Formula/md-viewer.rb"
  mkdir -p "$(dirname "$formula")"
fi

sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)

manifest="$root/md-viewer/Package.swift"
cmark_line=$(grep -o '\.package(url: "https://github.com/swiftlang/swift-cmark", revision: "[0-9a-f]*")' "$manifest")
cmark_revision=$(printf '%s' "$cmark_line" | sed 's/.*revision: "\([0-9a-f]*\)".*/\1/')
if [ -z "$cmark_revision" ]; then
  echo "could not find the pinned swift-cmark revision in $manifest" >&2
  exit 1
fi
cmark_url="https://github.com/swiftlang/swift-cmark/archive/$cmark_revision.tar.gz"
curl --fail --location --silent --show-error --output "$work/swift-cmark.tar.gz" "$cmark_url"
cmark_sha=$(shasum -a 256 "$work/swift-cmark.tar.gz" | cut -d' ' -f1)

cat > "$formula" <<RUBY
class MdViewer < Formula
  desc "Preview Markdown files clicked in Rex terminal panes"
  homepage "https://github.com/good-banana/rexworks/tree/main/md-viewer"
  url "$url"
  sha256 "$sha"

  depends_on macos: :sonoma

  resource "swift-cmark" do
    url "$cmark_url"
    sha256 "$cmark_sha"
  end

  def install
    swift_major = Utils.safe_popen_read("swift", "--version")[/Swift version (\d+)/, 1].to_i
    if swift_major < 6
      odie "md-viewer needs Swift 6 or later. Install Xcode 16 or later Command Line Tools: xcode-select --install"
    end
    resource("swift-cmark").stage(buildpath/"swift-cmark")
    cd "md-viewer" do
      inreplace "Package.swift", '$cmark_line', '.package(path: "../swift-cmark")'
      rm "Package.resolved"
      system "swift", "build", "--disable-sandbox", "-c", "release"
      bin.install ".build/release/md-viewer"
      libexec.install ".build/release/md-viewer_MDViewerRender.bundle"
      libexec.install ".build/release/md-viewer_MDViewerMermaid.bundle"
      system "scripts/build-app.sh", ".build/release/MDViewerHandler", version.to_s, libexec
    end
  end

  def caveats
    <<~EOS
      Make md-viewer the handler for Markdown files clicked in Rex:
        md-viewer setup
      Opens from other apps go to your previous Markdown app.
      After brew upgrade md-viewer, rerun md-viewer setup to update the installed app.
      To undo: md-viewer uninstall
    EOS
  end

  test do
    assert_match "Usage", shell_output("#{bin}/md-viewer --help")
    assert_match version.to_s, shell_output("#{bin}/md-viewer --version")
  end
end
RUBY

echo "wrote $formula"
