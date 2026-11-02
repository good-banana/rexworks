#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
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

fetch @highlightjs/cdn-assets@11.11.1/highlight.min.js \
  highlight.min.js c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381
fetch mermaid@11.17.2/dist/mermaid.min.js \
  mermaid.min.js 581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8

cp "$staging/highlight.min.js" "$root/Sources/MDViewerRender/Resources/highlight.min.js"
cp "$staging/mermaid.min.js" "$root/Sources/MDViewerMermaid/Resources/mermaid/mermaid.min.js"
echo "vendored highlight.js and mermaid"
