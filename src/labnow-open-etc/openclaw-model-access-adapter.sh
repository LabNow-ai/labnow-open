#!/usr/bin/env bash
# RuntimeManifest/RuntimeSecretFile adapter for OpenClaw.
# It deliberately stores only a file SecretRef in OpenClaw config; api_key stays
# in the Launcher-mounted RuntimeSecretFile under /run.
set -euo pipefail

readonly ADAPTER_ID="openclaw"
readonly ADAPTER_VERSION="0.1.0-candidate.2"
readonly CONTRACT_VERSION="v1alpha1"
readonly DEFAULT_MANIFEST_PATH="/run/labnow/model-access/manifest.json"
readonly DEFAULT_SECRET_PATH="/run/labnow/model-access/secret.json"

ACTION="${1:-}"
MANIFEST_PATH="$DEFAULT_MANIFEST_PATH"
SECRET_PATH="$DEFAULT_SECRET_PATH"
# Unit tests may use an isolated temporary mount. Production never accepts an
# environment-provided substitute for the Launcher contract mount points.
if [ "${LABNOW_ALLOW_TEST_PATHS:-}" = "1" ]; then
  MANIFEST_PATH="${LABNOW_MANIFEST_PATH:-$DEFAULT_MANIFEST_PATH}"
  SECRET_PATH="${LABNOW_SECRET_PATH:-$DEFAULT_SECRET_PATH}"
fi
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw/data}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR}/openclaw.json}"
STATE_DIR="${LABNOW_MODEL_ACCESS_STATE_DIR:-${OPENCLAW_STATE_DIR}/labnow-model-access}"
STATUS_PATH="${STATE_DIR}/status.json"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"

die() {
  # Never include input values here: RuntimeSecretFile contains a credential.
  printf '%s\n' "openclaw-model-access-adapter: $1" >&2
  exit "${2:-1}"
}

canonical_path() {
  if realpath -m -- "$1" >/dev/null 2>&1; then
    realpath -m -- "$1"
    return
  fi

  # macOS/BSD realpath lacks -m; all adapter-controlled parents already exist.
  local parent leaf
  parent="$(dirname -- "$1")"
  leaf="$(basename -- "$1")"
  (cd -- "$parent" && printf '%s/%s\n' "$(pwd -P)" "$leaf")
}

