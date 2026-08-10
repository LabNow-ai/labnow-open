#!/usr/bin/env bash
# Starts the OpenClaw gateway at the LabNow workspace route without touching
# LabNow's managed model provider namespace or RuntimeSecretFile.
set -euo pipefail

readonly OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG:-/root/.openclaw/data/openclaw.json}"
readonly OPENCLAW_GATEWAY_PORT="18789"

die() {
  printf '%s\n' "start-labnow-openclaw: $1" >&2
  exit "${2:-1}"
}

assert_regular_config_path() {
  [[ "$OPENCLAW_CONFIG_PATH" = /* ]] || die "SECURE_PATH_REQUIRED" 64

  local config_parent
  config_parent="$(dirname -- "$OPENCLAW_CONFIG_PATH")"
  mkdir -p -- "$config_parent"
  [ ! -L "$config_parent" ] || die "SECURE_PATH_REQUIRED" 64
  [ ! -e "$OPENCLAW_CONFIG_PATH" ] || [ ! -L "$OPENCLAW_CONFIG_PATH" ] || die "SECURE_PATH_REQUIRED" 64
}

control_ui_base_path() {
  local prefix="${URL_PREFIX:-/}"
  [[ "$prefix" = /* ]] || die "URL_PREFIX_INVALID" 64
  case "$prefix" in
    *".."*|*'?'*|*'#'*|*'//'*) die "URL_PREFIX_INVALID" 64 ;;
  esac
  prefix="${prefix%/}"
  if [ -z "$prefix" ]; then
    printf '%s\n' "/openclaw"
  else
    printf '%s\n' "${prefix}/openclaw"
  fi
}

configure_control_ui_base_path() {
  local base_path tmp
  base_path="$(control_ui_base_path)"
  assert_regular_config_path

  if [ ! -e "$OPENCLAW_CONFIG_PATH" ]; then
    umask 077
    printf '{}\n' > "$OPENCLAW_CONFIG_PATH"
    chmod 0600 "$OPENCLAW_CONFIG_PATH"
  fi
  jq -e 'type == "object"' "$OPENCLAW_CONFIG_PATH" >/dev/null || die "OPENCLAW_CONFIG_INVALID" 70

  tmp="$(mktemp "$(dirname -- "$OPENCLAW_CONFIG_PATH")/.openclaw.json.XXXXXX")"
  umask 077
  jq --arg base_path "$base_path" '
    def object_or_empty:
      if . == null then {} elif type == "object" then . else error("expected object") end;
    .gateway = (.gateway | object_or_empty)
    | .gateway.controlUi = (.gateway.controlUi | object_or_empty)
    | if .gateway.controlUi.basePath == null then
        .gateway.controlUi.basePath = $base_path
      elif .gateway.controlUi.basePath == $base_path then
        .
      else
        error("OPENCLAW_CONTROL_UI_BASE_PATH_CONFLICT")
      end
  ' "$OPENCLAW_CONFIG_PATH" > "$tmp" || {
    find "$(dirname -- "$tmp")" -maxdepth 1 -name "$(basename -- "$tmp")" -delete
    die "OPENCLAW_CONTROL_UI_BASE_PATH_CONFLICT" 72
  }
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$OPENCLAW_CONFIG_PATH"
}

configure_control_ui_base_path
exec /opt/openclaw/start-openclaw.sh gateway --allow-unconfigured --bind loopback --port "$OPENCLAW_GATEWAY_PORT"
