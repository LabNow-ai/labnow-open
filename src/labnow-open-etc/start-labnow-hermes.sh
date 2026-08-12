#!/usr/bin/env bash
# Starts Hermes only after a LabNow-managed runtime is coherent. The generated
# Hermes config contains a SecretRef, never a credential value.
set -euo pipefail

readonly CONTRACT_VERSION="v1alpha1"
readonly ADAPTER_ID="hermes"
readonly HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
readonly HERMES_MANAGED_DIR="${HERMES_MANAGED_DIR:-${HERMES_HOME}/labnow-model-access}"
readonly HERMES_MANAGED_CONFIG="${HERMES_MANAGED_DIR}/config.yaml"
readonly HERMES_BINDING_STATE="${HERMES_MANAGED_DIR}/state/binding.json"

RUNTIME_MANIFEST_PATH="/run/labnow/model-access/manifest.json"
RUNTIME_SECRET_PATH="/run/labnow/model-access/secret.json"
HERMES_START_BIN="/usr/local/bin/start-hermes.sh"
# A short discovery period lets the Launcher materialize a RuntimeManifest
# after supervisord starts, without making unmanaged Hermes workspaces wait for
# a SecretFile. Once a Hermes manifest is found, the longer bounded material
# wait fails closed rather than starting with a literal ${OPENAI_API_KEY}.
MANIFEST_DISCOVERY_WAIT_SECONDS=10
RUNTIME_MATERIAL_WAIT_SECONDS=30

# Isolated host tests may substitute paths, the upstream launcher and short
# timeouts. Production always uses the fixed RC1 mount and bounded constants.
if [ "${LABNOW_ALLOW_TEST_PATHS:-}" = "1" ]; then
  RUNTIME_MANIFEST_PATH="${LABNOW_MANIFEST_PATH:-$RUNTIME_MANIFEST_PATH}"
  RUNTIME_SECRET_PATH="${LABNOW_RUNTIME_SECRET_PATH:-$RUNTIME_SECRET_PATH}"
  HERMES_START_BIN="${LABNOW_HERMES_START_BIN:-$HERMES_START_BIN}"
  MANIFEST_DISCOVERY_WAIT_SECONDS="${LABNOW_MANIFEST_DISCOVERY_WAIT_SECONDS:-$MANIFEST_DISCOVERY_WAIT_SECONDS}"
  RUNTIME_MATERIAL_WAIT_SECONDS="${LABNOW_RUNTIME_MATERIAL_WAIT_SECONDS:-$RUNTIME_MATERIAL_WAIT_SECONDS}"
fi

die() {
  # Never interpolate runtime input values: RuntimeSecretFile contains a key.
  printf '%s\n' "start-labnow-hermes: $1" >&2
  exit "${2:-1}"
}

assert_wait_seconds() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -le 60 ] || die "INVALID_WAIT_CONFIGURATION" 64
}

assert_regular_file() {
  local path="$1" code="$2" label="$3"
  [ -f "$path" ] && [ ! -L "$path" ] || die "$label" "$code"
}

assert_wait_seconds "$MANIFEST_DISCOVERY_WAIT_SECONDS"
assert_wait_seconds "$RUNTIME_MATERIAL_WAIT_SECONDS"

validate_manifest() {
  assert_regular_file "$RUNTIME_MANIFEST_PATH" 67 "INVALID_MANIFEST"
  jq -e --arg version "$CONTRACT_VERSION" --arg adapter_id "$ADAPTER_ID" '
    type == "object"
    and (keys | sort) == (["adapter_id","allowed_models","api_key_file","base_url","binding_id","contract_version","default_model","expires_at","generation","lease_id","protocol","workspace_id"] | sort)
    and .contract_version == $version
    and .adapter_id == $adapter_id
    and .protocol == "openai_compatible"
    and (.workspace_id, .binding_id, .lease_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.generation | type == "number" and floor == . and . >= 1)
    and (.api_key_file == "/run/labnow/model-access/secret.json")
  ' "$RUNTIME_MANIFEST_PATH" >/dev/null || die "INVALID_MANIFEST" 67
}

runtime_material_ready() {
  # A missing file may be a normal atomic handoff in progress. An existing
  # non-regular file is a security boundary violation and must fail closed.
  if [ -e "$RUNTIME_SECRET_PATH" ] || [ -L "$RUNTIME_SECRET_PATH" ]; then
    assert_regular_file "$RUNTIME_SECRET_PATH" 68 "RUNTIME_SECRET_REQUIRED"
  else
    return 1
  fi
  if [ -e "$HERMES_MANAGED_CONFIG" ] || [ -L "$HERMES_MANAGED_CONFIG" ]; then
    assert_regular_file "$HERMES_MANAGED_CONFIG" 71 "SECURE_MANAGED_CONFIG_REQUIRED"
  else
    return 1
  fi
  if [ -e "$HERMES_BINDING_STATE" ] || [ -L "$HERMES_BINDING_STATE" ]; then
    assert_regular_file "$HERMES_BINDING_STATE" 71 "SECURE_BINDING_STATE_REQUIRED"
  else
    return 1
  fi
  [ "$(stat -c '%a' "$RUNTIME_SECRET_PATH" 2>/dev/null || stat -f '%Lp' "$RUNTIME_SECRET_PATH")" = "400" ] || die "SECURE_SECRET_MODE_REQUIRED" 65

  jq -e --arg version "$CONTRACT_VERSION" '
    type == "object"
    and (keys | sort) == (["api_key","binding_id","contract_version","generation","lease_id"] | sort)
    and .contract_version == $version
    and (.binding_id, .lease_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length >= 1 and length <= 128)
    and (.generation | type == "number" and floor == . and . >= 1)
    and (.api_key | type == "string" and length >= 16 and length <= 4096 and test("^[^[:space:]]+$"))
  ' "$RUNTIME_SECRET_PATH" >/dev/null || die "INVALID_SECRET" 68
  jq -e --slurpfile manifest "$RUNTIME_MANIFEST_PATH" '
    .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$RUNTIME_SECRET_PATH" >/dev/null || die "IDENTITY_MISMATCH" 69
  jq -e --slurpfile manifest "$RUNTIME_MANIFEST_PATH" '
    type == "object"
    and (keys | sort) == (["binding_id","generation","lease_id"] | sort)
    and .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$HERMES_BINDING_STATE" >/dev/null || return 1
  jq -e '.model.api_key == "${OPENAI_API_KEY}"' "$HERMES_MANAGED_CONFIG" >/dev/null || return 1
}

wait_for_manifest() {
  local deadline=$((SECONDS + MANIFEST_DISCOVERY_WAIT_SECONDS))
  while :; do
    if [ -e "$RUNTIME_MANIFEST_PATH" ] || [ -L "$RUNTIME_MANIFEST_PATH" ]; then
      validate_manifest
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1
  done
}

wait_for_managed_material() {
  local deadline=$((SECONDS + RUNTIME_MATERIAL_WAIT_SECONDS))
  while :; do
    if runtime_material_ready; then
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && die "RUNTIME_MATERIAL_TIMEOUT" 73
    sleep 1
  done
}

if wait_for_manifest; then
  wait_for_managed_material
  # Keep the key unexported until all identity and managed-state checks pass;
  # exec then limits it to the Hermes child environment, never argv or disk.
  api_key="$(jq -er '.api_key' "$RUNTIME_SECRET_PATH")" || die "INVALID_SECRET" 68
  export OPENAI_API_KEY="$api_key"
fi

export HERMES_HOME HERMES_MANAGED_DIR
exec "$HERMES_START_BIN" "$@"
