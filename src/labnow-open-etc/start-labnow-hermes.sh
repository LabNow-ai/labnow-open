#!/usr/bin/env bash
# Starts Hermes under the Launcher-provided model access mode. The generated
# Hermes config contains a SecretRef, never a credential value.
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_LINK="$(readlink "$SCRIPT_PATH")"
  case "$SCRIPT_LINK" in
    /*) SCRIPT_PATH="$SCRIPT_LINK" ;;
    *) SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$SCRIPT_LINK" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LABNOW_ADAPTER_ID="hermes"
LABNOW_ADAPTER_VERSION="0.1.0-rc.1"
LABNOW_MANIFEST_PATH="/run/labnow/model-access/manifest.json"
LABNOW_SECRET_PATH="/run/labnow/model-access/secret.json"
LABNOW_STATUS_PATH="/run/labnow/model-access/status.json"
# shellcheck source=lib/model-access-adapter-common.sh
source "${SCRIPT_DIR}/lib/model-access-adapter-common.sh"

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
HERMES_MANAGED_DIR="${HERMES_MANAGED_DIR:-${HERMES_HOME}/labnow-model-access}"
HERMES_MANAGED_CONFIG="${HERMES_MANAGED_DIR}/config.yaml"
HERMES_BINDING_STATE="${HERMES_MANAGED_DIR}/state/binding.json"
HERMES_START_BIN="/usr/local/bin/start-hermes.sh"

hermes_model_access_action() {
  "${SCRIPT_DIR}/hermes-model-access-adapter.sh" "$1"
}

start_labnow_hermes() {
  local api_key
  case "${MODEL_ACCESS_MODE+x}:${MODEL_ACCESS_MODE:-}" in
    :*) labnow_die "MODEL_ACCESS_MODE_REQUIRED" ;;
    x:managed)
      labnow_validate_manifest
      labnow_validate_secret
      hermes_model_access_action apply
      hermes_model_access_action probe
      # Keep the key unexported until validation, apply and probe all pass;
      # exec limits it to the Hermes child environment, never argv or disk.
      api_key="$(jq -er '.api_key' "$LABNOW_SECRET_PATH")" || labnow_die "INVALID_SECRET"
      export OPENAI_API_KEY="$api_key"
      ;;
    x:unmanaged) ;;
    *) labnow_die "MODEL_ACCESS_MODE_INVALID" ;;
  esac
  export HERMES_HOME HERMES_MANAGED_DIR
  exec "$HERMES_START_BIN" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  start_labnow_hermes "$@"
fi
