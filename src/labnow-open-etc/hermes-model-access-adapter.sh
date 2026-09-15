#!/usr/bin/env bash
# Hermes renderer for the shared RuntimeManifest/RuntimeSecretFile adapter.
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
HERMES_CONFIG_PATH="${HERMES_MANAGED_DIR}/config.yaml"
STATE_DIR="${HERMES_MANAGED_DIR}/state"
HERMES_BIN="${HERMES_BIN:-hermes}"
LABNOW_CONFIG_ROOT="$HERMES_HOME"
LABNOW_MANAGED_STATE_DIR="$STATE_DIR"

hermes_assert_runtime_paths() {
  [[ "$HERMES_HOME" = /* && "$HERMES_MANAGED_DIR" = /* ]] || labnow_die "SECURE_PATH_REQUIRED"
  labnow_assert_trusted_path "$HERMES_HOME" "$HERMES_MANAGED_DIR"
  labnow_assert_trusted_path "$HERMES_MANAGED_DIR" "$HERMES_CONFIG_PATH"
  labnow_assert_trusted_path "$HERMES_MANAGED_DIR" "$STATE_DIR"
  labnow_assert_not_symlink "$HERMES_MANAGED_DIR"
  labnow_assert_not_symlink "$HERMES_CONFIG_PATH"
  labnow_assert_not_symlink "$STATE_DIR"
}

hermes_ensure_paths() {
  [[ "$HERMES_HOME" = /* && "$HERMES_MANAGED_DIR" = "$HERMES_HOME"/* ]] || labnow_die "SECURE_PATH_REQUIRED"
  labnow_ensure_trusted_directory "$HERMES_HOME"
  labnow_ensure_trusted_directory "$HERMES_MANAGED_DIR"
  labnow_ensure_trusted_directory "$STATE_DIR"
  labnow_assert_trusted_path "$HERMES_HOME" "$HERMES_MANAGED_DIR"
  labnow_assert_trusted_path "$HERMES_MANAGED_DIR" "$HERMES_CONFIG_PATH"
  labnow_assert_trusted_path "$HERMES_MANAGED_DIR" "$STATE_DIR"
  chmod 0700 "$HERMES_MANAGED_DIR" "$STATE_DIR"
}

hermes_render_apply() {
  local tmp
  labnow_make_temp "$HERMES_MANAGED_DIR" ".config"
  tmp="$LABNOW_LAST_TEMP"
  umask 077
  jq -n \
    --arg base_url "$(labnow_manifest_field '.base_url')" \
    --arg default_model "$(labnow_manifest_field '.default_model')" \
    --arg api_key_ref '${OPENAI_API_KEY}' \
    '{model:{provider:"custom", default:$default_model, base_url:$base_url, api_mode:"chat_completions", api_key:$api_key_ref}}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$HERMES_CONFIG_PATH"
  labnow_forget_temp "$tmp"
}

hermes_assert_managed_config() {
  jq -e \
    --arg base_url "$(labnow_manifest_field '.base_url')" \
    --arg default_model "$(labnow_manifest_field '.default_model')" \
    --arg api_key_ref '${OPENAI_API_KEY}' '
      type == "object"
      and (keys | sort) == ["model"]
      and .model == {provider:"custom", default:$default_model, base_url:$base_url, api_mode:"chat_completions", api_key:$api_key_ref}
    ' "$HERMES_CONFIG_PATH" >/dev/null || labnow_die "MANAGED_CONFIG_MISSING"
}

labnow_adapter_apply() {
  labnow_validate_manifest
  labnow_validate_secret
  hermes_ensure_paths
  hermes_assert_runtime_paths
  labnow_assert_apply_generation
  hermes_render_apply
  labnow_write_binding_state
  labnow_write_status "applied"
}

labnow_adapter_probe() {
  labnow_validate_manifest
  labnow_validate_secret
  hermes_ensure_paths
  hermes_assert_runtime_paths
  [ -f "$HERMES_CONFIG_PATH" ] && [ ! -L "$HERMES_CONFIG_PATH" ] || labnow_die "MANAGED_CONFIG_MISSING"
  hermes_assert_managed_config
  HERMES_HOME="$HERMES_HOME" HERMES_MANAGED_DIR="$HERMES_MANAGED_DIR" "$HERMES_BIN" config check >/dev/null 2>&1 || labnow_die "APPLICATION_CONFIG_INVALID"
  labnow_write_status "ready"
}

labnow_adapter_remove() {
  labnow_validate_manifest
  hermes_ensure_paths
  hermes_assert_runtime_paths
  if labnow_remove_matches_binding; then
    hermes_assert_runtime_paths
    [ ! -e "$HERMES_CONFIG_PATH" ] || [ ! -L "$HERMES_CONFIG_PATH" ] || labnow_die "SECURE_PATH_REQUIRED"
    rm -f -- "$HERMES_CONFIG_PATH"
    labnow_remove_binding_state
  fi
  labnow_write_status "removed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  labnow_adapter_dispatch "${1:-}"
fi
