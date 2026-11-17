#!/usr/bin/env bash
# Build the release tarballs for Linux and macOS from this repo. Usage: scripts/package.sh linux|macos <input-binary> <out-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
kind=$1; bin=$2; out=$3
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
install -m 755 "$bin" "$stage/recpill"
cp LICENSE "$stage/LICENSE"
case "$kind" in
  linux)
    cp linux/desktop/recpill-start.desktop linux/desktop/recpill-stop.desktop linux/desktop/recpill-toggle.desktop linux/recpill.png "$stage/"
    tar -czf "$out/recpill-linux.tar.gz" -C "$stage" .
    ;;
  macos)
    tar -czf "$out/recpill-macos.tar.gz" -C "$stage" .
    ;;
  *) echo "unknown kind $kind" >&2; exit 2 ;;
esac
echo "wrote $out"