assert_under() {
  local parent child
  parent="$(canonical_path "$1")"
  child="$(canonical_path "$2")"
  case "$child" in
    "$parent"|"$parent"/*) ;;
    *) die "SECURE_PATH_REQUIRED" 64 ;;
  esac
}

assert_not_symlink() {
  [ ! -L "$1" ] || die "SECURE_PATH_REQUIRED" 64
}

assert_runtime_paths() {
  [[ "$OPENCLAW_STATE_DIR" = /* && "$OPENCLAW_CONFIG_PATH" = /* && "$STATE_DIR" = /* ]] || die "SECURE_PATH_REQUIRED" 64
  assert_not_symlink "$OPENCLAW_STATE_DIR"
  assert_under "$OPENCLAW_STATE_DIR" "$OPENCLAW_CONFIG_PATH"
  assert_under "$OPENCLAW_STATE_DIR" "$STATE_DIR"
  assert_not_symlink "$OPENCLAW_CONFIG_PATH"
  assert_not_symlink "$STATE_DIR"
}

assert_regular_secret() {
  [ -f "$SECRET_PATH" ] && [ ! -L "$SECRET_PATH" ] || die "SECURE_PATH_REQUIRED" 64
  local secret_mode
  if secret_mode="$(stat -c '%a' "$SECRET_PATH" 2>/dev/null)"; then :; else
    secret_mode="$(stat -f '%Lp' "$SECRET_PATH")"
  fi
  [ "$secret_mode" = "400" ] || die "SECRET_FILE_MODE_INVALID" 65
}

validate_manifest() {
  [ -f "$MANIFEST_PATH" ] && [ ! -L "$MANIFEST_PATH" ] || die "MANIFEST_UNAVAILABLE" 66
  jq -e --arg version "$CONTRACT_VERSION" --arg adapter "$ADAPTER_ID" --arg secret "$SECRET_PATH" '
    def opaque_id: type == "string" and length >= 1 and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$");
    def model_id: type == "string" and length >= 1 and length <= 256 and test("^[^[:space:]]+$");
    type == "object"
    and (keys | sort) == (["contract_version","workspace_id","binding_id","lease_id","generation","adapter_id","protocol","base_url","default_model","allowed_models","api_key_file","expires_at"] | sort)
    and .contract_version == $version
    and (.workspace_id | opaque_id)
    and (.binding_id | opaque_id)
    and (.lease_id | opaque_id)
    and (.generation | type == "number" and floor == . and . >= 1)
    and .adapter_id == $adapter
    and .protocol == "openai_compatible"
    and (.base_url | type == "string" and length <= 2048 and test("^https?://[^[:space:]]+$"))
    and (.default_model | model_id)
    and (.allowed_models | type == "array" and length >= 1 and (all(.[]; model_id)) and (unique | length == length))
    and (.default_model as $default_model | .allowed_models | index($default_model) != null)
    and .api_key_file == $secret
    and (.expires_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
  ' "$MANIFEST_PATH" >/dev/null || die "INVALID_MANIFEST" 67
}

validate_secret() {
  assert_regular_secret
  jq -e --arg version "$CONTRACT_VERSION" '
    def opaque_id: type == "string" and length >= 1 and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$");
    type == "object"
    and (keys | sort) == (["contract_version","binding_id","lease_id","generation","api_key"] | sort)
    and .contract_version == $version
    and (.binding_id | opaque_id)
    and (.lease_id | opaque_id)
    and (.generation | type == "number" and floor == . and . >= 1)
    and (.api_key | type == "string" and length >= 16 and length <= 4096)
  ' "$SECRET_PATH" >/dev/null || die "INVALID_SECRET" 68

  jq -e --slurpfile manifest "$MANIFEST_PATH" '
    .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$SECRET_PATH" >/dev/null || die "IDENTITY_MISMATCH" 69
}

ensure_config_parent() {
  mkdir -p -- "$OPENCLAW_STATE_DIR"
  assert_not_symlink "$OPENCLAW_STATE_DIR"
  mkdir -p -- "$STATE_DIR"
  assert_not_symlink "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
}

ensure_config_object() {
  if [ ! -e "$OPENCLAW_CONFIG_PATH" ]; then
    umask 077
    printf '{}\n' > "$OPENCLAW_CONFIG_PATH"
    chmod 0600 "$OPENCLAW_CONFIG_PATH"
  fi
  [ -f "$OPENCLAW_CONFIG_PATH" ] && [ ! -L "$OPENCLAW_CONFIG_PATH" ] || die "SECURE_PATH_REQUIRED" 64
  jq -e 'type == "object"' "$OPENCLAW_CONFIG_PATH" >/dev/null || die "OPENCLAW_CONFIG_INVALID" 70
}

manifest_field() {
  jq -er "$1" "$MANIFEST_PATH"
}

write_status() {
  local phase error_code message tmp
  phase="$1"
  error_code="${2:-}"
  message="${3:-}"
  ensure_config_parent
  tmp="$(mktemp "${STATE_DIR}/.status.XXXXXX")"
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
    --arg error_code "$error_code" \
    --arg message "$message" \
    '{contract_version:$contract_version, workspace_id:$workspace_id, binding_id:$binding_id, lease_id:$lease_id, generation:$generation, adapter_id:$adapter_id, phase:$phase, observed_at:$observed_at}
     + (if $error_code == "" then {} else {error_code:$error_code} end)
     + (if $message == "" then {} else {message:$message} end)' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$STATUS_PATH"
}

render_apply() {
  local tmp aliases models
  tmp="$(mktemp "${OPENCLAW_STATE_DIR}/.openclaw.json.XXXXXX")"
  aliases="$(jq -c '[.allowed_models[] | {full:("labnow/" + .), alias:("labnow/" + .)}]' "$MANIFEST_PATH")"
  models="$(jq -c '[.allowed_models[] | {id:., name:.}]' "$MANIFEST_PATH")"

  jq \
    --arg base_url "$(manifest_field '.base_url')" \
    --arg secret_path "$SECRET_PATH" \
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
    ' "$OPENCLAW_CONFIG_PATH" > "$tmp" || { rm -f -- "$tmp"; die "OPENCLAW_CONFIG_INVALID" 70; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$OPENCLAW_CONFIG_PATH"
}

render_remove() {
  local tmp
  [ -e "$OPENCLAW_CONFIG_PATH" ] || return 0
  ensure_config_object
  tmp="$(mktemp "${OPENCLAW_STATE_DIR}/.openclaw.json.XXXXXX")"
  jq '
    if (.models? | type) == "object" and (.models.providers? | type) == "object" then del(.models.providers.labnow) else . end
    | if (.secrets? | type) == "object" and (.secrets.providers? | type) == "object" then del(.secrets.providers["labnow-runtime"]) else . end
    | if (.agents? | type) == "object" and (.agents.defaults? | type) == "object" and (.agents.defaults.models? | type) == "object" then
        .agents.defaults.models |= with_entries(select(.key | startswith("labnow/") | not))
      else . end
  ' "$OPENCLAW_CONFIG_PATH" > "$tmp" || { rm -f -- "$tmp"; die "OPENCLAW_CONFIG_INVALID" 70; }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$OPENCLAW_CONFIG_PATH"
}

capabilities() {
  jq -n --arg adapter_id "$ADAPTER_ID" --arg adapter_version "$ADAPTER_VERSION" --arg contract_version "$CONTRACT_VERSION" \
    '{adapter_id:$adapter_id, adapter_version:$adapter_version, supported_contract_versions:[$contract_version], supported_protocols:["openai_compatible"], supports_reload:false}'
}

apply() {
  assert_runtime_paths
  validate_manifest
  validate_secret
  ensure_config_parent
  ensure_config_object
  render_apply
  write_status "applied"
}

probe() {
  assert_runtime_paths
  validate_manifest
  validate_secret
  ensure_config_parent
  ensure_config_object
  jq -e '.models.providers.labnow? and .secrets.providers["labnow-runtime"]?' "$OPENCLAW_CONFIG_PATH" >/dev/null || die "MANAGED_CONFIG_MISSING" 71
  "$OPENCLAW_BIN" config validate >/dev/null 2>&1 || die "OPENCLAW_CONFIG_INVALID" 70
  write_status "ready"
}

remove() {
  assert_runtime_paths
  validate_manifest
  ensure_config_parent
  render_remove
  write_status "removed"
}

case "$ACTION" in
  capabilities) capabilities ;;
  apply) apply ;;
  probe) probe ;;
  remove) remove ;;
  *) die "USAGE: capabilities|apply|probe|remove" 64 ;;
esac
