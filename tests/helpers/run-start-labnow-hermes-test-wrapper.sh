#!/usr/bin/env bash
# Test-only path injection for the sourceable Hermes starter implementation.
set -Eeuo pipefail

STARTER_PATH="${1:?starter path is required}"
ADAPTER_PATH="$(dirname -- "$STARTER_PATH")/hermes-model-access-adapter.sh"
ADAPTER_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-model-access-adapter-test-wrapper.sh"
# shellcheck source=/dev/null
source "$STARTER_PATH"

LABNOW_MANIFEST_PATH="${MODEL_ACCESS_TEST_MANIFEST_PATH:?}"
LABNOW_SECRET_PATH="${MODEL_ACCESS_TEST_SECRET_PATH:?}"
LABNOW_STATUS_PATH="${MODEL_ACCESS_TEST_STATUS_PATH:?}"
LABNOW_TRUSTED_RUNTIME_ROOT="$(dirname -- "$LABNOW_STATUS_PATH")"
HERMES_START_BIN="${MODEL_ACCESS_TEST_HERMES_START_BIN:?}"
hermes_model_access_action() {
  MODEL_ACCESS_TEST_MANIFEST_PATH="$LABNOW_MANIFEST_PATH" \
  MODEL_ACCESS_TEST_SECRET_PATH="$LABNOW_SECRET_PATH" \
  MODEL_ACCESS_TEST_STATUS_PATH="$LABNOW_STATUS_PATH" \
  MODEL_ACCESS_TEST_TRUSTED_RUNTIME_ROOT="$LABNOW_TRUSTED_RUNTIME_ROOT" \
  HERMES_HOME="$HERMES_HOME" \
  HERMES_MANAGED_DIR="$HERMES_MANAGED_DIR" \
  HERMES_BIN=true \
  "$ADAPTER_WRAPPER" "$ADAPTER_PATH" "$1"
}
start_labnow_hermes "${@:2}"
