#!/usr/bin/env bash
# Test-only path injection for adapters. Production entrypoints always use the
# fixed RuntimeManifest, RuntimeSecretFile and RuntimeStatus contract paths.
set -Eeuo pipefail

ADAPTER_PATH="${1:?adapter path is required}"
ACTION="${2:?adapter action is required}"

case "$(basename -- "$ADAPTER_PATH")" in
  openclaw-model-access-adapter.sh|hermes-model-access-adapter.sh) ;;
  *) printf '%s\n' 'unsupported adapter test target' >&2; exit 64 ;;
esac

# Tests run inside the product test container only. util-linux flock is a hard
# prerequisite; no host emulation is provided.
command -v flock >/dev/null 2>&1 \
  || { printf '%s\n' 'FAIL: flock is required; run this test inside the product test container' >&2; exit 1; }

# shellcheck source=/dev/null
source "$ADAPTER_PATH"

LABNOW_MANIFEST_PATH="${MODEL_ACCESS_TEST_MANIFEST_PATH:?}"
LABNOW_SECRET_PATH="${MODEL_ACCESS_TEST_SECRET_PATH:?}"
LABNOW_STATUS_PATH="${MODEL_ACCESS_TEST_STATUS_PATH:?}"
LABNOW_TRUSTED_RUNTIME_ROOT="${MODEL_ACCESS_TEST_TRUSTED_RUNTIME_ROOT:-$(dirname -- "$LABNOW_STATUS_PATH")}"
labnow_adapter_dispatch "$ACTION"
