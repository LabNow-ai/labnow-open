#!/usr/bin/env bash
# Safe, repeatable P2-R2 evidence runner. It accepts only file paths and
# non-sensitive identifiers; RuntimeSecretFile contents never reach stdout,
# command arguments, or the JSON report.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$REPO_ROOT/src/labnow-open-etc/openclaw-model-access-adapter.sh"
CONTRACT_BUNDLE="0.1.0-candidate.2"
CONTRACT_VERSION="v1alpha1"
STAGE=""
REPORT=""
GENERATION_1_MANIFEST=""
GENERATION_1_SECRET=""
GENERATION_2_MANIFEST=""
GENERATION_2_SECRET=""
MODEL=""
OPENCLAW_IMAGE=""
LITELLM_IMAGE=""

usage() {
  cat <<'EOF'
Usage:
  openclaw-model-access-adapter-real-evidence.sh \
    --stage pre-revoke|post-revoke --report /absolute/path/report.json \
    --generation-1-manifest /absolute/path/manifest.json \
    --generation-1-secret /absolute/path/secret.json \
    --generation-2-manifest /absolute/path/manifest.json \
    --generation-2-secret /absolute/path/secret.json \
    --model INTERNAL_MODEL --openclaw-image IMAGE@sha256:DIGEST \
    --litellm-image IMAGE@sha256:DIGEST

The report records parameter names only, never secret paths or contents. Run
pre-revoke first; revoke generation 1 outside this script; then run post-revoke.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --generation-1-manifest) GENERATION_1_MANIFEST="$2"; shift 2 ;;
    --generation-1-secret) GENERATION_1_SECRET="$2"; shift 2 ;;
    --generation-2-manifest) GENERATION_2_MANIFEST="$2"; shift 2 ;;
    --generation-2-secret) GENERATION_2_SECRET="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --openclaw-image) OPENCLAW_IMAGE="$2"; shift 2 ;;
    --litellm-image) LITELLM_IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ "$STAGE" = pre-revoke ] || [ "$STAGE" = post-revoke ] || { usage >&2; exit 64; }
