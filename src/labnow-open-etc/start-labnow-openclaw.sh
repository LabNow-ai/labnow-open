#!/usr/bin/env bash
# Starts the OpenClaw gateway at the LabNow workspace route.
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
LABNOW_ADAPTER_ID="openclaw"
LABNOW_ADAPTER_VERSION="0.1.0-rc.1"
LABNOW_MANIFEST_PATH="/run/labnow/model-access/manifest.json"
LABNOW_SECRET_PATH="/run/labnow/model-access/secret.json"
LABNOW_STATUS_PATH="/run/labnow/model-access/status.json"
# shellcheck source=lib/model-access-adapter-common.sh
source "${SCRIPT_DIR}/lib/model-access-adapter-common.sh"

readonly OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG:-/root/.openclaw/data/openclaw.json}"
readonly OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw/data}"
readonly OPENCLAW_GATEWAY_PORT="18789"

die() {
  printf '%s\n' "start-labnow-openclaw: $1" >&2
  exit "${2:-1}"
}

assert_regular_config_path() {
  [[ "$OPENCLAW_CONFIG_PATH" = /* && "$OPENCLAW_STATE_DIR" = /* ]] || labnow_die "SECURE_PATH_REQUIRED"
  labnow_ensure_trusted_directory "$OPENCLAW_STATE_DIR"
  labnow_assert_trusted_path "$OPENCLAW_STATE_DIR" "$OPENCLAW_CONFIG_PATH"
  [ ! -e "$OPENCLAW_CONFIG_PATH" ] || [ ! -L "$OPENCLAW_CONFIG_PATH" ] || die "SECURE_PATH_REQUIRED" 64
}

control_ui_base_path() {
  local prefix="${URL_PREFIX:-/}"
  [[ "$prefix" = /* ]] || die "URL_PREFIX_INVALID" 64
  case "$prefix" in
    *".."*|*'?'*|*'#'*|*'//'*) die "URL_PREFIX_INVALID" 64 ;;
  esac
  prefix="${prefix%/}"
  if [ -z "$prefix" ]; then
    printf '%s\n' "/openclaw"
  else
    printf '%s\n' "${prefix}/openclaw"
  fi
}

configure_control_ui_base_path() {
  local base_path tmp
  base_path="$(control_ui_base_path)"
  assert_regular_config_path

  if [ ! -e "$OPENCLAW_CONFIG_PATH" ]; then
    umask 077
    printf '{}\n' > "$OPENCLAW_CONFIG_PATH"
    chmod 0600 "$OPENCLAW_CONFIG_PATH"
  fi
  jq -e 'type == "object"' "$OPENCLAW_CONFIG_PATH" >/dev/null || die "OPENCLAW_CONFIG_INVALID" 70

  tmp="$(mktemp "$(dirname -- "$OPENCLAW_CONFIG_PATH")/.openclaw.json.XXXXXX")"
  umask 077
  jq --arg base_path "$base_path" '
    def object_or_empty:
      if . == null then {} elif type == "object" then . else error("expected object") end;
    .gateway = (.gateway | object_or_empty)
    | .gateway.controlUi = (.gateway.controlUi | object_or_empty)
    | .tools = (.tools | object_or_empty)
    | if .tools.allow == null then .tools.allow = ["exec"] else . end
    # The user home is shared across named workspaces. basePath is runtime
    # routing state, so atomically converge it to the current URL_PREFIX
    # instead of treating a previous workspace name as a configuration error.
    | .gateway.controlUi.basePath = $base_path
  ' "$OPENCLAW_CONFIG_PATH" > "$tmp" || {
    find "$(dirname -- "$tmp")" -maxdepth 1 -name "$(basename -- "$tmp")" -delete
    die "OPENCLAW_CONTROL_UI_BASE_PATH_UPDATE_FAILED" 72
  }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$OPENCLAW_CONFIG_PATH"
}

openclaw_model_access_action() {
  "${SCRIPT_DIR}/openclaw-model-access-adapter.sh" "$1"
}

openclaw_exec_gateway() {
  exec /opt/openclaw/start-openclaw.sh gateway --allow-unconfigured --bind loopback --port "$OPENCLAW_GATEWAY_PORT"
}

start_labnow_openclaw() {
  case "${MODEL_ACCESS_MODE+x}:${MODEL_ACCESS_MODE:-}" in
    :*) labnow_die "MODEL_ACCESS_MODE_REQUIRED" ;;
    x:managed)
      labnow_validate_manifest
      labnow_validate_secret
      openclaw_model_access_action apply
      openclaw_model_access_action probe
      ;;
    x:unmanaged) ;;
    *) labnow_die "MODEL_ACCESS_MODE_INVALID" ;;
  esac
  configure_control_ui_base_path
  openclaw_exec_gateway
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  start_labnow_openclaw "$@"
fi
