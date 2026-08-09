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
LITELLM_CONTAINER=""
LOCAL_IMAGE="quay.io/labnow/labnow-open:che-549-openclaw-adapter-local"

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
    --litellm-image IMAGE@sha256:DIGEST --litellm-container CONTAINER

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
    --litellm-container) LITELLM_CONTAINER="$2"; shift 2 ;;
    --local-image) LOCAL_IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[ "$STAGE" = pre-revoke ] || [ "$STAGE" = post-revoke ] || { usage >&2; exit 64; }
for input_file in "$REPORT" "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; do
  [[ "$input_file" = /* ]] || { printf 'absolute path required\n' >&2; exit 64; }
done
[ -n "$MODEL" ] && [ -n "$OPENCLAW_IMAGE" ] && [ -n "$LITELLM_IMAGE" ] && [ -n "$LITELLM_CONTAINER" ] || { usage >&2; exit 64; }
PHASE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
SOURCE_ADAPTER_SHA256="$(shasum -a 256 "$ADAPTER" | awk '{print $1}')"
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
    -e P2_MODEL="$MODEL" \
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

run_stream_agent() {
  local manifest_file="$1" secret_file="$2"
  docker run --rm --platform linux/amd64 --network host --entrypoint bash \
    -e OPENCLAW_STATE_DIR=/root/.openclaw/data \
    -e OPENCLAW_CONFIG_PATH=/root/.openclaw/data/openclaw.json \
    -e P2_MODEL="$MODEL" \
    -v "$WORK_DIR/runtime-status:/run/labnow/model-access" \
    -v "$manifest_file:/run/labnow/model-access/manifest.json:ro" \
    -v "$secret_file:/run/labnow/model-access/secret.json:ro" \
    -v "$WORK_DIR/data:/root/.openclaw/data" \
    "$OPENCLAW_IMAGE" -lc 'set +e
      raw=/root/.openclaw/data/p2-g1-stream.raw.jsonl
      : > "$raw"
      openclaw gateway run --allow-unconfigured --auth none --port 18789 --raw-stream --raw-stream-path "$raw" >/tmp/p2-gateway.log 2>&1 &
      gateway_pid=$!
      sleep 1
      openclaw agent --session-id p2-g1-stream --model "labnow/$P2_MODEL" --message "Return STREAM_OK only." --json >/dev/null 2>/tmp/p2-stream.stderr
      agent_exit=$?
      kill "$gateway_pid" >/dev/null 2>&1
      wait "$gateway_pid" >/dev/null 2>&1
      exit "$agent_exit"' >/dev/null 2>/dev/null
}

trajectory_summary() {
  local session_id="$1" trajectory="$WORK_DIR/data/agents/main/sessions/${session_id}.trajectory.jsonl"
  if [ ! -f "$trajectory" ]; then printf '{"model_completed_count":0,"session_ended_count":0,"error_field_present":false}'; return; fi
  jq -s '{model_completed_count:([.[] | select(.type == "model.completed")] | length),session_ended_count:([.[] | select(.type == "session.ended")] | length),error_field_present:any(.[]; has("error"))}' "$trajectory"
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
  g1_apply_first_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  run_step run_adapter apply "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET"; g1_apply_repeat_exit=$?
  g1_apply_repeat_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  if [ "$g1_apply_first_hash" = "$g1_apply_repeat_hash" ]; then g1_apply_hash_equal=true; else g1_apply_hash_equal=false; fi
  run_step run_adapter probe "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET"; g1_probe_exit=$?
  g1_status="$(status_summary)"
  run_step run_agent p2-g1-chat "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Reply READY only.'; g1_chat_exit=$?
  g1_chat_summary="$(trajectory_summary p2-g1-chat)"
  if jq -e '.model_completed_count > 0 and .session_ended_count > 0 and .error_field_present == false' <<<"$g1_chat_summary" >/dev/null; then g1_chat_structure_passed=true; else g1_chat_structure_passed=false; fi
  run_step run_stream_agent "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET"; g1_stream_exit=$?
  raw_stream_file="$WORK_DIR/data/p2-g1-stream.raw.jsonl"
  if [ -f "$raw_stream_file" ]; then g1_stream_event_count="$(wc -l < "$raw_stream_file" | tr -d ' ')"; else g1_stream_event_count=0; fi
  if [ "$g1_stream_exit" = 0 ] && [ "$g1_stream_event_count" -gt 0 ]; then g1_stream_terminated=true; else g1_stream_terminated=false; fi
  run_step run_agent p2-g1-tool "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Use exec to run printf P2_TOOL_OK, then reply DONE.'; g1_tool_exit=$?
  if rg -q 'P2_TOOL_OK' "$WORK_DIR/data/agents" 2>/dev/null; then g1_tool_observed=true; else g1_tool_observed=false; fi
  run_step run_adapter apply "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_apply_exit=$?
  g2_apply_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  run_step run_adapter probe "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_probe_exit=$?
  g2_status="$(status_summary)"
  run_step run_agent p2-g2-controlled-restart "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET" 'Reply GENERATION_2_OK only.'; g2_restart_chat_exit=$?
  g2_restart_chat_summary="$(trajectory_summary p2-g2-controlled-restart)"
  if jq -e '.model_completed_count > 0 and .session_ended_count > 0 and .error_field_present == false' <<<"$g2_restart_chat_summary" >/dev/null; then g2_restart_chat_structure_passed=true; else g2_restart_chat_structure_passed=false; fi
  if [ "$host_fixture_suite_exit" = 0 ] && [ "$container_fixture_suite_exit" = 0 ] && [ "$g1_apply_exit" = 0 ] && [ "$g1_apply_repeat_exit" = 0 ] && [ "$g1_apply_hash_equal" = true ] && [ "$g1_probe_exit" = 0 ] && [ "$g1_chat_exit" = 0 ] && [ "$g1_chat_structure_passed" = true ] && [ "$g1_stream_terminated" = true ] && [ "$g1_tool_exit" = 0 ] && [ "$g1_tool_observed" = true ] && [ "$g2_apply_exit" = 0 ] && [ "$g2_probe_exit" = 0 ] && [ "$g2_restart_chat_exit" = 0 ] && [ "$g2_restart_chat_structure_passed" = true ]; then pre_passed=true; else pre_passed=false; fi
  set -e
  jq -n --arg stage "$STAGE" --arg commit "$PHASE_COMMIT" --arg adapter_sha "$SOURCE_ADAPTER_SHA256" --arg bundle "$CONTRACT_BUNDLE" --arg version "$CONTRACT_VERSION" --arg model "$MODEL" --arg openclaw "$OPENCLAW_IMAGE" --arg litellm "$LITELLM_IMAGE" --arg first "$g1_apply_first_hash" --arg repeat "$g1_apply_repeat_hash" --arg g2hash "$g2_apply_hash" --argjson equal "$g1_apply_hash_equal" --argjson g1status "$g1_status" --argjson g2status "$g2_status" --argjson chat "$g1_chat_summary" --argjson chat_ok "$g1_chat_structure_passed" --argjson g2chat "$g2_restart_chat_summary" --argjson g2chat_ok "$g2_restart_chat_structure_passed" --argjson host "$host_fixture_suite_exit" --argjson container "$container_fixture_suite_exit" --argjson a "$g1_apply_exit" --argjson ar "$g1_apply_repeat_exit" --argjson p "$g1_probe_exit" --argjson c "$g1_chat_exit" --argjson s "$g1_stream_exit" --argjson events "$g1_stream_event_count" --argjson ended "$g1_stream_terminated" --argjson t "$g1_tool_exit" --argjson tool "$g1_tool_observed" --argjson a2 "$g2_apply_exit" --argjson p2 "$g2_probe_exit" --argjson r2 "$g2_restart_chat_exit" --argjson passed "$pre_passed" \
    '{schema:"labnow-p2-r2-evidence-v2",stage:$stage,passed:$passed,provenance:{phase_commit:$commit,source_adapter_sha256:$adapter_sha},command_templates:{chat:"openclaw-agent-local-json",stream:"openclaw-gateway-raw-stream-plus-agent",tool:"openclaw-agent-local-json-exec",adapter:"openclaw-model-access-adapter ACTION"},contract:{version:$version,bundle:$bundle},inputs:{generation_1_secret_parameter:"GENERATION_1_SECRET_FILE",generation_2_secret_parameter:"GENERATION_2_SECRET_FILE",model:$model,openclaw_image:$openclaw,litellm_image:$litellm},fixture_checks:{host_suite_exit:$host,container_suite_exit:$container,cases:[{case:"runtime-manifest-default-not-allowed",action:"apply",expected_error_code:67},{case:"runtime-manifest-wrong-version",action:"apply",expected_error_code:67},{case:"runtime-secret-identity-mismatch",action:"apply",expected_error_code:69}]},checks:{generation_1:{apply_exit:$a,repeat_apply_exit:$ar,apply_first_config_sha256:$first,apply_repeat_config_sha256:$repeat,apply_hash_equal:$equal,probe_exit:$p,status:$g1status,chat:{exit:$c,structure:$chat,structure_passed:$chat_ok},stream:{exit:$s,raw_event_count:$events,terminated:$ended},tool_exit:$t,tool_observed:$tool},generation_2:{apply_exit:$a2,probe_exit:$p2,config_sha256:$g2hash,status:$g2status,controlled_restart_chat:{exit:$r2,structure:$g2chat,structure_passed:$g2chat_ok}}}}' > "$REPORT"
else
  set +e
  run_step run_adapter apply "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_apply_exit=$?
  run_step run_adapter probe "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; g2_probe_exit=$?
  run_step run_agent p2-g1-revoked "$GENERATION_1_MANIFEST" "$GENERATION_1_SECRET" 'Reply REVOKED_CHECK only.'; revoked_exit=$?
  if rg -q '(^|[^0-9])401([^0-9]|$)|Unauthorized|unauthorized' "$WORK_DIR/data/agents" 2>/dev/null; then rejection_observed=true; else rejection_observed=false; fi
  run_step run_adapter remove "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; remove_exit=$?
  remove_first_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  run_step run_adapter remove "$GENERATION_2_MANIFEST" "$GENERATION_2_SECRET"; remove_repeat_exit=$?
  remove_repeat_hash="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
  if [ "$remove_first_hash" = "$remove_repeat_hash" ]; then remove_hash_equal=true; else remove_hash_equal=false; fi
  if jq -e '((.models.providers? // {}) | has("labnow") | not) and ((.secrets.providers? // {}) | has("labnow-runtime") | not) and ([.agents.defaults.models? // {} | keys[] | select(startswith("labnow/"))] | length == 0)' "$WORK_DIR/data/openclaw.json" >/dev/null; then managed_config_removed=true; else managed_config_removed=false; fi
  credential_pattern='sk-[A-Za-z0-9_-]{16,}|Bearer[[:space:]]+[A-Za-z0-9._-]{16,}'
  if rg -q -e "$credential_pattern" "$WORK_DIR/data/openclaw.json" "$status_file"; then generated_config_or_status_zero_hit=false; else generated_config_or_status_zero_hit=true; fi
  if rg -q -e "$credential_pattern" "$WORK_DIR/data"; then openclaw_runtime_state_zero_hit=false; else openclaw_runtime_state_zero_hit=true; fi
  litellm_log="$WORK_DIR/.litellm.log"
  docker logs "$LITELLM_CONTAINER" > "$litellm_log" 2>&1
  if rg -q -e "$credential_pattern" "$litellm_log"; then litellm_log_zero_hit=false; else litellm_log_zero_hit=true; fi
  find "$WORK_DIR" -maxdepth 1 -name '.litellm.log' -delete
  if ps -axo command= | rg 'p2-g1-|p2-g2-' | rg -q -e "$credential_pattern"; then process_arguments_zero_hit=false; else process_arguments_zero_hit=true; fi
  if git -C "$REPO_ROOT" diff --no-ext-diff 7f43656b8db451111f0d6c73e571c45e18db2501..HEAD | rg -q -e "$credential_pattern"; then git_diff_zero_hit=false; else git_diff_zero_hit=true; fi
  image_scan_dir="$(mktemp -d /private/tmp/labnow-open-p2-image-scan.XXXXXX)"
  docker image save "$LOCAL_IMAGE" -o "$image_scan_dir/image.tar"
  local_image_id="$(docker image inspect "$LOCAL_IMAGE" --format '{{.Id}}')"
  local_image_adapter_sha256="$(docker run --rm --platform linux/amd64 --entrypoint sha256sum "$LOCAL_IMAGE" /usr/local/bin/openclaw-model-access-adapter | awk '{print $1}')"
  if [ "$local_image_adapter_sha256" = "$SOURCE_ADAPTER_SHA256" ]; then local_image_adapter_matches_source=true; else local_image_adapter_matches_source=false; fi
  local_image_archive_sha256="$(shasum -a 256 "$image_scan_dir/image.tar" | awk '{print $1}')"
  if rg -a -q -e "$credential_pattern" "$image_scan_dir"; then local_image_layer_zero_hit=false; else local_image_layer_zero_hit=true; fi
  find "$image_scan_dir" -depth -delete
  if [ "$g2_apply_exit" = 0 ] && [ "$g2_probe_exit" = 0 ] && [ "$revoked_exit" -ne 0 ] && [ "$rejection_observed" = true ] && [ "$remove_exit" = 0 ] && [ "$remove_repeat_exit" = 0 ] && [ "$remove_hash_equal" = true ] && [ "$managed_config_removed" = true ] && [ "$generated_config_or_status_zero_hit" = true ] && [ "$openclaw_runtime_state_zero_hit" = true ] && [ "$litellm_log_zero_hit" = true ] && [ "$process_arguments_zero_hit" = true ] && [ "$git_diff_zero_hit" = true ] && [ "$local_image_layer_zero_hit" = true ] && [ "$local_image_adapter_matches_source" = true ]; then post_passed=true; else post_passed=false; fi
  set -e
  jq -n --arg stage "$STAGE" --arg commit "$PHASE_COMMIT" --arg adapter_sha "$SOURCE_ADAPTER_SHA256" --arg bundle "$CONTRACT_BUNDLE" --arg version "$CONTRACT_VERSION" --arg model "$MODEL" --arg openclaw "$OPENCLAW_IMAGE" --arg litellm "$LITELLM_IMAGE" --arg local_image "$LOCAL_IMAGE" --arg image_id "$local_image_id" --arg archive "$local_image_archive_sha256" --arg image_adapter "$local_image_adapter_sha256" --arg first "$remove_first_hash" --arg repeat "$remove_repeat_hash" --argjson image_matches "$local_image_adapter_matches_source" --argjson equal "$remove_hash_equal" --argjson a2 "$g2_apply_exit" --argjson p2 "$g2_probe_exit" --argjson revoked "$revoked_exit" --argjson rejected "$rejection_observed" --argjson remove "$remove_exit" --argjson remover "$remove_repeat_exit" --argjson removed "$managed_config_removed" --argjson config_status "$generated_config_or_status_zero_hit" --argjson runtime "$openclaw_runtime_state_zero_hit" --argjson litellm_log "$litellm_log_zero_hit" --argjson process "$process_arguments_zero_hit" --argjson diff "$git_diff_zero_hit" --argjson image "$local_image_layer_zero_hit" --argjson passed "$post_passed" \
    '{schema:"labnow-p2-r2-evidence-v2",stage:$stage,passed:$passed,provenance:{phase_commit:$commit,source_adapter_sha256:$adapter_sha},command_templates:{scan_generated_config_status:"rg-credential-pattern generated-config RuntimeStatus",scan_openclaw_state:"rg-credential-pattern OpenClaw-state",scan_litellm_log:"docker-logs-to-private-temp then rg",scan_process_arguments:"ps-scoped-p2 then rg",scan_git_diff:"git-diff then rg",scan_image_layer:"docker-image-save then rg-a"},contract:{version:$version,bundle:$bundle},inputs:{generation_1_secret_parameter:"GENERATION_1_SECRET_FILE",generation_2_secret_parameter:"GENERATION_2_SECRET_FILE",model:$model,openclaw_image:$openclaw,litellm_image:$litellm},checks:{generation_2_reapply_exit:$a2,generation_2_probe_exit:$p2,revoked_generation_1_agent_exit:$revoked,revoked_generation_1_rejection_observed:$rejected,remove:{first_exit:$remove,repeat_exit:$remover,first_config_sha256:$first,repeat_config_sha256:$repeat,hash_equal:$equal,managed_config_removed:$removed},credential_scan:{generated_config_and_runtime_status_zero_hit:$config_status,openclaw_runtime_state_and_logs_zero_hit:$runtime,litellm_logs_zero_hit:$litellm_log,container_process_arguments_zero_hit:$process,git_diff_zero_hit:$diff,local_image_layers_zero_hit:$image},local_image:{reference:$local_image,image_id:$image_id,archive_sha256:$archive,adapter_sha256:$image_adapter,adapter_matches_source:$image_matches}}}' > "$REPORT"
fi

chmod 0600 "$REPORT"
report_hash="$(shasum -a 256 "$REPORT" | awk '{print $1}')"
printf '%s  %s\n' "$report_hash" "$(basename "$REPORT")" > "${REPORT}.sha256"
chmod 0600 "${REPORT}.sha256"
printf 'stage=%s report_sha256=%s\n' "$STAGE" "$report_hash"
if [ "$STAGE" = pre-revoke ]; then final_passed="$pre_passed"; else final_passed="$post_passed"; fi
[ "$final_passed" = true ]
