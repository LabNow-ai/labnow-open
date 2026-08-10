#!/usr/bin/env bash
# RuntimeManifest/RuntimeSecretFile adapter for Hermes.
# The Hermes managed-scope config references OPENAI_API_KEY but never stores it.
set -euo pipefail

readonly ADAPTER_ID="hermes"
readonly ADAPTER_VERSION="0.1.0-rc.1"
readonly CONTRACT_VERSION="v1alpha1"
readonly DEFAULT_MANIFEST_PATH="/run/labnow/model-access/manifest.json"
readonly DEFAULT_SECRET_PATH="/run/labnow/model-access/secret.json"
readonly DEFAULT_STATUS_PATH="/run/labnow/model-access/status.json"

ACTION="${1:-}"
MANIFEST_PATH="$DEFAULT_MANIFEST_PATH"
SECRET_PATH="$DEFAULT_SECRET_PATH"
STATUS_PATH="$DEFAULT_STATUS_PATH"
if [ "${LABNOW_ALLOW_TEST_PATHS:-}" = "1" ]; then
  MANIFEST_PATH="${LABNOW_MANIFEST_PATH:-$DEFAULT_MANIFEST_PATH}"
  SECRET_PATH="${LABNOW_SECRET_PATH:-$DEFAULT_SECRET_PATH}"
  STATUS_PATH="${LABNOW_STATUS_PATH:-$DEFAULT_STATUS_PATH}"
fi

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
HERMES_MANAGED_DIR="${HERMES_MANAGED_DIR:-${HERMES_HOME}/labnow-model-access}"
HERMES_CONFIG_PATH="${HERMES_MANAGED_DIR}/config.yaml"
STATE_DIR="${HERMES_MANAGED_DIR}/state"
HERMES_BIN="${HERMES_BIN:-hermes}"

die() {
  # Never include input values here: RuntimeSecretFile contains a credential.
  printf '%s\n' "hermes-model-access-adapter: $1" >&2
  exit "${2:-1}"
}

canonical_path() {
  if realpath -m -- "$1" >/dev/null 2>&1; then
    realpath -m -- "$1"
    return
  fi

  local parent leaf
  parent="$(dirname -- "$1")"
  leaf="$(basename -- "$1")"
  (cd -- "$parent" && printf '%s/%s\n' "$(pwd -P)" "$leaf")
}

