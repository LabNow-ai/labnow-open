#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/src/labnow-open-etc/hermes-model-access-adapter.sh"
TEST_WRAPPER="$REPO_ROOT/tests/helpers/run-model-access-adapter-test-wrapper.sh"
FIXTURES="/Users/chengeng/Projects/GitHub/lab_project_analysis/contracts/model-access/v1alpha1/fixtures"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_runtime_status() {
  local expected_phase="$1" expected_generation="$2"
  jq -e --arg phase "$expected_phase" --argjson generation "$expected_generation" '
    type == "object"
    and (keys | sort) == (["adapter_id","binding_id","contract_version","generation","lease_id","observed_at","phase","workspace_id"] | sort)
    and .adapter_id == "hermes"
    and .contract_version == "v1alpha1"
    and .generation == $generation
    and .phase == $phase
  ' "$WORK_DIR/runtime/status.json" >/dev/null || fail "RuntimeStatus schema: $expected_phase"
}

run_adapter() {
  local action="$1"
  MODEL_ACCESS_TEST_MANIFEST_PATH="$WORK_DIR/runtime/manifest.json" \
  MODEL_ACCESS_TEST_SECRET_PATH="$WORK_DIR/runtime/secret.json" \
  MODEL_ACCESS_TEST_STATUS_PATH="$WORK_DIR/runtime/status.json" \
  HERMES_HOME="$WORK_DIR/hermes" \
  HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
  HERMES_BIN=true \
  "$TEST_WRAPPER" "$ADAPTER" "$action"
}

mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/hermes"
cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
jq '.adapter_id = "hermes" | .expires_at = "2099-01-01T00:00:00.123Z"' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.hermes.json"
mv "$WORK_DIR/runtime/manifest.hermes.json" "$WORK_DIR/runtime/manifest.json"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
printf '%s\n' 'model: {provider: user, default: user-model}' > "$WORK_DIR/hermes/config.yaml"
chmod 0600 "$WORK_DIR/hermes/config.yaml"
user_config_hash="$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')"

capabilities="$(run_adapter capabilities)"
jq -e '.adapter_id == "hermes" and .supports_reload == false' <<<"$capabilities" >/dev/null || fail "capabilities"

run_adapter apply
assert_runtime_status applied 1
first_hash="$(sha256sum "$WORK_DIR/hermes/labnow-model-access/config.yaml" | awk '{print $1}')"
run_adapter apply
assert_runtime_status applied 1
second_hash="$(sha256sum "$WORK_DIR/hermes/labnow-model-access/config.yaml" | awk '{print $1}')"
[ "$first_hash" = "$second_hash" ] || fail "apply is not idempotent"
run_adapter probe
assert_runtime_status ready 1
[ "$user_config_hash" = "$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')" ] || fail "user config changed"
jq -e '
  .model.provider == "custom"
  and .model.default == "model-example-chat"
  and .model.api_key == "${OPENAI_API_KEY}"
' "$WORK_DIR/hermes/labnow-model-access/config.yaml" >/dev/null || fail "managed Hermes config"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/hermes/labnow-model-access"; then fail "secret leaked into managed config"; fi

jq '.generation = 2' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.next.json"
mv "$WORK_DIR/runtime/manifest.next.json" "$WORK_DIR/runtime/manifest.json"
jq '.generation = 2' "$WORK_DIR/runtime/secret.json" > "$WORK_DIR/runtime/secret.next.json"
mv -f "$WORK_DIR/runtime/secret.next.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
run_adapter apply
assert_runtime_status applied 2
jq -e '.generation == 2' "$WORK_DIR/hermes/labnow-model-access/state/binding.json" >/dev/null || fail "generation state"
# supports_reload=false requires the caller to use a controlled restart. A new
# probe is the adapter boundary that validates generation 2 after that restart.
run_adapter probe
assert_runtime_status ready 2

run_adapter remove
assert_runtime_status removed 2
first_remove_hash="$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')"
run_adapter remove
assert_runtime_status removed 2
second_remove_hash="$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')"
[ "$first_remove_hash" = "$second_remove_hash" ] || fail "remove is not idempotent"
[ ! -e "$WORK_DIR/hermes/labnow-model-access/config.yaml" ] || fail "managed config remains after remove"
[ "$user_config_hash" = "$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')" ] || fail "remove changed user config"

for fixture in "$FIXTURES"/invalid/runtime-manifest-default-not-allowed.json "$FIXTURES"/invalid/runtime-manifest-wrong-version.json; do
  cp "$fixture" "$WORK_DIR/runtime/manifest.json"
  jq '.adapter_id = "hermes"' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.hermes.json"
  mv "$WORK_DIR/runtime/manifest.hermes.json" "$WORK_DIR/runtime/manifest.json"
  set +e
  run_adapter apply >/dev/null 2>&1
  fixture_exit=$?
  set -e
  [ "$fixture_exit" = 67 ] || fail "invalid manifest error code: $(basename "$fixture")=$fixture_exit"
done

cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
jq '.adapter_id = "openclaw"' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.wrong-adapter.json"
mv "$WORK_DIR/runtime/manifest.wrong-adapter.json" "$WORK_DIR/runtime/manifest.json"
set +e
run_adapter apply >/dev/null 2>&1
wrong_adapter_exit=$?
set -e
[ "$wrong_adapter_exit" = 67 ] || fail "wrong adapter error code: $wrong_adapter_exit"

cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
jq '.adapter_id = "hermes"' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.hermes.json"
mv "$WORK_DIR/runtime/manifest.hermes.json" "$WORK_DIR/runtime/manifest.json"
jq '.generation = 1' "$WORK_DIR/runtime/secret.json" > "$WORK_DIR/runtime/secret.reset.json"
mv -f "$WORK_DIR/runtime/secret.reset.json" "$WORK_DIR/runtime/secret.json"
chmod 0600 "$WORK_DIR/runtime/secret.json"
set +e
run_adapter apply >/dev/null 2>&1
mode_exit=$?
set -e
[ "$mode_exit" = 65 ] || fail "secret mode error code: $mode_exit"
chmod 0400 "$WORK_DIR/runtime/secret.json"
jq '.binding_id = "wrong-binding"' "$WORK_DIR/runtime/secret.json" > "$WORK_DIR/runtime/secret.next.json"
mv -f "$WORK_DIR/runtime/secret.next.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
set +e
run_adapter apply >/dev/null 2>&1
mismatch_exit=$?
set -e
[ "$mismatch_exit" = 69 ] || fail "mismatched secret error code: $mismatch_exit"

printf 'PASS hermes-model-access-adapter\n'
