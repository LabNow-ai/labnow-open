#!/usr/bin/env bash
# Test-only dependency injection for the sourceable OpenClaw starter.
set -Eeuo pipefail

STARTER_PATH="${1:?starter path is required}"
ADAPTER_PATH="$(dirname -- "$STARTER_PATH")/openclaw-model-access-adapter.sh"
ADAPTER_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-model-access-adapter-test-wrapper.sh"
OPENCLAW_CONFIG="${MODEL_ACCESS_TEST_OPENCLAW_CONFIG_PATH:?}"
OPENCLAW_STATE_DIR="${MODEL_ACCESS_TEST_OPENCLAW_STATE_DIR:?}"
# shellcheck source=/dev/null
source "$STARTER_PATH"

LABNOW_MANIFEST_PATH="${MODEL_ACCESS_TEST_MANIFEST_PATH:?}"
LABNOW_SECRET_PATH="${MODEL_ACCESS_TEST_SECRET_PATH:?}"
LABNOW_STATUS_PATH="${MODEL_ACCESS_TEST_STATUS_PATH:?}"
LABNOW_TRUSTED_RUNTIME_ROOT="$(dirname -- "$LABNOW_STATUS_PATH")"
export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH

openclaw_model_access_action() {
  MODEL_ACCESS_TEST_MANIFEST_PATH="$LABNOW_MANIFEST_PATH" \
  MODEL_ACCESS_TEST_SECRET_PATH="$LABNOW_SECRET_PATH" \
  MODEL_ACCESS_TEST_STATUS_PATH="$LABNOW_STATUS_PATH" \
  MODEL_ACCESS_TEST_TRUSTED_RUNTIME_ROOT="$LABNOW_TRUSTED_RUNTIME_ROOT" \
  LABNOW_MODEL_ACCESS_STATE_DIR="${OPENCLAW_STATE_DIR}/labnow-model-access" \
  OPENCLAW_BIN=true \
  "$ADAPTER_WRAPPER" "$ADAPTER_PATH" "$1"
}

openclaw_exec_gateway() {
  exec "${MODEL_ACCESS_TEST_OPENCLAW_START_BIN:?}" gateway
}

start_labnow_openclaw "${@:2}"
