#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.recorrido.cloudflare-generation-worker"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$HOME/.hermes/scripts/recorrido_cloudflare_generation_worker.py"
HEALTHCHECK="$HOME/.hermes/scripts/recorrido_cloudflare_generation_healthcheck.py"
ENV_FILE="$HOME/.config/recorrido/cloudflare-generation.env"
PYTHON="/opt/homebrew/bin/python3.12"
GENERATOR="/Users/AIAgenterminal/recorrido/scripts/generate_recorrido_v16_batch.py"

if [ ! -x "$PYTHON" ]; then
  echo "trusted Python 3.12 missing: $PYTHON" >&2
  exit 1
fi
if ! "$PYTHON" "$GENERATOR" --help >/dev/null 2>&1; then
  echo "trusted Recorrido renderer import preflight failed" >&2
  exit 1
fi

mkdir -p "$HOME/.hermes/scripts" "$HOME/.hermes/logs" "$HOME/.hermes/runtime/recorrido-cloudflare-generation" "$HOME/Library/LaunchAgents"
install -m 700 "$HERE/worker.py" "$SCRIPT"
install -m 700 "$HERE/healthcheck.py" "$HEALTHCHECK"
install -m 600 "$HERE/$LABEL.plist" "$PLIST"

case "${1:-}" in
  --enable)
    if [ ! -f "$ENV_FILE" ] || [ "$(stat -f '%Lp' "$ENV_FILE")" != "600" ]; then
      echo "protected env file missing or not mode 600: $ENV_FILE" >&2
      exit 1
    fi
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl kickstart -k "$DOMAIN/$LABEL"
    ;;
  --disable)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    ;;
  "")
    echo "installed but disabled: $PLIST"
    ;;
  *)
    echo "usage: $0 [--enable|--disable]" >&2
    exit 2
    ;;
esac
