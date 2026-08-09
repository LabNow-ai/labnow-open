#!/usr/bin/env bash
# Aggregates the two credential-free P2-R2 reports; it never accepts Secrets.
set -euo pipefail

pre_report=""
post_report=""
output=""
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
pre_hash="$(shasum -a 256 "$pre_report" | awk '{print $1}')"
post_hash="$(shasum -a 256 "$post_report" | awk '{print $1}')"
if jq -e '.schema == "labnow-p2-r2-evidence-v2" and .stage == "pre-revoke" and .passed == true' "$pre_report" >/dev/null && jq -e '.schema == "labnow-p2-r2-evidence-v2" and .stage == "post-revoke" and .passed == true' "$post_report" >/dev/null; then passed=true; else passed=false; fi
jq -n --arg pre "$pre_hash" --arg post "$post_hash" --argjson passed "$passed" '{schema:"labnow-p2-r2-handoff-v1",passed:$passed,reports:{pre_revoke_sha256:$pre,post_revoke_sha256:$post}}' > "$output"
chmod 0600 "$output"
handoff_hash="$(shasum -a 256 "$output" | awk '{print $1}')"
printf '%s  %s\n' "$handoff_hash" "$(basename "$output")" > "${output}.sha256"
chmod 0600 "${output}.sha256"
printf 'handoff_passed=%s handoff_sha256=%s\n' "$passed" "$handoff_hash"
[ "$passed" = true ]