assert_under() {
  local parent target
  parent="$(canonical_path "$1")"
  target="$(canonical_path "$2")"
  [[ "$target" == "$parent"/* ]] || die "SECURE_PATH_REQUIRED" 64
}

assert_not_symlink() {
  [ ! -L "$1" ] || die "SECURE_PATH_REQUIRED" 64
}

assert_runtime_paths() {
  [[ "$HERMES_HOME" = /* && "$HERMES_MANAGED_DIR" = /* && "$STATUS_PATH" = /* ]] || die "SECURE_PATH_REQUIRED" 64
  assert_not_symlink "$HERMES_HOME"
  assert_under "$HERMES_HOME" "$HERMES_MANAGED_DIR"
  assert_under "$HERMES_MANAGED_DIR" "$HERMES_CONFIG_PATH"
  assert_under "$HERMES_MANAGED_DIR" "$STATE_DIR"
  assert_not_symlink "$HERMES_MANAGED_DIR"
  assert_not_symlink "$HERMES_CONFIG_PATH"
  assert_not_symlink "$STATE_DIR"
}

ensure_managed_paths() {
  [[ "$HERMES_HOME" = /* && "$HERMES_MANAGED_DIR" = "$HERMES_HOME"/* ]] || die "SECURE_PATH_REQUIRED" 64
  mkdir -p -- "$HERMES_HOME"
  assert_not_symlink "$HERMES_HOME"
  chmod 0700 "$HERMES_HOME"
  mkdir -p -- "$HERMES_MANAGED_DIR" "$STATE_DIR"
  assert_not_symlink "$HERMES_MANAGED_DIR"
  assert_not_symlink "$STATE_DIR"
  chmod 0700 "$HERMES_MANAGED_DIR" "$STATE_DIR"
}

ensure_status_parent() {
  local status_parent
  status_parent="$(dirname -- "$STATUS_PATH")"
  mkdir -p -- "$status_parent"
  assert_not_symlink "$status_parent"
  [ ! -e "$STATUS_PATH" ] || [ ! -L "$STATUS_PATH" ] || die "SECURE_PATH_REQUIRED" 64
  chmod 0700 "$status_parent"
}

opaque_id() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

validate_manifest() {
  [ -f "$MANIFEST_PATH" ] && [ ! -L "$MANIFEST_PATH" ] || die "INVALID_MANIFEST" 67
  jq -e --arg version "$CONTRACT_VERSION" '
    type == "object"
    and (keys | sort) == (["adapter_id","allowed_models","api_key_file","base_url","binding_id","contract_version","default_model","expires_at","generation","lease_id","protocol","workspace_id"] | sort)
    and .contract_version == $version
    and .adapter_id == "hermes"
    and .protocol == "openai_compatible"
    and (.workspace_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.binding_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.lease_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.generation | type == "number" and floor == . and . >= 1)
    and (.base_url | type == "string" and length <= 2048 and test("^https?://[^[:space:]]+$"))
    and (.api_key_file == "/run/labnow/model-access/secret.json")
    and (.expires_at | type == "string" and (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) != null)
    and (.allowed_models | type == "array" and length > 0 and unique == . and all(.[]; type == "string" and length >= 1 and length <= 256 and test("^[^[:space:]]+$")))
    and (.default_model as $default_model | ($default_model | type == "string" and length >= 1 and length <= 256 and test("^[^[:space:]]+$")) and (.allowed_models | index($default_model) != null))
  ' "$MANIFEST_PATH" >/dev/null || die "INVALID_MANIFEST" 67
}

validate_secret() {
  [ -f "$SECRET_PATH" ] && [ ! -L "$SECRET_PATH" ] || die "INVALID_SECRET" 68
  [ "$(stat -c '%a' "$SECRET_PATH" 2>/dev/null || stat -f '%Lp' "$SECRET_PATH")" = "400" ] || die "SECURE_SECRET_MODE_REQUIRED" 65
  jq -e --arg version "$CONTRACT_VERSION" '
    type == "object"
    and (keys | sort) == (["api_key","binding_id","contract_version","generation","lease_id"] | sort)
    and .contract_version == $version
    and (.binding_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.lease_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.generation | type == "number" and floor == . and . >= 1)
    and (.api_key | type == "string" and length >= 16 and length <= 4096 and test("^[^[:space:]]+$"))
  ' "$SECRET_PATH" >/dev/null || die "INVALID_SECRET" 68
  jq -e --slurpfile manifest "$MANIFEST_PATH" '
    .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$SECRET_PATH" >/dev/null || die "IDENTITY_MISMATCH" 69
}

manifest_field() {
  jq -er "$1" "$MANIFEST_PATH"
}

write_status() {
  local phase status_parent tmp
  phase="$1"
  ensure_status_parent
  status_parent="$(dirname -- "$STATUS_PATH")"
  tmp="$(mktemp "${status_parent}/.status.XXXXXX")"
  umask 077
  jq -n \
    --arg contract_version "$CONTRACT_VERSION" \
    --arg workspace_id "$(manifest_field '.workspace_id')" \
    --arg binding_id "$(manifest_field '.binding_id')" \
    --arg lease_id "$(manifest_field '.lease_id')" \
    --argjson generation "$(manifest_field '.generation')" \
    --arg adapter_id "$ADAPTER_ID" \
    --arg phase "$phase" \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{contract_version:$contract_version, workspace_id:$workspace_id, binding_id:$binding_id, lease_id:$lease_id, generation:$generation, adapter_id:$adapter_id, phase:$phase, observed_at:$observed_at}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$STATUS_PATH"
}

write_binding_state() {
  local tmp
  tmp="$(mktemp "${STATE_DIR}/.binding.XXXXXX")"
  umask 077
  jq -n \
    --arg binding_id "$(manifest_field '.binding_id')" \
    --arg lease_id "$(manifest_field '.lease_id')" \
    --argjson generation "$(manifest_field '.generation')" \
    '{binding_id:$binding_id, lease_id:$lease_id, generation:$generation}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "${STATE_DIR}/binding.json"
}

render_apply() {
  local tmp
  tmp="$(mktemp "${HERMES_MANAGED_DIR}/.config.XXXXXX")"
  umask 077
  jq -n \
    --arg base_url "$(manifest_field '.base_url')" \
    --arg default_model "$(manifest_field '.default_model')" \
    --arg api_key_ref '${OPENAI_API_KEY}' \
    '{model:{provider:"custom", default:$default_model, base_url:$base_url, api_mode:"chat_completions", api_key:$api_key_ref}}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$HERMES_CONFIG_PATH"
}

assert_managed_config() {
  jq -e \
    --arg base_url "$(manifest_field '.base_url')" \
    --arg default_model "$(manifest_field '.default_model')" \
    --arg api_key_ref '${OPENAI_API_KEY}' '
      type == "object"
      and (keys | sort) == ["model"]
      and .model == {provider:"custom", default:$default_model, base_url:$base_url, api_mode:"chat_completions", api_key:$api_key_ref}
    ' "$HERMES_CONFIG_PATH" >/dev/null || die "MANAGED_CONFIG_MISSING" 71
}

capabilities() {
  jq -n --arg adapter_id "$ADAPTER_ID" --arg adapter_version "$ADAPTER_VERSION" --arg contract_version "$CONTRACT_VERSION" \
    '{adapter_id:$adapter_id, adapter_version:$adapter_version, supported_contract_versions:[$contract_version], supported_protocols:["openai_compatible"], supports_reload:false}'
}

apply() {
  validate_manifest
  validate_secret
  ensure_managed_paths
  assert_runtime_paths
  render_apply
  write_binding_state
  write_status "applied"
}

probe() {
  validate_manifest
  validate_secret
  ensure_managed_paths
  assert_runtime_paths
  [ -f "$HERMES_CONFIG_PATH" ] && [ ! -L "$HERMES_CONFIG_PATH" ] || die "MANAGED_CONFIG_MISSING" 71
  assert_managed_config
  HERMES_HOME="$HERMES_HOME" HERMES_MANAGED_DIR="$HERMES_MANAGED_DIR" "$HERMES_BIN" config check >/dev/null 2>&1 || die "HERMES_CONFIG_INVALID" 70
  write_status "ready"
}

remove() {
  validate_manifest
  ensure_managed_paths
  assert_runtime_paths
  [ ! -e "$HERMES_CONFIG_PATH" ] || [ ! -L "$HERMES_CONFIG_PATH" ] || die "SECURE_PATH_REQUIRED" 64
  rm -f -- "$HERMES_CONFIG_PATH" "${STATE_DIR}/binding.json"
  write_status "removed"
}

case "$ACTION" in
  capabilities) capabilities ;;
  apply) apply ;;
  probe) probe ;;
  remove) remove ;;
  *) die "USAGE: capabilities|apply|probe|remove" 64 ;;
esac
