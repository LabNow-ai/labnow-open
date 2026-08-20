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

# macOS does not ship util-linux flock. This wrapper-only fallback preserves
# inter-process exclusion for host assertions; production still requires flock.
if ! command -v flock >/dev/null 2>&1; then
  flock() {
    case "$1" in
      -x)
        while ! mkdir "${LABNOW_ACTIVE_LOCK_PATH}.test-lock" 2>/dev/null; do sleep 0.02; done
        LABNOW_TEST_LOCK_DIR="${LABNOW_ACTIVE_LOCK_PATH}.test-lock"
        ;;
      -u)
        rmdir "${LABNOW_TEST_LOCK_DIR:?}" 2>/dev/null || true
        ;;
      *) printf '%s\n' 'unsupported test flock operation' >&2; return 64 ;;
    esac
  }
fi

# shellcheck source=/dev/null
source "$ADAPTER_PATH"

LABNOW_MANIFEST_PATH="${MODEL_ACCESS_TEST_MANIFEST_PATH:?}"
LABNOW_SECRET_PATH="${MODEL_ACCESS_TEST_SECRET_PATH:?}"
LABNOW_STATUS_PATH="${MODEL_ACCESS_TEST_STATUS_PATH:?}"
LABNOW_TRUSTED_RUNTIME_ROOT="${MODEL_ACCESS_TEST_TRUSTED_RUNTIME_ROOT:-$(dirname -- "$LABNOW_STATUS_PATH")}"
labnow_adapter_dispatch "$ACTION"
