#!/usr/bin/env bash
# Uses an explicitly supplied immutable Hermes image; no moving tag is accepted.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/src/labnow-open-etc/hermes-model-access-adapter.sh"
FIXTURES="/Users/chengeng/Projects/GitHub/lab_project_analysis/contracts/model-access/v1alpha1/fixtures"
HERMES_IMAGE="${HERMES_IMAGE:?set HERMES_IMAGE to an immutable quay.io/labnow/hermes@sha256 reference}"
case "$HERMES_IMAGE" in quay.io/labnow/hermes@sha256:*) ;; *) printf '%s\n' 'FAIL: HERMES_IMAGE must be an immutable quay.io/labnow/hermes digest' >&2; exit 64 ;; esac
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/status" "$WORK_DIR/hermes"
cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
jq '.adapter_id = "hermes"' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.hermes.json"
mv "$WORK_DIR/runtime/manifest.hermes.json" "$WORK_DIR/runtime/manifest.json"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
printf '%s\n' 'model: {provider: user, default: user-model}' > "$WORK_DIR/hermes/config.yaml"
chmod 0600 "$WORK_DIR/hermes/config.yaml"
user_config_hash="$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')"

run_adapter() {
  docker run --rm --platform linux/amd64 --entrypoint bash \
    -e HERMES_HOME=/root/.hermes \
    -e HERMES_MANAGED_DIR=/root/.hermes/labnow-model-access \
    -v "$ADAPTER:/usr/local/bin/hermes-model-access-adapter:ro" \
    -v "$WORK_DIR/status:/run/labnow/model-access" \
    -v "$WORK_DIR/runtime/manifest.json:/run/labnow/model-access/manifest.json:ro" \
    -v "$WORK_DIR/runtime/secret.json:/run/labnow/model-access/secret.json:ro" \
    -v "$WORK_DIR/hermes:/root/.hermes" \
    "$HERMES_IMAGE" -lc "hermes-model-access-adapter $1"
}

run_adapter apply
run_adapter probe
first_hash="$(sha256sum "$WORK_DIR/hermes/labnow-model-access/config.yaml" | awk '{print $1}')"
run_adapter apply
second_hash="$(sha256sum "$WORK_DIR/hermes/labnow-model-access/config.yaml" | awk '{print $1}')"
[ "$first_hash" = "$second_hash" ] || fail "apply is not idempotent"
[ "$user_config_hash" = "$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')" ] || fail "user config changed"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/hermes" "$WORK_DIR/status"; then fail "secret leaked into generated state"; fi

jq '.generation = 2' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.next.json"
mv "$WORK_DIR/runtime/manifest.next.json" "$WORK_DIR/runtime/manifest.json"
jq '.generation = 2' "$WORK_DIR/runtime/secret.json" > "$WORK_DIR/runtime/secret.next.json"
mv "$WORK_DIR/runtime/secret.next.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
run_adapter apply
run_adapter probe
jq -e '.generation == 2 and .phase == "ready" and .adapter_id == "hermes"' "$WORK_DIR/status/status.json" >/dev/null || fail "generation-2 RuntimeStatus"

run_adapter remove
run_adapter remove
[ ! -e "$WORK_DIR/hermes/labnow-model-access/config.yaml" ] || fail "managed config remains after remove"
[ "$user_config_hash" = "$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')" ] || fail "remove changed user config"

printf 'PASS hermes-model-access-adapter-container image=%s\n' "$HERMES_IMAGE"