for input_file in "$REPORT" "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; do
  [[ "$input_file" = /* ]] || { printf 'absolute path required\n' >&2; exit 64; }
done
[ -n "$MODEL" ] && [ -n "$OPENCLAW_IMAGE" ] && [ -n "$LITELLM_IMAGE" ] || { usage >&2; exit 64; }
for secret_file in "$GENERATION_1_SECRET" "$GENERATION_2_SECRET"; do
  [ -f "$secret_file" ] && [ ! -L "$secret_file" ] || { printf 'secret file unavailable\n' >&2; exit 65; }
  secret_mode="$(stat -f '%Lp' "$secret_file" 2>/dev/null || stat -c '%a' "$secret_file")"
  [ "$secret_mode" = 400 ] || { printf 'secret mode invalid\n' >&2; exit 65; }
done
for manifest_file in "$GENERATION_1_MANIFEST" "$GENERATION_2_MANIFEST"; do
  [ -f "$manifest_file" ] && [ ! -L "$manifest_file" ] || { printf 'manifest unavailable\n' >&2; exit 66; }
done

WORK_DIR="$(mktemp -d /private/tmp/labnow-open-p2-evidence.XXXXXX)"
trap 'find "$WORK_DIR" -depth -delete' EXIT
mkdir -p "$WORK_DIR/runtime-status" "$WORK_DIR/data"
touch "$WORK_DIR/runtime-status/manifest.json" "$WORK_DIR/runtime-status/secret.json"
chmod 0600 "$WORK_DIR/runtime-status/manifest.json" "$WORK_DIR/runtime-status/secret.json"
printf '{}\n' > "$WORK_DIR/data/openclaw.json"
chmod 0600 "$WORK_DIR/data/openclaw.json"

run_adapter() {
  local action="$1" manifest_file="$2" secret_file="$3"
  docker run --rm --platform linux/amd64 --network host --entrypoint bash \
    -e OPENCLAW_STATE_DIR=/root/.openclaw/data \
    -e OPENCLAW_CONFIG_PATH=/root/.openclaw/data/openclaw.json \
    -v "$WORK_DIR/runtime-status:/run/labnow/model-access" \
    -v "$manifest_file:/run/labnow/model-access/manifest.json:ro" \
    -v "$secret_file:/run/labnow/model-access/secret.json:ro" \
    -v "$ADAPTER:/usr/local/bin/openclaw-model-access-adapter:ro" \
    -v "$WORK_DIR/data:/root/.openclaw/data" \
    "$OPENCLAW_IMAGE" -lc "openclaw-model-access-adapter $action" >/dev/null 2>/dev/null
}

run_agent() {
  local session_id="$1" manifest_file="$2" secret_file="$3" prompt="$4"
  docker run --rm --platform linux/amd64 --network host --entrypoint bash \
    -e OPENCLAW_STATE_DIR=/root/.openclaw/data \
    -e OPENCLAW_CONFIG_PATH=/root/.openclaw/data/openclaw.json \
    -v "$WORK_DIR/runtime-status:/run/labnow/model-access" \
    -v "$manifest_file:/run/labnow/model-access/manifest.json:ro" \
    -v "$secret_file:/run/labnow/model-access/secret.json:ro" \
    -v "$WORK_DIR/data:/root/.openclaw/data" \
    "$OPENCLAW_IMAGE" -lc "openclaw agent --local --session-id $session_id --model labnow/$MODEL --message '$prompt' --json >/dev/null 2>/tmp/agent.stderr" >/dev/null 2>/dev/null
}

status_file="$WORK_DIR/runtime-status/status.json"
status_summary() {
  jq -c '{contract_version,workspace_id,binding_id,lease_id,generation,adapter_id,phase,observed_at,error_code,message}' "$status_file"
}
run_step() { "$@"; }

if [ "$STAGE" = pre-revoke ]; then
  set +e
  bash "$REPO_ROOT/tests/openclaw-model-access-adapter-test.sh" >/dev/null 2>/dev/null; host_fixture_suite_exit=$?
  OPENCLAW_IMAGE="$OPENCLAW_IMAGE" bash "$REPO_ROOT/tests/openclaw-model-access-adapter-container-test.sh" >/dev/null 2>/dev/null; container_fixture_suite_exit=$?
  run_step run_adapter apply "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET"; g1_apply_exit=$?
  run_step run_adapter apply "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET"; g1_apply_repeat_exit=$?
  g1_apply_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  run_step run_adapter probe "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET"; g1_probe_exit=$?
  g1_status="$(status_summary)"
  run_step run_agent p2-g1-chat "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Reply READY only.'; g1_chat_exit=$?
  run_step run_agent p2-g1-stream "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Return STREAM_OK only.'; g1_stream_exit=$?
  run_step run_agent p2-g1-tool "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Use exec to run printf P2_TOOL_OK, then reply DONE.'; g1_tool_exit=$?
  if rg -q 'P2_TOOL_OK' "$WORK_DIR/data/agents" 2>/dev/null; then g1_tool_observed=true; else g1_tool_observed=false; fi
  run_step run_adapter apply "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_apply_exit=$?
  g2_apply_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  run_step run_adapter probe "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_probe_exit=$?
  g2_status="$(status_summary)"
  run_step run_agent p2-g2-controlled-restart "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET" 'Reply GENERATION_2_OK only.'; g2_restart_chat_exit=$?
  set -e
  jq -n --arg stage "$STAGE" --arg bundle "$CONTRACT_BUNDLE" --arg version "$CONTRACT_VERSION" --arg model "$MODEL" --arg openclaw "$OPENCLAW_IMAGE" --arg litellm "$LITELLM_IMAGE" --arg g1hash "$g1_apply_hash" --arg g2hash "$g2_apply_hash" --argjson g1status "$g1_status" --argjson g2status "$g2_status" --argjson host "$host_fixture_suite_exit" --argjson container "$container_fixture_suite_exit" --argjson a "$g1_apply_exit" --argjson ar "$g1_apply_repeat_exit" --argjson p "$g1_probe_exit" --argjson c "$g1_chat_exit" --argjson s "$g1_stream_exit" --argjson t "$g1_tool_exit" --argjson tool "$g1_tool_observed" --argjson a2 "$g2_apply_exit" --argjson p2 "$g2_probe_exit" --argjson r2 "$g2_restart_chat_exit" \
    '{schema:"labnow-p2-r2-evidence-v1",stage:$stage,contract:{version:$version,bundle:$bundle},inputs:{generation_1_secret_parameter:"GENERATION_1_SECRET_FILE",generation_2_secret_parameter:"GENERATION_2_SECRET_FILE",model:$model,openclaw_image:$openclaw,litellm_image:$litellm},fixture_checks:{host_suite_exit:$host,container_suite_exit:$container,cases:[{case:"runtime-manifest-default-not-allowed",action:"apply",expected_error_code:67},{case:"runtime-manifest-wrong-version",action:"apply",expected_error_code:67},{case:"runtime-secret-identity-mismatch",action:"apply",expected_error_code:69}]},checks:{generation_1:{apply_exit:$a,repeat_apply_exit:$ar,probe_exit:$p,config_sha256:$g1hash,status:$g1status,chat_exit:$c,stream_exit:$s,tool_exit:$t,tool_observed:$tool},generation_2:{apply_exit:$a2,probe_exit:$p2,config_sha256:$g2hash,status:$g2status,controlled_restart_chat_exit:$r2}}}' > "$REPORT"
else
  set +e
  run_step run_adapter apply "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_apply_exit=$?
  run_step run_adapter probe "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_probe_exit=$?
  run_step run_agent p2-g1-revoked "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Reply REVOKED_CHECK only.'; revoked_exit=$?
  if rg -q '(^|[^0-9])401([^0-9]|$)|Unauthorized|unauthorized' "$WORK_DIR/data/agents" 2>/dev/null; then rejection_observed=true; else rejection_observed=false; fi
  run_step run_adapter remove "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; remove_exit=$?
  remove_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  run_step run_adapter remove "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; remove_repeat_exit=$?
  if jq -e '((.models.providers? // {}) | has("labnow") | not) and ((.secrets.providers? // {}) | has("labnow-runtime") | not) and ([.agents.defaults.models? // {} | keys[] | select(startswith("labnow/"))] | length == 0)' "$WORK_DIR/data/openclaw.json" >/dev/null; then managed_config_removed=true; else managed_config_removed=false; fi
  credential_pattern='sk-[A-Za-z0-9_-]{16,}|Bearer[[:space:]]+[A-Za-z0-9._-]{16,}'
  if rg -q -e "$credential_pattern" "$WORK_DIR"; then plaintext_credential_detected=true; else plaintext_credential_detected=false; fi
  set -e
  jq -n --arg stage "$STAGE" --arg bundle "$CONTRACT_BUNDLE" --arg version "$CONTRACT_VERSION" --arg model "$MODEL" --arg openclaw "$OPENCLAW_IMAGE" --arg litellm "$LITELLM_IMAGE" --arg hash "$remove_hash" --argjson a2 "$g2_apply_exit" --argjson p2 "$g2_probe_exit" --argjson revoked "$revoked_exit" --argjson rejected "$rejection_observed" --argjson remove "$remove_exit" --argjson remover "$remove_repeat_exit" --argjson removed "$managed_config_removed" --argjson leaked "$plaintext_credential_detected" \
    '{schema:"labnow-p2-r2-evidence-v1",stage:$stage,contract:{version:$version,bundle:$bundle},inputs:{generation_1_secret_parameter:"GENERATION_1_SECRET_FILE",generation_2_secret_parameter:"GENERATION_2_SECRET_FILE",model:$model,openclaw_image:$openclaw,litellm_image:$litellm},checks:{generation_2_reapply_exit:$a2,generation_2_probe_exit:$p2,revoked_generation_1_agent_exit:$revoked,revoked_generation_1_rejection_observed:$rejected,remove_exit:$remove,repeat_remove_exit:$remover,remove_config_sha256:$hash,managed_config_removed:$removed,credential_scan:{scope:["generated-config","runtime-status","agent-state"],plaintext_credential_detected:$leaked}}}' > "$REPORT"
fi

chmod 0600 "$REPORT"
report_hash="$(shasum -a 256 "$REPORT" | awk '{print $1}')"
printf '%s  %s\n' "$report_hash" "$(basename "$REPORT")" > "${REPORT}.sha256"
printf 'stage=%s report_sha256=%s\n' "$STAGE" "$report_hash"
