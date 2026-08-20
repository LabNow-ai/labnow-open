#!/usr/bin/env bash
# Contract edge cases shared by both renderers and the Hermes startup gate.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${MODEL_ACCESS_FIXTURES_DIR:-$REPO_ROOT/../lab_project_analysis/contracts/model-access/v1alpha1/fixtures}"
[[ -d "$FIXTURES" ]] || { printf 'FAIL: contract fixtures not found at %s; set MODEL_ACCESS_FIXTURES_DIR\n' "$FIXTURES" >&2; exit 1; }
ADAPTER_WRAPPER="$REPO_ROOT/tests/helpers/run-model-access-adapter-test-wrapper.sh"
STARTER_WRAPPER="$REPO_ROOT/tests/helpers/run-start-labnow-hermes-test-wrapper.sh"
OPENCLAW_ADAPTER="$REPO_ROOT/src/labnow-open-etc/openclaw-model-access-adapter.sh"
HERMES_ADAPTER="$REPO_ROOT/src/labnow-open-etc/hermes-model-access-adapter.sh"
HERMES_STARTER="$REPO_ROOT/src/labnow-open-etc/start-labnow-hermes.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/openclaw/run" "$WORK_DIR/openclaw/state" \
  "$WORK_DIR/hermes/run" "$WORK_DIR/hermes/home" "$WORK_DIR/hermes/bin"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/openclaw/run/secret.json"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/hermes/run/secret.json"
chmod 0400 "$WORK_DIR/openclaw/run/secret.json" "$WORK_DIR/hermes/run/secret.json"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$WORK_DIR/hermes/bin/start-hermes.sh"
chmod 0700 "$WORK_DIR/hermes/bin/start-hermes.sh"

write_manifest() {
  local target="$1" adapter="$2" expires_at="$3" models_json="$4"
  jq --arg adapter "$adapter" --arg expires_at "$expires_at" --argjson models "$models_json" '
    .adapter_id = $adapter
    | .expires_at = $expires_at
    | .allowed_models = $models
    | .default_model = $models[0]
  ' "$FIXTURES/valid/runtime-manifest.json" > "$target"
}

run_openclaw() {
  local action="$1"
  MODEL_ACCESS_TEST_MANIFEST_PATH="$WORK_DIR/openclaw/run/manifest.json" \
  MODEL_ACCESS_TEST_SECRET_PATH="$WORK_DIR/openclaw/run/secret.json" \
  MODEL_ACCESS_TEST_STATUS_PATH="$WORK_DIR/openclaw/run/status.json" \
  OPENCLAW_STATE_DIR="$WORK_DIR/openclaw/state" \
  OPENCLAW_CONFIG_PATH="$WORK_DIR/openclaw/state/openclaw.json" \
  LABNOW_MODEL_ACCESS_STATE_DIR="$WORK_DIR/openclaw/state/labnow-model-access" \
  OPENCLAW_BIN=true \
  "$ADAPTER_WRAPPER" "$OPENCLAW_ADAPTER" "$action"
}

run_hermes() {
  local action="$1"
  MODEL_ACCESS_TEST_MANIFEST_PATH="$WORK_DIR/hermes/run/manifest.json" \
  MODEL_ACCESS_TEST_SECRET_PATH="$WORK_DIR/hermes/run/secret.json" \
  MODEL_ACCESS_TEST_STATUS_PATH="$WORK_DIR/hermes/run/status.json" \
  HERMES_HOME="$WORK_DIR/hermes/home" \
  HERMES_MANAGED_DIR="$WORK_DIR/hermes/home/labnow-model-access" \
  HERMES_BIN=true \
  "$ADAPTER_WRAPPER" "$HERMES_ADAPTER" "$action"
}

run_starter() {
  MODEL_ACCESS_TEST_MANIFEST_PATH="$WORK_DIR/hermes/run/manifest.json" \
  MODEL_ACCESS_TEST_SECRET_PATH="$WORK_DIR/hermes/run/secret.json" \
  MODEL_ACCESS_TEST_STATUS_PATH="$WORK_DIR/hermes/run/start-status.json" \
  MODEL_ACCESS_TEST_HERMES_START_BIN="$WORK_DIR/hermes/bin/start-hermes.sh" \
  MODEL_ACCESS_MODE=managed \
  HERMES_HOME="$WORK_DIR/hermes/home" \
  HERMES_MANAGED_DIR="$WORK_DIR/hermes/home/labnow-model-access" \
  "$STARTER_WRAPPER" "$HERMES_STARTER" gateway
}

