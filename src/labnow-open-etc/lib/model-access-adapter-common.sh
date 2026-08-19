#!/usr/bin/env bash
# Shared RuntimeManifest/RuntimeSecretFile validation and lifecycle helpers.
# This file is sourced by application adapters and the Hermes starter.
set -Eeuo pipefail

: "${LABNOW_ADAPTER_ID:?LABNOW_ADAPTER_ID is required}"
: "${LABNOW_MANIFEST_PATH:?LABNOW_MANIFEST_PATH is required}"
: "${LABNOW_SECRET_PATH:?LABNOW_SECRET_PATH is required}"
: "${LABNOW_STATUS_PATH:?LABNOW_STATUS_PATH is required}"

readonly LABNOW_CONTRACT_VERSION="v1alpha1"
readonly LABNOW_CONTRACT_MANIFEST_PATH="/run/labnow/model-access/manifest.json"
readonly LABNOW_CONTRACT_SECRET_PATH="/run/labnow/model-access/secret.json"
readonly LABNOW_CONTRACT_STATUS_PATH="/run/labnow/model-access/status.json"

LABNOW_TEMP_FILES=()
LABNOW_LAST_TEMP=""
LABNOW_LAST_ERROR=""
LABNOW_STATUS_IDENTITY_READY=false
LABNOW_FAILURE_STATUS_WRITTEN=false

# Adapter-local errors use this registry. Its numeric values are deliberately
# stable across OpenClaw and Hermes, while the public HTTP error registry stays
# owned by the model-access contract.
labnow_error_exit_code() {
  case "$1" in
    USAGE|SECURE_PATH_REQUIRED|INVALID_WAIT_CONFIGURATION) printf '64\n' ;;
    SECRET_FILE_MODE_INVALID) printf '65\n' ;;
    MANIFEST_UNAVAILABLE) printf '66\n' ;;
    INVALID_MANIFEST) printf '67\n' ;;
    INVALID_SECRET) printf '68\n' ;;
    IDENTITY_MISMATCH) printf '69\n' ;;
    APPLICATION_CONFIG_INVALID) printf '70\n' ;;
    MANAGED_CONFIG_MISSING) printf '71\n' ;;
    RUNTIME_MATERIAL_TIMEOUT) printf '73\n' ;;
    *) printf '1\n' ;;
  esac
}

labnow_log_error() {
  printf '%s-model-access: %s\n' "$LABNOW_ADAPTER_ID" "$1" >&2
}

labnow_die() {
  local error_code="$1"
  LABNOW_LAST_ERROR="$error_code"
  labnow_log_error "$error_code"
  exit "$(labnow_error_exit_code "$error_code")"
}

labnow_canonical_path() {
  if realpath -m -- "$1" >/dev/null 2>&1; then
    realpath -m -- "$1"
    return
  fi

  local parent leaf
  parent="$(dirname -- "$1")"
  leaf="$(basename -- "$1")"
  (cd -- "$parent" && printf '%s/%s\n' "$(pwd -P)" "$leaf")
}

