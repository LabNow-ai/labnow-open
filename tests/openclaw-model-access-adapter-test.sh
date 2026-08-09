#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/src/labnow-open-etc/openclaw-model-access-adapter.sh"
CONTRACT_DIR="/Users/chengeng/Projects/GitHub/lab_project_analysis/contracts/model-access/v1alpha1/fixtures"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run_adapter() {
  local action="$1"
  LABNOW_ALLOW_TEST_PATHS=1 \
  LABNOW_MANIFEST_PATH="$WORK_DIR/run/manifest.json" \
  LABNOW_SECRET_PATH="$WORK_DIR/run/secret.json" \
  OPENCLAW_STATE_DIR="$WORK_DIR/openclaw" \
  OPENCLAW_CONFIG_PATH="$WORK_DIR/openclaw/openclaw.json" \
  LABNOW_MODEL_ACCESS_STATE_DIR="$WORK_DIR/openclaw/labnow-model-access" \
  OPENCLAW_BIN=true \
  "$ADAPTER" "$action"
}

mkdir -p "$WORK_DIR/run" "$WORK_DIR/openclaw"
cp "$CONTRACT_DIR/valid/runtime-manifest.json" "$WORK_DIR/run/manifest.json"
cp "$CONTRACT_DIR/valid/runtime-secret-file.json" "$WORK_DIR/run/secret.json"
chmod 0400 "$WORK_DIR/run/secret.json"
# The adapter accepts overridable paths only for this isolated host-side test;
# production uses the fixture's fixed /run/labnow/model-access/secret.json.
jq --arg secret "$WORK_DIR/run/secret.json" '.api_key_file = $secret' "$WORK_DIR/run/manifest.json" > "$WORK_DIR/run/manifest.next.json"
mv "$WORK_DIR/run/manifest.next.json" "$WORK_DIR/run/manifest.json"
jq -n '{
  gateway:{mode:"local"},
  models:{providers:{"user-provider":{baseUrl:"https://example.invalid/v1",apiKey:{source:"env",provider:"user-env",id:"USER_PROVIDER_KEY"},models:[]}}},
  channels:{telegram:{enabled:true}},
  tools:{allow:["exec"]},
  skills:{entries:{"user-skill":{enabled:true}}},
  agents:{defaults:{model:{primary:"user-provider/user-model"},models:{"user-provider/user-model":{alias:"user-default"}}}}
}' > "$WORK_DIR/openclaw/openclaw.json"

capabilities="$(run_adapter capabilities)"
jq -e '.adapter_id == "openclaw" and .supports_reload == false' <<<"$capabilities" >/dev/null || fail "capabilities"

run_adapter apply
first_hash="$(sha256sum "$WORK_DIR/openclaw/openclaw.json" | awk '{print $1}')"
run_adapter apply
second_hash="$(sha256sum "$WORK_DIR/openclaw/openclaw.json" | awk '{print $1}')"
[ "$first_hash" = "$second_hash" ] || fail "apply is not idempotent"
run_adapter probe
jq -e '.phase == "ready" and .generation == 1 and has("api_key") | not' "$WORK_DIR/openclaw/labnow-model-access/status.json" >/dev/null || fail "ready status"
jq -e '
  .models.providers["user-provider"]
  and .channels.telegram.enabled
  and .tools.allow == ["exec"]
  and .skills.entries["user-skill"].enabled
  and .agents.defaults.model.primary == "user-provider/user-model"
  and .models.providers.labnow.apiKey.source == "file"
  and .models.providers.labnow.apiKey.provider == "labnow-runtime"
  and .models.providers.labnow.apiKey.id == "/api_key"
  and (.secrets.providers["labnow-runtime"].path | endswith("/secret.json"))
' "$WORK_DIR/openclaw/openclaw.json" >/dev/null || fail "ownership preservation or SecretRef"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/openclaw"; then fail "secret leaked into generated state"; fi

jq '.generation = 2' "$WORK_DIR/run/manifest.json" > "$WORK_DIR/run/manifest.next.json"
mv "$WORK_DIR/run/manifest.next.json" "$WORK_DIR/run/manifest.json"
jq '.generation = 2' "$WORK_DIR/run/secret.json" > "$WORK_DIR/run/secret.next.json"
mv "$WORK_DIR/run/secret.next.json" "$WORK_DIR/run/secret.json"
chmod 0400 "$WORK_DIR/run/secret.json"
run_adapter apply
jq -e '.generation == 2' "$WORK_DIR/openclaw/labnow-model-access/status.json" >/dev/null || fail "rotation generation"

run_adapter remove
first_remove_hash="$(sha256sum "$WORK_DIR/openclaw/openclaw.json" | awk '{print $1}')"
run_adapter remove
second_remove_hash="$(sha256sum "$WORK_DIR/openclaw/openclaw.json" | awk '{print $1}')"
[ "$first_remove_hash" = "$second_remove_hash" ] || fail "remove is not idempotent"
jq -e '
  (.models.providers | has("labnow") | not)
  and (.secrets.providers | has("labnow-runtime") | not)
  and (.agents.defaults.models | has("labnow/model-example-chat") | not)
  and .agents.defaults.model.primary == "user-provider/user-model"
' "$WORK_DIR/openclaw/openclaw.json" >/dev/null || fail "remove preservation"

for fixture in "$CONTRACT_DIR"/invalid/runtime-manifest-default-not-allowed.json "$CONTRACT_DIR"/invalid/runtime-manifest-wrong-version.json; do
  cp "$fixture" "$WORK_DIR/run/manifest.json"
  if run_adapter apply >/dev/null 2>&1; then fail "invalid manifest was accepted: $(basename "$fixture")"; fi
done
cp "$CONTRACT_DIR/valid/runtime-manifest.json" "$WORK_DIR/run/manifest.json"
jq --arg secret "$WORK_DIR/run/secret.json" '.api_key_file = $secret' "$WORK_DIR/run/manifest.json" > "$WORK_DIR/run/manifest.next.json"
mv "$WORK_DIR/run/manifest.next.json" "$WORK_DIR/run/manifest.json"
jq '.binding_id = "wrong-binding"' "$WORK_DIR/run/secret.json" > "$WORK_DIR/run/secret.next.json"
mv "$WORK_DIR/run/secret.next.json" "$WORK_DIR/run/secret.json"
chmod 0400 "$WORK_DIR/run/secret.json"
if run_adapter apply >/dev/null 2>&1; then fail "mismatched secret was accepted"; fi

printf 'PASS openclaw-model-access-adapter\n'
