#!/usr/bin/env bash
set -euo pipefail

# Installs the Linux-hosted MetaTrader 5 toolchain used to compile MQL5 files.
# MetaEditor is a Windows executable, so Linux compilation is performed through Wine.
# The official MetaQuotes Linux installer script installs Wine and MetaTrader 5.

MT5_INSTALLER_URL="${MT5_INSTALLER_URL:-https://download.terminal.free/cdn/web/metaquotes.software.corp/mt5/mt5linux.sh}"
INSTALLER_PATH="${TMPDIR:-/tmp}/mt5linux.sh"

if command -v wine >/dev/null 2>&1 && find "$HOME" -iname 'metaeditor*.exe' -print -quit 2>/dev/null | grep -q .; then
  echo "MetaTrader/MetaEditor appears to already be installed under $HOME."
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  echo "Installing Wine dependencies with apt-get..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    wine64 xvfb cabextract winbind
fi

echo "Downloading official MetaTrader 5 Linux installer from: $MT5_INSTALLER_URL"
curl -L --fail --retry 3 --connect-timeout 30 -o "$INSTALLER_PATH" "$MT5_INSTALLER_URL"
chmod +x "$INSTALLER_PATH"

echo "Running MetaTrader 5 installer. Follow any Wine/MetaTrader prompts that appear."
"$INSTALLER_PATH"
