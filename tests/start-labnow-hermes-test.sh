#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTER="$REPO_ROOT/src/labnow-open-etc/start-labnow-hermes.sh"
FIXTURES="/Users/chengeng/Projects/GitHub/lab_project_analysis/contracts/model-access/v1alpha1/fixtures"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/hermes/labnow-model-access/state" "$WORK_DIR/bin" "$WORK_DIR/runtime"

cat > "$WORK_DIR/bin/start-hermes.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${HERMES_HOME:-}" = "$EXPECTED_HERMES_HOME" ]
[ "${HERMES_MANAGED_DIR:-}" = "$EXPECTED_HERMES_MANAGED_DIR" ]
case "${EXPECT_MANAGED:-}" in
  1) [ -n "${OPENAI_API_KEY:-}" ] && [[ "$OPENAI_API_KEY" =~ ^[^[:space:]]+$ ]] ;;
  0) [ -z "${OPENAI_API_KEY:-}" ] ;;
  *) exit 64 ;;
esac
printf '%s\n' "${1:-missing}:managed=${EXPECT_MANAGED}" >> "$START_RESULT"
EOF
chmod 0700 "$WORK_DIR/bin/start-hermes.sh"

write_runtime() {
  local generation="$1"
  jq --argjson generation "$generation" '.adapter_id = "hermes" | .generation = $generation' \
    "$FIXTURES/valid/runtime-manifest.json" > "$WORK_DIR/runtime/manifest.json"
  jq --argjson generation "$generation" '.generation = $generation' \
    "$FIXTURES/valid/runtime-secret-file.json" > "$WORK_DIR/runtime/secret.json"
  chmod 0600 "$WORK_DIR/runtime/manifest.json"
  chmod 0400 "$WORK_DIR/runtime/secret.json"
}

write_managed_scope() {
  local generation="$1"
  printf '%s\n' '{"model":{"provider":"custom","api_key":"${OPENAI_API_KEY}"}}' > "$WORK_DIR/hermes/labnow-model-access/config.yaml"
  jq -n --slurpfile manifest "$WORK_DIR/runtime/manifest.json" '
    {binding_id:$manifest[0].binding_id, lease_id:$manifest[0].lease_id, generation:$manifest[0].generation}
  ' > "$WORK_DIR/hermes/labnow-model-access/state/binding.json"
  chmod 0600 "$WORK_DIR/hermes/labnow-model-access/config.yaml" "$WORK_DIR/hermes/labnow-model-access/state/binding.json"
}

assert_coherent_scope() {
  jq -e --slurpfile manifest "$WORK_DIR/runtime/manifest.json" '
    .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$WORK_DIR/runtime/secret.json" >/dev/null || fail "test runtime secret identity"
  jq -e --slurpfile manifest "$WORK_DIR/runtime/manifest.json" '
    .binding_id == $manifest[0].binding_id
    and .lease_id == $manifest[0].lease_id
    and .generation == $manifest[0].generation
  ' "$WORK_DIR/hermes/labnow-model-access/state/binding.json" >/dev/null || fail "test binding state identity"
  jq -e '.model.api_key == "${OPENAI_API_KEY}"' "$WORK_DIR/hermes/labnow-model-access/config.yaml" >/dev/null || fail "test managed SecretRef"
}

run_starter() {
  local managed="$1" service="$2" result="$3"
  env -i \
    PATH="$PATH" \
    LABNOW_ALLOW_TEST_PATHS=1 \
    LABNOW_MANIFEST_PATH="$WORK_DIR/runtime/manifest.json" \
    LABNOW_RUNTIME_SECRET_PATH="$WORK_DIR/runtime/secret.json" \
    LABNOW_HERMES_START_BIN="$WORK_DIR/bin/start-hermes.sh" \
    LABNOW_MANIFEST_DISCOVERY_WAIT_SECONDS="${LABNOW_MANIFEST_DISCOVERY_WAIT_SECONDS:-1}" \
    LABNOW_RUNTIME_MATERIAL_WAIT_SECONDS="${LABNOW_RUNTIME_MATERIAL_WAIT_SECONDS:-2}" \
    HERMES_HOME="$WORK_DIR/hermes" \
    HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
    EXPECTED_HERMES_HOME="$WORK_DIR/hermes" \
    EXPECTED_HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
    EXPECT_MANAGED="$managed" \
    START_RESULT="$result" \
    "$STARTER" "$service"
}

