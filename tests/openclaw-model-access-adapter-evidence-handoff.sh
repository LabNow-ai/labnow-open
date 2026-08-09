#!/usr/bin/env bash
# Aggregates two credential-free P2-R2 reports only when they prove one fixed
# runtime combination. It never accepts Secrets or persists their paths.
set -euo pipefail

pre_report=""
post_report=""
output=""
output_tmp=""
sidecar_tmp=""

cleanup() {
  [ -z "$output_tmp" ] || find "$(dirname "$output_tmp")" -maxdepth 1 -name "$(basename "$output_tmp")" -delete
  [ -z "$sidecar_tmp" ] || find "$(dirname "$sidecar_tmp")" -maxdepth 1 -name "$(basename "$sidecar_tmp")" -delete
}
trap cleanup EXIT

report_context() {
  local report_file="$1"
  jq -c -e '
    . as $report
    | ($report.schema == "labnow-p2-r2-evidence-v2"
      and $report.passed == true
      and ($report.provenance.phase_commit | type == "string" and length > 0)
      and ($report.provenance.source_adapter_sha256 | type == "string" and length == 64)
      and ($report.contract.version | type == "string" and length > 0)
      and ($report.contract.bundle | type == "string" and length > 0)
      and ($report.inputs.model | type == "string" and length > 0)
      and ($report.inputs.openclaw_image | type == "string" and length > 0)
      and ($report.inputs.litellm_image | type == "string" and length > 0))
    | if . then {
        provenance:{phase_commit:$report.provenance.phase_commit,source_adapter_sha256:$report.provenance.source_adapter_sha256},
        contract:{version:$report.contract.version,bundle:$report.contract.bundle},
        inputs:{model:$report.inputs.model,openclaw_image:$report.inputs.openclaw_image,litellm_image:$report.inputs.litellm_image}
      } else empty end
  ' "$report_file"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pre-report) pre_report="$2"; shift 2 ;;
    --post-report) post_report="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) printf '%s\n' 'Usage: evidence-handoff.sh --pre-report ABS --post-report ABS --output ABS'; exit 0 ;;
    *) exit 64 ;;
  esac
done

for report_file in "$pre_report" "$post_report" "$output"; do [[ "$report_file" = /* ]] || exit 64; done
for report_file in "$pre_report" "$post_report"; do [ -f "$report_file" ] && [ ! -L "$report_file" ] || exit 66; done
[ -d "$(dirname "$output")" ] || exit 64

pre_hash="$(shasum -a 256 "$pre_report" | awk '{print $1}')"
post_hash="$(shasum -a 256 "$post_report" | awk '{print $1}')"
set +e
pre_context="$(report_context "$pre_report")"; pre_context_exit=$?
post_context="$(report_context "$post_report")"; post_context_exit=$?
set -e

contexts_match=false
common_context=null
if [ "$pre_context_exit" = 0 ] && [ "$post_context_exit" = 0 ] && [ "$pre_context" = "$post_context" ]; then
  contexts_match=true
  common_context="$pre_context"
fi

if [ "$contexts_match" = true ] && jq -e '.stage == "pre-revoke"' "$pre_report" >/dev/null && jq -e '.stage == "post-revoke"' "$post_report" >/dev/null; then passed=true; else passed=false; fi

output_tmp="$(mktemp "$(dirname "$output")/.${output##*/}.XXXXXX")"
chmod 0600 "$output_tmp"
jq -n --arg pre "$pre_hash" --arg post "$post_hash" --argjson passed "$passed" --argjson contexts_match "$contexts_match" --argjson pre_context_exit "$pre_context_exit" --argjson post_context_exit "$post_context_exit" --argjson context "$common_context" \
  '{schema:"labnow-p2-r2-handoff-v1",passed:$passed,reports:{pre_revoke_sha256:$pre,post_revoke_sha256:$post},consistency:{pre_context_exit:$pre_context_exit,post_context_exit:$post_context_exit,contexts_match:$contexts_match},provenance:$context.provenance,contract:$context.contract,inputs:$context.inputs}' > "$output_tmp"
jq -e '.schema == "labnow-p2-r2-handoff-v1" and (.passed | type == "boolean") and (.reports.pre_revoke_sha256 | type == "string" and length == 64) and (.reports.post_revoke_sha256 | type == "string" and length == 64) and (.consistency.contexts_match | type == "boolean") and (if .passed then (.consistency.contexts_match == true and (.provenance.phase_commit | type == "string" and length > 0) and (.provenance.source_adapter_sha256 | type == "string" and length == 64) and (.contract.version | type == "string" and length > 0) and (.contract.bundle | type == "string" and length > 0) and (.inputs.model | type == "string" and length > 0) and (.inputs.openclaw_image | type == "string" and length > 0) and (.inputs.litellm_image | type == "string" and length > 0)) else true end)' "$output_tmp" >/dev/null
mv -f -- "$output_tmp" "$output"
output_tmp=""
chmod 0600 "$output"

handoff_hash="$(shasum -a 256 "$output" | awk '{print $1}')"
sidecar_tmp="$(mktemp "$(dirname "$output")/.${output##*/}.sha256.XXXXXX")"
chmod 0600 "$sidecar_tmp"
printf '%s  %s\n' "$handoff_hash" "$(basename "$output")" > "$sidecar_tmp"
mv -f -- "$sidecar_tmp" "${output}.sha256"
sidecar_tmp=""
chmod 0600 "${output}.sha256"
printf 'handoff_passed=%s handoff_sha256=%s\n' "$passed" "$handoff_hash"
[ "$passed" = true ]
