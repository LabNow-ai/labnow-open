#!/usr/bin/env bash
# Starts Hermes with a RuntimeSecretFile only while LabNow managed config exists.
set -euo pipefail

readonly HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
readonly HERMES_MANAGED_DIR="${HERMES_MANAGED_DIR:-${HERMES_HOME}/labnow-model-access}"
readonly HERMES_MANAGED_CONFIG="${HERMES_MANAGED_DIR}/config.yaml"
RUNTIME_SECRET_PATH="/run/labnow/model-access/secret.json"
HERMES_START_BIN="/usr/local/bin/start-hermes.sh"
# Isolated host tests may substitute paths and the upstream launcher. Production
# always uses the fixed RC1 mount and the upstream executable above.
if [ "${LABNOW_ALLOW_TEST_PATHS:-}" = "1" ]; then
  RUNTIME_SECRET_PATH="${LABNOW_RUNTIME_SECRET_PATH:-$RUNTIME_SECRET_PATH}"
  HERMES_START_BIN="${LABNOW_HERMES_START_BIN:-$HERMES_START_BIN}"
fi

die() {
  printf '%s\n' "start-labnow-hermes: $1" >&2
  exit "${2:-1}"
}

if [ -e "$HERMES_MANAGED_CONFIG" ]; then
  [ -f "$HERMES_MANAGED_CONFIG" ] && [ ! -L "$HERMES_MANAGED_CONFIG" ] || die "SECURE_MANAGED_CONFIG_REQUIRED" 64
  [ -f "$RUNTIME_SECRET_PATH" ] && [ ! -L "$RUNTIME_SECRET_PATH" ] || die "RUNTIME_SECRET_REQUIRED" 68
  [ "$(stat -c '%a' "$RUNTIME_SECRET_PATH" 2>/dev/null || stat -f '%Lp' "$RUNTIME_SECRET_PATH")" = "400" ] || die "SECURE_SECRET_MODE_REQUIRED" 65
  api_key="$(jq -er '.api_key | strings | select(test("^[^[:space:]]+$"))' "$RUNTIME_SECRET_PATH")" || die "INVALID_SECRET" 68
  export OPENAI_API_KEY="$api_key"
fi

export HERMES_HOME HERMES_MANAGED_DIR
exec "$HERMES_START_BIN" "$@"
