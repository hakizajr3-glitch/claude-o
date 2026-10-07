#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 path/to/file.mq5 [extra MetaEditor args...]" >&2
  exit 64
fi

SOURCE_PATH="$1"
shift

if [[ ! -f "$SOURCE_PATH" ]]; then
  echo "Source file not found: $SOURCE_PATH" >&2
  exit 66
fi

if ! command -v wine >/dev/null 2>&1; then
  echo "wine is not installed. Run scripts/install_mql5_linux.sh first." >&2
  exit 69
fi

METAEDITOR_PATH="${METAEDITOR_PATH:-}"
if [[ -z "$METAEDITOR_PATH" ]]; then
  METAEDITOR_PATH="$(find "$HOME" -iname 'metaeditor64.exe' -o -iname 'metaeditor.exe' 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$METAEDITOR_PATH" || ! -f "$METAEDITOR_PATH" ]]; then
  echo "MetaEditor executable was not found. Set METAEDITOR_PATH or run scripts/install_mql5_linux.sh first." >&2
  exit 69
fi

LOG_PATH="${MQL5_COMPILE_LOG:-${SOURCE_PATH%.*}.compile.log}"
WINDOWS_SOURCE_PATH="$(winepath -w "$(realpath "$SOURCE_PATH")")"
WINDOWS_LOG_PATH="$(winepath -w "$(realpath -m "$LOG_PATH")")"

wine "$METAEDITOR_PATH" /compile:"$WINDOWS_SOURCE_PATH" /log:"$WINDOWS_LOG_PATH" "$@"

if [[ -f "$LOG_PATH" ]]; then
  cat "$LOG_PATH"
fi

if [[ ! -f "${SOURCE_PATH%.*}.ex5" ]]; then
  echo "Compilation did not produce ${SOURCE_PATH%.*}.ex5. Check $LOG_PATH for details." >&2
  exit 1
fi
