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
declared=$(sed -n 's/^public let sideclickVersion = "\(.*\)"$/\1/p' "$root/sideclick/Sources/SideclickCore/Version.swift")
if [ "$declared" != "$version" ]; then
  echo "Version.swift declares $declared; update it to $version and commit before releasing." >&2
  exit 1
fi
tag="sideclick-v$version"
prefix="rexworks-$tag"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$local_mode" -eq 1 ]; then
  tarball="$work/$tag.tar.gz"
  tar -C "$root" -czf "$tarball" -s "|^sideclick|$prefix/sideclick|" --exclude .build --exclude .swiftpm sideclick
  stable="${TMPDIR:-/tmp}/$tag.tar.gz"
  cp "$tarball" "$stable"
  url="file://$stable"
  formula="${TMPDIR:-/tmp}/sideclick.rb"
else
  url="https://github.com/good-banana/rexworks/archive/refs/tags/$tag.tar.gz"
  tarball="$work/$tag.tar.gz"
  curl --fail --location --silent --show-error --output "$tarball" "$url"
  formula="$root/homebrew-rexworks/Formula/sideclick.rb"
  mkdir -p "$(dirname "$formula")"
fi

sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)

cat > "$formula" <<RUBY
class Sideclick < Formula
  desc "Cmd-click web links in Rex to open them in a browser pane beside you"
  homepage "https://github.com/good-banana/rexworks/tree/main/sideclick"
  url "$url"
  sha256 "$sha"

  depends_on macos: :sonoma

  def install
    swift_major = Utils.safe_popen_read("swift", "--version")[/Swift version (\d+)/, 1].to_i
    if swift_major < 6
      odie "sideclick needs Swift 6 or later. Install Xcode 16 or later Command Line Tools: xcode-select --install"
    end
    cd "sideclick" do
      system "swift", "build", "--disable-sandbox", "-c", "release"
      bin.install ".build/release/sideclick"
      system "scripts/build-app.sh", ".build/release/SideclickHandler", version.to_s, libexec
    end
  end

  def caveats
    <<~EOS
      Make Cmd-clicked web links in Rex open in a browser pane:
        sideclick setup
      Setup checks for terminal-browser and offers to install it.
      Cmd+Option-click, and links from other apps, go to your previous browser.
      After brew upgrade sideclick, rerun sideclick setup to update the installed app.
      To undo: sideclick uninstall
    EOS
  end

  test do
    assert_match "Usage", shell_output("#{bin}/sideclick --help")
    assert_match version.to_s, shell_output("#{bin}/sideclick --version")
  end
end
RUBY

echo "wrote $formula"
