#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/src/labnow-open-etc/openclaw-model-access-adapter.sh"
FIXTURES="/Users/chengeng/Projects/GitHub/lab_project_analysis/contracts/model-access/v1alpha1/fixtures"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-quay.io/labnow/openclaw@sha256:edc85cc2068f5ec0df470f7d06daa0a4fbd78ef5ad6cf5b48f58381da839dd12}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_runtime_status() {
  local expected_phase="$1" expected_generation="$2"
  jq -e --arg phase "$expected_phase" --argjson generation "$expected_generation" '
    type == "object"
    and (keys | sort) == (["adapter_id","binding_id","contract_version","generation","lease_id","observed_at","phase","workspace_id"] | sort)
    and .contract_version == "v1alpha1"
    and (.workspace_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length <= 128)
    and (.binding_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length <= 128)
    and (.lease_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]*$") and length <= 128)
    and .generation == $generation
    and .adapter_id == "openclaw"
    and .phase == $phase
    and (.observed_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+Z$"))
  ' "$WORK_DIR/status/status.json" >/dev/null || fail "RuntimeStatus schema: $expected_phase"
}
mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/status" "$WORK_DIR/data"
cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
touch "$WORK_DIR/status/manifest.json" "$WORK_DIR/status/secret.json"
chmod 0600 "$WORK_DIR/status/manifest.json" "$WORK_DIR/status/secret.json"
jq -n '{
  gateway:{mode:"local"},
  models:{providers:{"user-provider":{baseUrl:"https://example.invalid/v1",apiKey:{source:"env",provider:"user-env",id:"USER_PROVIDER_KEY"},models:[]}}},
  channels:{telegram:{enabled:true}},
  tools:{allow:["exec"]},
  skills:{entries:{"user-skill":{enabled:true}}},
  agents:{defaults:{model:{primary:"user-provider/user-model"},models:{"user-provider/user-model":{alias:"user-default"}}}}
}' > "$WORK_DIR/data/openclaw.json"

run_adapter() {
  docker run --rm --platform linux/amd64 \
    --entrypoint bash \
    -e OPENCLAW_CONFIG=/root/.openclaw/data/openclaw.json \
    -e OPENCLAW_STATE_DIR=/root/.openclaw/data \
    -v "$ADAPTER:/usr/local/bin/openclaw-model-access-adapter:ro" \
    -v "$WORK_DIR/status:/run/labnow/model-access" \
    -v "$WORK_DIR/runtime/manifest.json:/run/labnow/model-access/manifest.json:ro" \
    -v "$WORK_DIR/runtime/secret.json:/run/labnow/model-access/secret.json:ro" \
    -v "$WORK_DIR/data:/root/.openclaw/data" \
    "$OPENCLAW_IMAGE" -lc "env -u OPENCLAW_CONFIG_PATH openclaw-model-access-adapter $1"
}

validate_config() {
  # This direct OpenClaw schema check needs the upstream CLI path variable.
  # run_adapter explicitly unsets it so Adapter probe covers the regression.
  docker run --rm --platform linux/amd64 \
    --entrypoint bash \
    -e OPENCLAW_CONFIG=/root/.openclaw/data/openclaw.json \
    -e OPENCLAW_STATE_DIR=/root/.openclaw/data \
    -e OPENCLAW_CONFIG_PATH=/root/.openclaw/data/openclaw.json \
    -v "$WORK_DIR/status:/run/labnow/model-access" \
    -v "$WORK_DIR/runtime/manifest.json:/run/labnow/model-access/manifest.json:ro" \
    -v "$WORK_DIR/runtime/secret.json:/run/labnow/model-access/secret.json:ro" \
    -v "$WORK_DIR/data:/root/.openclaw/data" \
    "$OPENCLAW_IMAGE" -lc 'openclaw config validate'
}

run_adapter apply
assert_runtime_status applied 1
validate_config
run_adapter probe
assert_runtime_status ready 1
jq -e '
  .models.providers["user-provider"]
  and .channels.telegram.enabled
  and .tools.allow == ["exec"]
  and .skills.entries["user-skill"].enabled
  and .agents.defaults.model.primary == "user-provider/user-model"
  and .models.providers.labnow.apiKey == {source:"file",provider:"labnow-runtime",id:"/api_key"}
' "$WORK_DIR/data/openclaw.json" >/dev/null || fail "managed config does not preserve user-owned fields"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/data"; then fail "secret leaked into OpenClaw state"; fi

run_adapter remove
assert_runtime_status removed 1
jq -e '(.models.providers | has("labnow") | not) and (.secrets.providers | has("labnow-runtime") | not)' "$WORK_DIR/data/openclaw.json" >/dev/null || fail "remove left managed OpenClaw config"

printf 'PASS openclaw-model-access-adapter-container image=%s\n' "$OPENCLAW_IMAGE"
