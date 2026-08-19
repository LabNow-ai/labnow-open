#!/usr/bin/env bash
# Starts Hermes only after a LabNow-managed runtime is coherent. The generated
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
# A short discovery period lets the Launcher materialize a RuntimeManifest
# after supervisord starts, without making unmanaged Hermes workspaces wait for
# a SecretFile. Once a Hermes manifest is found, the bounded material wait
# fails closed rather than starting with a literal ${OPENAI_API_KEY}.
MANIFEST_DISCOVERY_WAIT_SECONDS=10
RUNTIME_MATERIAL_WAIT_SECONDS=30

hermes_assert_wait_seconds() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -le 60 ] || labnow_die "INVALID_WAIT_CONFIGURATION"
}

hermes_runtime_material_ready() {
  # A missing file may be an atomic handoff in progress. An existing
  # non-regular file is a security boundary violation and must fail closed.
  if [ -e "$LABNOW_SECRET_PATH" ] || [ -L "$LABNOW_SECRET_PATH" ]; then
    labnow_assert_regular_file "$LABNOW_SECRET_PATH" "INVALID_SECRET"
  else
    return 1
  fi
  if [ -e "$HERMES_MANAGED_CONFIG" ] || [ -L "$HERMES_MANAGED_CONFIG" ]; then
    labnow_assert_regular_file "$HERMES_MANAGED_CONFIG" "MANAGED_CONFIG_MISSING"
  else
    return 1
  fi
  if [ -e "$HERMES_BINDING_STATE" ] || [ -L "$HERMES_BINDING_STATE" ]; then
    labnow_assert_regular_file "$HERMES_BINDING_STATE" "MANAGED_CONFIG_MISSING"
  else
    return 1
  fi

  labnow_validate_secret
  jq -e --slurpfile manifest "$LABNOW_MANIFEST_PATH" '
    type == "object"
    and (keys | sort) == (["binding_id","generation","lease_id"] | sort)
    and .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$HERMES_BINDING_STATE" >/dev/null || return 1
  jq -e '.model.api_key == "${OPENAI_API_KEY}"' "$HERMES_MANAGED_CONFIG" >/dev/null || return 1
}

hermes_wait_for_manifest() {
  local deadline=$((SECONDS + MANIFEST_DISCOVERY_WAIT_SECONDS))
  while :; do
    if [ -e "$LABNOW_MANIFEST_PATH" ] || [ -L "$LABNOW_MANIFEST_PATH" ]; then
      labnow_validate_manifest
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1
  done
}

hermes_wait_for_managed_material() {
  local deadline=$((SECONDS + RUNTIME_MATERIAL_WAIT_SECONDS))
  while :; do
    if hermes_runtime_material_ready; then
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && labnow_die "RUNTIME_MATERIAL_TIMEOUT"
    sleep 1
  done
}

start_labnow_hermes() {
  local api_key
  hermes_assert_wait_seconds "$MANIFEST_DISCOVERY_WAIT_SECONDS"
  hermes_assert_wait_seconds "$RUNTIME_MATERIAL_WAIT_SECONDS"
  if hermes_wait_for_manifest; then
    hermes_wait_for_managed_material
    # Keep the key unexported until all identity and managed-state checks pass;
    # exec limits it to the Hermes child environment, never argv or disk.
    api_key="$(jq -er '.api_key' "$LABNOW_SECRET_PATH")" || labnow_die "INVALID_SECRET"
    export OPENAI_API_KEY="$api_key"
  fi
  export HERMES_HOME HERMES_MANAGED_DIR
  exec "$HERMES_START_BIN" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  start_labnow_hermes "$@"
fi
