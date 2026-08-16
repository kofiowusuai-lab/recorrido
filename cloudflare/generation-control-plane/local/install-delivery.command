#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.recorrido.customer-delivery-worker"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$HOME/.hermes/scripts/recorrido_customer_delivery_worker.py"
ENV_FILE="$HOME/.config/recorrido/cloudflare-generation.env"
PYTHON="/opt/homebrew/bin/python3.12"

[ -x "$PYTHON" ] || { echo "trusted Python missing: $PYTHON" >&2; exit 1; }
[ -f "$ENV_FILE" ] && [ "$(stat -f '%Lp' "$ENV_FILE")" = "600" ] || { echo "protected env file missing or not mode 600: $ENV_FILE" >&2; exit 1; }
mkdir -p "$HOME/.hermes/scripts" "$HOME/.hermes/logs" "$HOME/.hermes/runtime/recorrido-customer-delivery" "$HOME/Library/LaunchAgents"
install -m 700 "$HERE/delivery_worker.py" "$SCRIPT"
install -m 600 "$HERE/$LABEL.plist" "$PLIST"
wait_for_unload() {
  for ((attempt=0; attempt<40; attempt++)); do
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  echo "delivery worker did not unload: $DOMAIN/$LABEL" >&2; return 1
}
case "${1:-}" in
  --enable)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; wait_for_unload
    launchctl bootstrap "$DOMAIN" "$PLIST"; launchctl kickstart -k "$DOMAIN/$LABEL" ;;
  --disable)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; wait_for_unload ;;
  "") echo "installed but disabled: $PLIST" ;;
  *) echo "usage: $0 [--enable|--disable]" >&2; exit 2 ;;
esac