labnow_assert_under() {
  local parent child
  parent="$(labnow_canonical_path "$1")"
  child="$(labnow_canonical_path "$2")"
  case "$child" in
    "$parent"|"$parent"/*) ;;
    *) labnow_die "SECURE_PATH_REQUIRED" ;;
  esac
}

labnow_assert_not_symlink() {
  [ ! -L "$1" ] || labnow_die "SECURE_PATH_REQUIRED"
}

labnow_assert_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || labnow_die "$2"
}

labnow_file_mode() {
  if stat -c '%a' "$1" 2>/dev/null; then
    return
  fi
  stat -f '%Lp' "$1"
}

labnow_assert_secret_file() {
  labnow_assert_regular_file "$LABNOW_SECRET_PATH" "INVALID_SECRET"
  [ "$(labnow_file_mode "$LABNOW_SECRET_PATH")" = "400" ] || labnow_die "SECRET_FILE_MODE_INVALID"
}

labnow_make_temp() {
  local parent="$1" pattern="$2"
  LABNOW_LAST_TEMP="$(mktemp "${parent}/${pattern}.XXXXXX")"
  LABNOW_TEMP_FILES+=("$LABNOW_LAST_TEMP")
}

labnow_forget_temp() {
  local target="$1" kept=() item
  for item in "${LABNOW_TEMP_FILES[@]:-}"; do
    [ "$item" = "$target" ] || kept+=("$item")
  done
  LABNOW_TEMP_FILES=("${kept[@]:-}")
}

labnow_cleanup() {
  local item
  for item in "${LABNOW_TEMP_FILES[@]:-}"; do
    [ -n "$item" ] && rm -f -- "$item"
  done
  LABNOW_TEMP_FILES=()
}

labnow_write_status() {
  local phase="$1" error_code="${2:-}" message="${3:-}" status_parent tmp
  [ "$LABNOW_STATUS_IDENTITY_READY" = true ] || return 0
  status_parent="$(dirname -- "$LABNOW_STATUS_PATH")"
  mkdir -p -- "$status_parent"
  labnow_assert_not_symlink "$status_parent"
  [ ! -e "$LABNOW_STATUS_PATH" ] || labnow_assert_not_symlink "$LABNOW_STATUS_PATH"
  chmod 0700 "$status_parent"
  labnow_make_temp "$status_parent" ".status"
  tmp="$LABNOW_LAST_TEMP"
  umask 077
  jq -n \
    --arg contract_version "$LABNOW_CONTRACT_VERSION" \
    --arg workspace_id "$(labnow_manifest_field '.workspace_id')" \
    --arg binding_id "$(labnow_manifest_field '.binding_id')" \
    --arg lease_id "$(labnow_manifest_field '.lease_id')" \
    --argjson generation "$(labnow_manifest_field '.generation')" \
    --arg adapter_id "$LABNOW_ADAPTER_ID" \
    --arg phase "$phase" \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg error_code "$error_code" \
    --arg message "$message" \
    '{contract_version:$contract_version, workspace_id:$workspace_id, binding_id:$binding_id, lease_id:$lease_id, generation:$generation, adapter_id:$adapter_id, phase:$phase, observed_at:$observed_at}
     + (if $error_code == "" then {} else {error_code:$error_code} end)
     + (if $message == "" then {} else {message:$message} end)' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$LABNOW_STATUS_PATH"
  labnow_forget_temp "$tmp"
}

labnow_on_exit() {
  local exit_code="$1"
  trap - EXIT
  if [ "$exit_code" -ne 0 ] && [ "$LABNOW_STATUS_IDENTITY_READY" = true ] && [ "$LABNOW_FAILURE_STATUS_WRITTEN" = false ]; then
    LABNOW_FAILURE_STATUS_WRITTEN=true
    labnow_write_status "failed" "${LABNOW_LAST_ERROR:-APPLICATION_CONFIG_INVALID}" "model access operation failed" || true
  fi
  labnow_cleanup
  exit "$exit_code"
}

trap 'labnow_on_exit "$?"' EXIT

labnow_manifest_field() {
  jq -er "$1" "$LABNOW_MANIFEST_PATH"
}

labnow_validate_manifest() {
  labnow_assert_regular_file "$LABNOW_MANIFEST_PATH" "MANIFEST_UNAVAILABLE"
  jq -e --arg version "$LABNOW_CONTRACT_VERSION" --arg adapter "$LABNOW_ADAPTER_ID" '
    def opaque_id: type == "string" and length >= 1 and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$");
    type == "object"
    and (keys | sort) == (["contract_version","workspace_id","binding_id","lease_id","generation","adapter_id","protocol","base_url","default_model","allowed_models","api_key_file","expires_at"] | sort)
    and .contract_version == $version
    and (.workspace_id | opaque_id)
    and (.binding_id | opaque_id)
    and (.lease_id | opaque_id)
    and (.generation | type == "number" and floor == . and . >= 1)
    and .adapter_id == $adapter
  ' "$LABNOW_MANIFEST_PATH" >/dev/null && LABNOW_STATUS_IDENTITY_READY=true
  jq -e --arg version "$LABNOW_CONTRACT_VERSION" --arg adapter "$LABNOW_ADAPTER_ID" --arg secret "$LABNOW_CONTRACT_SECRET_PATH" '
    def opaque_id: type == "string" and length >= 1 and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$");
    def model_id: type == "string" and length >= 1 and length <= 256 and test("^[^[:space:]]+$");
    def expires_epoch:
      capture("^(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<time>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<fraction>\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$") as $parts
      | ($parts.date + "T" + $parts.time) as $local
      | ($local | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $utc_local
      | ($utc_local | strftime("%Y-%m-%dT%H:%M:%S")) as $normalized
      | if $normalized != $local then error("invalid date") else . end
      | (if $parts.zone == "Z" then 0 else
           ($parts.zone | capture("^(?<sign>[+-])(?<hours>[0-9]{2}):(?<minutes>[0-9]{2})$")) as $zone
           | (($zone.hours | tonumber) * 3600 + ($zone.minutes | tonumber) * 60) as $offset
           | if ($zone.hours | tonumber) > 23 or ($zone.minutes | tonumber) > 59 then error("invalid offset")
             elif $zone.sign == "+" then $offset else -$offset end
         end) as $offset
      | ($parts.fraction // "0" | "0" + ltrimstr("0") | tonumber) as $fraction
      | $utc_local - $offset + $fraction;
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
    and (.allowed_models | type == "array" and length >= 1 and all(.[]; model_id) and (. as $models | ($models | unique | length) == ($models | length)))
    and (.default_model as $default_model | .allowed_models | index($default_model) != null)
    and .api_key_file == $secret
    and (.expires_at | type == "string" and ((try expires_epoch catch null) as $expires_at | $expires_at != null and now < $expires_at))
  ' "$LABNOW_MANIFEST_PATH" >/dev/null || labnow_die "INVALID_MANIFEST"
}

labnow_validate_secret() {
  labnow_assert_secret_file
  jq -e --arg version "$LABNOW_CONTRACT_VERSION" '
    def opaque_id: type == "string" and length >= 1 and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$");
    type == "object"
    and (keys | sort) == (["contract_version","binding_id","lease_id","generation","api_key"] | sort)
    and .contract_version == $version
    and (.binding_id | opaque_id)
    and (.lease_id | opaque_id)
    and (.generation | type == "number" and floor == . and . >= 1)
    and (.api_key | type == "string" and length >= 16 and length <= 4096 and test("^[^[:space:]]+$"))
  ' "$LABNOW_SECRET_PATH" >/dev/null || labnow_die "INVALID_SECRET"
  jq -e --slurpfile manifest "$LABNOW_MANIFEST_PATH" '
    .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$LABNOW_SECRET_PATH" >/dev/null || labnow_die "IDENTITY_MISMATCH"
}

labnow_write_empty_json_object() {
  local path="$1" parent tmp
  [ -e "$path" ] && return 0
  parent="$(dirname -- "$path")"
  labnow_make_temp "$parent" ".config"
  tmp="$LABNOW_LAST_TEMP"
  umask 077
  printf '{}\n' > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
  labnow_forget_temp "$tmp"
}

labnow_capabilities() {
  jq -n --arg adapter_id "$LABNOW_ADAPTER_ID" --arg adapter_version "$LABNOW_ADAPTER_VERSION" --arg contract_version "$LABNOW_CONTRACT_VERSION" \
    '{adapter_id:$adapter_id, adapter_version:$adapter_version, supported_contract_versions:[$contract_version], supported_protocols:["openai_compatible"], supports_reload:false}'
}

labnow_adapter_dispatch() {
  local action="${1:-}"
  case "$action" in
    capabilities) labnow_capabilities ;;
    apply) labnow_adapter_apply ;;
    probe) labnow_adapter_probe ;;
    remove) labnow_adapter_remove ;;
    *) labnow_die "USAGE" ;;
  esac
}
