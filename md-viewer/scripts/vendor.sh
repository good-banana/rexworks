#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/Sources/MDViewerWeb/Resources/web/vendor"
cdn=https://cdn.jsdelivr.net/npm
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

fetch() {
  source=$1
  name=$2
  expected=$3
  curl -fsSL --proto '=https' "$cdn/$source" -o "$staging/$name"
  actual=$(shasum -a 256 "$staging/$name" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $source: expected $expected, got $actual" >&2
    exit 1
  fi
}

fetch markdown-it@14.3.3/dist/markdown-it.min.js \
  markdown-it.min.js 494ba53db1aac9f676317dda7062bd9545b5f0bbe3f12b0ab1ab4f813825cfb0
fetch markdown-it-footnote@4.0.0/dist/markdown-it-footnote.min.js \
  markdown-it-footnote.min.js d6fee58a3b56c5742fa18f3e01f1d317cc99975683ebd39c9195cb2aff0c2e42
fetch markdown-it-task-lists@2.1.1/dist/markdown-it-task-lists.min.js \
  markdown-it-task-lists.min.js 4f3b23f41bb3787957da2602fbccc4df0d017928c1fce62583159e096b832a81
fetch github-markdown-css@5.9.0/github-markdown-light.css \
  github-markdown-light.css de2d14b5290b8cf2af74c95e92560d9c00642ae72de0b856cece3e4eddb2d885
fetch github-markdown-css@5.9.0/github-markdown-dark.css \
  github-markdown-dark.css b45ead2db01f5856c4eb378f21f47da63f6b0ecf3be5d06385472164b7283df6
fetch @highlightjs/cdn-assets@11.11.1/highlight.min.js \
  highlight.min.js c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381
fetch @highlightjs/cdn-assets@11.11.1/styles/github.min.css \
  hljs-github.css 3a9a5def8b9c311e5ae43abde85c63133185eed4f0d9f67fea4b00a8308cf066
fetch @highlightjs/cdn-assets@11.11.1/styles/github-dark.min.css \
  hljs-github-dark.css 9f208d022102b1d0c7aebfecd8e42ca7997d5de636649d2b31ea63093d809019
fetch mermaid@11.17.2/dist/mermaid.min.js \
  mermaid.min.js 581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8

rm -rf "$dest"
mkdir -p "$dest"
cp "$staging"/* "$dest/"
echo "vendored into $dest"
