#!/usr/bin/env bash
# X-02 consumer tests for the OpenClaw starter's explicit mode state machine.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTER="$REPO_ROOT/src/labnow-open-etc/start-labnow-openclaw.sh"
TEST_WRAPPER="$REPO_ROOT/tests/helpers/run-start-labnow-openclaw-test-wrapper.sh"
FIXTURES="${MODEL_ACCESS_FIXTURES_DIR:-$REPO_ROOT/../lab_project_analysis/contracts/model-access/v1alpha1/fixtures}"
[[ -d "$FIXTURES" ]] || { printf 'FAIL: contract fixtures not found at %s; set MODEL_ACCESS_FIXTURES_DIR\n' "$FIXTURES" >&2; exit 1; }
WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -depth -delete' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/openclaw" "$WORK_DIR/bin" "$WORK_DIR/runtime"
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
  'case "${EXPECT_MANAGED:?}" in 1) test -f "${EXPECTED_CONFIG:?}" ;; 0) test ! -e "${EXPECTED_CONFIG:?}" || true ;; *) exit 64 ;; esac' \
  'printf "%s\\n" "${1:-missing}:managed=${EXPECT_MANAGED}" >> "${START_RESULT:?}"' \
  > "$WORK_DIR/bin/start-openclaw.sh"
chmod 0700 "$WORK_DIR/bin/start-openclaw.sh"

write_runtime() {
  cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
  cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/runtime/secret.json"
  chmod 0600 "$WORK_DIR/runtime/manifest.json"
  chmod 0400 "$WORK_DIR/runtime/secret.json"
}

run_starter() {
  local mode="$1" result="$2" expected_managed="$3"
  env -i \
    PATH="$PATH" \
    MODEL_ACCESS_MODE="$mode" \
    MODEL_ACCESS_TEST_MANIFEST_PATH="$WORK_DIR/runtime/manifest.json" \
    MODEL_ACCESS_TEST_SECRET_PATH="$WORK_DIR/runtime/secret.json" \
    MODEL_ACCESS_TEST_STATUS_PATH="$WORK_DIR/runtime/status.json" \
    MODEL_ACCESS_TEST_OPENCLAW_STATE_DIR="$WORK_DIR/openclaw" \
    MODEL_ACCESS_TEST_OPENCLAW_CONFIG_PATH="$WORK_DIR/openclaw/openclaw.json" \
    MODEL_ACCESS_TEST_OPENCLAW_START_BIN="$WORK_DIR/bin/start-openclaw.sh" \
    EXPECT_MANAGED="$expected_managed" \
    EXPECTED_CONFIG="$WORK_DIR/openclaw/openclaw.json" \
    START_RESULT="$result" \
    "$TEST_WRAPPER" "$STARTER"
}

expect_exit() {
  local expected="$1" label="$2" actual
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [ "$actual" = "$expected" ] || fail "$label exit=$actual expected=$expected"
}

write_runtime
MANAGED_RESULT="$WORK_DIR/managed.log"
run_starter managed "$MANAGED_RESULT" 1
rg -qx 'gateway:managed=1' "$MANAGED_RESULT" || fail 'managed OpenClaw did not start'
jq -e '.phase == "ready" and .adapter_id == "openclaw"' "$WORK_DIR/runtime/status.json" >/dev/null || fail 'managed OpenClaw did not probe ready'
jq -e '.models.providers.labnow and .gateway.controlUi.basePath == "/openclaw"' "$WORK_DIR/openclaw/openclaw.json" >/dev/null || fail 'managed OpenClaw did not retain managed config and gateway path'
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/openclaw" "$MANAGED_RESULT"; then fail 'OpenClaw starter leaked secret'; fi

find "$WORK_DIR/runtime" -mindepth 1 -maxdepth 1 -delete
MISSING_RESULT="$WORK_DIR/missing.log"
expect_exit 66 'managed missing manifest' run_starter managed "$MISSING_RESULT" 1
[ ! -e "$MISSING_RESULT" ] || fail 'managed missing material started OpenClaw'

UNMANAGED_RESULT="$WORK_DIR/unmanaged.log"
run_starter unmanaged "$UNMANAGED_RESULT" 0
rg -qx 'gateway:managed=0' "$UNMANAGED_RESULT" || fail 'unmanaged OpenClaw did not start natively'

MISSING_MODE_RESULT="$WORK_DIR/missing-mode.log"
set +e
env -i PATH="$PATH" \
  MODEL_ACCESS_TEST_MANIFEST_PATH="$WORK_DIR/runtime/manifest.json" \
  MODEL_ACCESS_TEST_SECRET_PATH="$WORK_DIR/runtime/secret.json" \
  MODEL_ACCESS_TEST_STATUS_PATH="$WORK_DIR/runtime/status.json" \
  MODEL_ACCESS_TEST_OPENCLAW_STATE_DIR="$WORK_DIR/openclaw" \
  MODEL_ACCESS_TEST_OPENCLAW_CONFIG_PATH="$WORK_DIR/openclaw/openclaw.json" \
  MODEL_ACCESS_TEST_OPENCLAW_START_BIN="$WORK_DIR/bin/start-openclaw.sh" \
  EXPECT_MANAGED=0 EXPECTED_CONFIG="$WORK_DIR/openclaw/openclaw.json" START_RESULT="$MISSING_MODE_RESULT" \
  "$TEST_WRAPPER" "$STARTER" >/dev/null 2>&1
missing_mode_exit=$?
set -e
[ "$missing_mode_exit" = 75 ] || fail "missing MODE exit=$missing_mode_exit"
[ ! -e "$MISSING_MODE_RESULT" ] || fail 'missing MODE started OpenClaw'
expect_exit 76 'invalid MODE' run_starter unsupported "$WORK_DIR/invalid-mode.log" 0

printf 'PASS start-labnow-openclaw\n'
