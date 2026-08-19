#!/usr/bin/env bash
# OpenClaw renderer for the shared RuntimeManifest/RuntimeSecretFile adapter.
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

OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw/data}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR}/openclaw.json}"
STATE_DIR="${LABNOW_MODEL_ACCESS_STATE_DIR:-${OPENCLAW_STATE_DIR}/labnow-model-access}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"

openclaw_assert_runtime_paths() {
  [[ "$OPENCLAW_STATE_DIR" = /* && "$OPENCLAW_CONFIG_PATH" = /* && "$STATE_DIR" = /* ]] || labnow_die "SECURE_PATH_REQUIRED"
  labnow_assert_not_symlink "$OPENCLAW_STATE_DIR"
  labnow_assert_under "$OPENCLAW_STATE_DIR" "$OPENCLAW_CONFIG_PATH"
  labnow_assert_under "$OPENCLAW_STATE_DIR" "$STATE_DIR"
  labnow_assert_not_symlink "$OPENCLAW_CONFIG_PATH"
  labnow_assert_not_symlink "$STATE_DIR"
}

openclaw_ensure_paths() {
  mkdir -p -- "$OPENCLAW_STATE_DIR" "$STATE_DIR"
  labnow_assert_not_symlink "$OPENCLAW_STATE_DIR"
  labnow_assert_not_symlink "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
}

openclaw_ensure_config() {
  labnow_write_empty_json_object "$OPENCLAW_CONFIG_PATH"
  [ -f "$OPENCLAW_CONFIG_PATH" ] && [ ! -L "$OPENCLAW_CONFIG_PATH" ] || labnow_die "SECURE_PATH_REQUIRED"
  jq -e 'type == "object"' "$OPENCLAW_CONFIG_PATH" >/dev/null || labnow_die "APPLICATION_CONFIG_INVALID"
}

openclaw_render_apply() {
  local tmp aliases models
  labnow_make_temp "$OPENCLAW_STATE_DIR" ".openclaw.json"
  tmp="$LABNOW_LAST_TEMP"
  aliases="$(jq -c '[.allowed_models[] | {full:("labnow/" + .), alias:("labnow/" + .)}]' "$LABNOW_MANIFEST_PATH")"
  models="$(jq -c '[.allowed_models[] | {id:., name:.}]' "$LABNOW_MANIFEST_PATH")"
  jq \
    --arg base_url "$(labnow_manifest_field '.base_url')" \
    --arg secret_path "$LABNOW_SECRET_PATH" \
    --argjson aliases "$aliases" \
    --argjson models "$models" '
      def object_or_empty: if . == null then {} elif type == "object" then . else error("expected object") end;
      .secrets = (.secrets | object_or_empty)
      | .secrets.providers = (.secrets.providers | object_or_empty)
      | .secrets.providers["labnow-runtime"] = {source:"file", path:$secret_path, mode:"json"}
      | .models = (.models | object_or_empty)
      | .models.providers = (.models.providers | object_or_empty)
      | .models.providers.labnow = {baseUrl:$base_url, apiKey:{source:"file", provider:"labnow-runtime", id:"/api_key"}, auth:"api-key", api:"openai-completions", models:$models}
      | .agents = (.agents | object_or_empty)
      | .agents.defaults = (.agents.defaults | object_or_empty)
      | .agents.defaults.models = ((.agents.defaults.models | object_or_empty) | with_entries(select(.key | startswith("labnow/") | not)))
      | reduce $aliases[] as $item (.; .agents.defaults.models[$item.full] = {alias:$item.alias})
    ' "$OPENCLAW_CONFIG_PATH" > "$tmp" || labnow_die "APPLICATION_CONFIG_INVALID"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$OPENCLAW_CONFIG_PATH"
  labnow_forget_temp "$tmp"
}

openclaw_render_remove() {
  local tmp
  [ -e "$OPENCLAW_CONFIG_PATH" ] || return 0
  openclaw_ensure_config
  labnow_make_temp "$OPENCLAW_STATE_DIR" ".openclaw.json"
  tmp="$LABNOW_LAST_TEMP"
  jq '
    if (.models? | type) == "object" and (.models.providers? | type) == "object" then del(.models.providers.labnow) else . end
    | if (.secrets? | type) == "object" and (.secrets.providers? | type) == "object" then del(.secrets.providers["labnow-runtime"]) else . end
    | if (.agents? | type) == "object" and (.agents.defaults? | type) == "object" and (.agents.defaults.models? | type) == "object" then
        .agents.defaults.models |= with_entries(select(.key | startswith("labnow/") | not))
      else . end
  ' "$OPENCLAW_CONFIG_PATH" > "$tmp" || labnow_die "APPLICATION_CONFIG_INVALID"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$OPENCLAW_CONFIG_PATH"
  labnow_forget_temp "$tmp"
}

labnow_adapter_apply() {
  openclaw_assert_runtime_paths
  labnow_validate_manifest
  labnow_validate_secret
  openclaw_ensure_paths
  openclaw_ensure_config
  openclaw_render_apply
  labnow_write_status "applied"
}

labnow_adapter_probe() {
  openclaw_assert_runtime_paths
  labnow_validate_manifest
  labnow_validate_secret
  openclaw_ensure_paths
  openclaw_ensure_config
  jq -e '.models.providers.labnow? and .secrets.providers["labnow-runtime"]?' "$OPENCLAW_CONFIG_PATH" >/dev/null || labnow_die "MANAGED_CONFIG_MISSING"
  OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_PATH" "$OPENCLAW_BIN" config validate >/dev/null 2>&1 || labnow_die "APPLICATION_CONFIG_INVALID"
  labnow_write_status "ready"
}

labnow_adapter_remove() {
  openclaw_assert_runtime_paths
  labnow_validate_manifest
  openclaw_ensure_paths
  openclaw_render_remove
  labnow_write_status "removed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  labnow_adapter_dispatch "${1:-}"
fi