assert_invalid_manifest() {
  local label="$1" status_file="$2" exit_code
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  exit_code=$?
  set -e
  [ "$exit_code" = 67 ] || fail "$label exit=$exit_code"
  jq -e '.phase == "failed" and .error_code == "INVALID_MANIFEST" and .message == "model access operation failed"' "$status_file" >/dev/null \
    || fail "$label did not write a sanitized failed RuntimeStatus"
}

# now>=expires_at is rejected in apply, probe and the Hermes startup gate. The
# dynamic near value is rounded to the current second, so it is at (or before)
# the validator's current time when consumed.
near_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
declare -a expiry_cases=(
  'expired|1970-01-01T00:00:00Z'
  "near|$near_now"
  'timezone-offset|1970-01-01T00:00:00+14:00'
  'fractional-seconds|1970-01-01T00:00:00.500Z'
  'invalid-format|not-a-date-time'
)

for expiry_case in "${expiry_cases[@]}"; do
  label="${expiry_case%%|*}"
  expires_at="${expiry_case#*|}"
  write_manifest "$WORK_DIR/openclaw/run/manifest.json" openclaw "$expires_at" '["model-example-chat"]'
  assert_invalid_manifest "openclaw-$label-apply" "$WORK_DIR/openclaw/run/status.json" run_openclaw apply
  assert_invalid_manifest "openclaw-$label-probe" "$WORK_DIR/openclaw/run/status.json" run_openclaw probe

  write_manifest "$WORK_DIR/hermes/run/manifest.json" hermes "$expires_at" '["model-example-chat"]'
  assert_invalid_manifest "hermes-$label-apply" "$WORK_DIR/hermes/run/status.json" run_hermes apply
  assert_invalid_manifest "hermes-$label-probe" "$WORK_DIR/hermes/run/status.json" run_hermes probe
  assert_invalid_manifest "starter-$label" "$WORK_DIR/hermes/run/start-status.json" run_starter
done

# Both consumers reject duplicates, while an unsorted but unique list remains
# legal; validation must never use jq unique's sorting as an order requirement.
write_manifest "$WORK_DIR/openclaw/run/manifest.json" openclaw '2099-01-01T00:00:00Z' '["z-model","a-model","z-model"]'
assert_invalid_manifest 'openclaw-duplicate-models' "$WORK_DIR/openclaw/run/status.json" run_openclaw apply
write_manifest "$WORK_DIR/hermes/run/manifest.json" hermes '2099-01-01T00:00:00Z' '["z-model","a-model","z-model"]'
assert_invalid_manifest 'hermes-duplicate-models' "$WORK_DIR/hermes/run/status.json" run_hermes apply

write_manifest "$WORK_DIR/openclaw/run/manifest.json" openclaw '2099-01-01T00:00:00Z' '["z-model","a-model"]'
run_openclaw apply || fail 'openclaw rejected a unique unordered model list'
write_manifest "$WORK_DIR/hermes/run/manifest.json" hermes '2099-01-01T00:00:00Z' '["z-model","a-model"]'
run_hermes apply || fail 'hermes rejected a unique unordered model list'

# RFC 3339 offset and fractional representations are valid contract values
# when they are still in the future. This prevents the negative lease tests
# above from accidentally passing because the parser rejected valid syntax.
for future_expires_at in '2099-01-01T00:00:00+14:00' '2099-01-01T00:00:00.500Z'; do
  write_manifest "$WORK_DIR/openclaw/run/manifest.json" openclaw "$future_expires_at" '["model-example-chat"]'
  run_openclaw apply || fail "openclaw rejected valid expires_at=$future_expires_at"
  write_manifest "$WORK_DIR/hermes/run/manifest.json" hermes "$future_expires_at" '["model-example-chat"]'
  run_hermes apply || fail "hermes rejected valid expires_at=$future_expires_at"
done

printf 'PASS model-access-adapter-common\n'
