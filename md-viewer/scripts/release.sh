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

cat > "$formula" <<RUBY
class MdViewer < Formula
  desc "Preview Markdown files clicked in Rex terminal panes"
  homepage "https://github.com/good-banana/rexworks/tree/main/md-viewer"
  url "$url"
  sha256 "$sha"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    cd "md-viewer" do
      system "swift", "build", "--disable-sandbox", "-c", "release"
      bin.install ".build/release/md-viewer"
      libexec.install ".build/release/md-viewer_MDViewerWeb.bundle"
      system "scripts/build-app.sh", ".build/release/MDViewerHandler", version.to_s, libexec
    end
  end

  def caveats
    <<~EOS
      Make md-viewer the handler for Markdown files clicked in Rex:
        md-viewer setup
      Opens from other apps go to your previous Markdown app.
      To undo: md-viewer uninstall
    EOS
  end

  test do
    assert_match "Usage", shell_output("#{bin}/md-viewer --help")
  end
end
RUBY

echo "wrote $formula"
