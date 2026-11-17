#!/bin/sh
# RecPill installer for Linux and macOS. No root needed: installs into ~/.local.
#   curl -fsSL https://github.com/maxjustships/recpill/releases/latest/download/install.sh | sh
#   curl -fsSL https://github.com/maxjustships/recpill/releases/latest/download/install.sh | sh -s -- --uninstall
#
# Optional environment variables:
#   RECPILL_VERSION=v0.1.0   install a specific release (default: latest)
#   RECPILL_PREFIX=~/.local  install prefix
set -eu

REPO=maxjustships/recpill
PREFIX=${RECPILL_PREFIX:-$HOME/.local}
if [ -n "${RECPILL_BASE_URL:-}" ]; then
  BASE=$RECPILL_BASE_URL
elif [ -n "${RECPILL_VERSION:-}" ]; then
  BASE=https://github.com/$REPO/releases/download/$RECPILL_VERSION
else
  BASE=https://github.com/$REPO/releases/latest/download
fi

OS=$(uname -s)
case "$OS" in
  Linux)  ASSET=recpill-linux.tar.gz ;;
  Darwin) ASSET=recpill-macos.tar.gz ;;
  *) echo "RecPill supports Linux and macOS here (Windows: see the README)." >&2; exit 1 ;;
esac

APPS=$HOME/.local/share/applications
ICONS=$HOME/.local/share/icons/hicolor/128x128/apps

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  if [ -x "$PREFIX/bin/recpill" ]; then
    "$PREFIX/bin/recpill" status >/dev/null 2>&1 && { echo "A recording is in progress. Stop it first (recpill stop)." >&2; exit 1; }
  fi
  rm -f "$PREFIX/bin/recpill" "$APPS"/recpill-start.desktop "$APPS"/recpill-stop.desktop "$APPS"/recpill-toggle.desktop "$ICONS"/recpill.png
  [ -d "$APPS" ] && command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true
  echo "RecPill is uninstalled. Your recordings and config were not touched."
  exit 0
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 1; }; }
need curl
need tar

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "Downloading RecPill..."
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS"
WANT=$(grep " \*\{0,1\}$ASSET\$" "$TMP/SHA256SUMS" | awk '{print $1}' | head -n 1)
[ -n "$WANT" ] || { echo "SHA256SUMS has no entry for $ASSET" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then GOT=$(sha256sum "$TMP/$ASSET" | awk '{print $1}'); else GOT=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}'); fi
[ "$WANT" = "$GOT" ] || { echo "Checksum mismatch (expected $WANT, got $GOT). Nothing was installed." >&2; exit 1; }

tar -xzf "$TMP/$ASSET" -C "$TMP"
mkdir -p "$PREFIX/bin"
install -m 755 "$TMP/recpill" "$PREFIX/bin/recpill"

if [ "$OS" = "Linux" ]; then
  mkdir -p "$APPS" "$ICONS"
  for a in start stop toggle; do
    sed "s|@BIN@|$PREFIX/bin/recpill|g" "$TMP/recpill-$a.desktop" > "$APPS/recpill-$a.desktop"
  done
  install -m 644 "$TMP/recpill.png" "$ICONS/recpill.png"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true
  echo
  "$PREFIX/bin/recpill" doctor || echo "Install the missing tools above (Arch: pipewire-pulse ffmpeg libnotify; Debian/Ubuntu: pulseaudio-utils ffmpeg libnotify-bin)."
else
  command -v xattr >/dev/null 2>&1 && xattr -d com.apple.quarantine "$PREFIX/bin/recpill" 2>/dev/null || true
  echo
  echo "macOS build is a BETA and has not been tested on real hardware. It needs macOS 14.4 or newer."
fi

echo
echo "RecPill installed: $PREFIX/bin/recpill"
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "Add $PREFIX/bin to your PATH to run 'recpill' from the terminal." ;; esac
echo "Try it:  recpill start   ...   recpill stop"
echo "Uninstall:  curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | sh -s -- --uninstall"