# Existing coherent material starts all three consumers with an environment-only
# key. The fake launcher records only the service and a non-sensitive boolean.
write_runtime 1
write_managed_scope 1
assert_coherent_scope
RESULT="$WORK_DIR/started.log"
run_starter 1 gateway "$RESULT"
run_starter 1 dashboard "$RESULT"
run_starter 1 tui "$RESULT"
[ "$(wc -l < "$RESULT" | tr -d ' ')" = "3" ] || fail "managed consumers did not all start"
rg -qx 'gateway:managed=1' "$RESULT" && rg -qx 'dashboard:managed=1' "$RESULT" && rg -qx 'tui:managed=1' "$RESULT" || fail "managed service environment"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/hermes" "$RESULT"; then
  fail "secret leaked by starter"
fi

# A cold start can see neither manifest nor config when supervisord starts.
# Once a Hermes manifest appears, the wrapper must wait for the matching secret
# and binding state, not start with the config's literal SecretRef.
rm -f "$WORK_DIR/runtime/manifest.json" "$WORK_DIR/runtime/secret.json" \
  "$WORK_DIR/hermes/labnow-model-access/config.yaml" "$WORK_DIR/hermes/labnow-model-access/state/binding.json"
COLD_RESULT="$WORK_DIR/cold-start.log"
LABNOW_MANIFEST_DISCOVERY_WAIT_SECONDS=5 LABNOW_RUNTIME_MATERIAL_WAIT_SECONDS=5 \
  run_starter 1 gateway "$COLD_RESULT" &
cold_pid=$!
sleep 1
write_runtime 2
sleep 1
write_managed_scope 2
assert_coherent_scope
wait "$cold_pid" || fail "cold managed start"
rg -qx 'gateway:managed=1' "$COLD_RESULT" || fail "cold start did not inject managed key"

# A Hermes manifest without coherent material fails closed. A subsequent
# supervisor restart succeeds once the same generation's material is present.
rm -f "$WORK_DIR/runtime/secret.json" "$WORK_DIR/hermes/labnow-model-access/config.yaml" "$WORK_DIR/hermes/labnow-model-access/state/binding.json"
TIMEOUT_RESULT="$WORK_DIR/timeout.log"
set +e
LABNOW_RUNTIME_MATERIAL_WAIT_SECONDS=0 run_starter 1 dashboard "$TIMEOUT_RESULT" >/dev/null 2>&1
timeout_exit=$?
set -e
[ "$timeout_exit" = "73" ] || fail "managed startup timeout error code: $timeout_exit"
[ ! -e "$TIMEOUT_RESULT" ] || fail "timed-out managed process started"
write_runtime 2
write_managed_scope 2
run_starter 1 dashboard "$TIMEOUT_RESULT"
rg -qx 'dashboard:managed=1' "$TIMEOUT_RESULT" || fail "restart did not recover managed startup"

# With no RuntimeManifest, the same image is unbound and must not wait for or
# read a SecretFile. This keeps existing unmanaged workspaces operational.
rm -f "$WORK_DIR/runtime/manifest.json" "$WORK_DIR/runtime/secret.json" \
  "$WORK_DIR/hermes/labnow-model-access/config.yaml" "$WORK_DIR/hermes/labnow-model-access/state/binding.json"
UNMANAGED_RESULT="$WORK_DIR/unmanaged.log"
LABNOW_MANIFEST_DISCOVERY_WAIT_SECONDS=0 run_starter 0 dashboard "$UNMANAGED_RESULT"
rg -qx 'dashboard:managed=0' "$UNMANAGED_RESULT" || fail "unmanaged start"

printf 'PASS start-labnow-hermes\n'
