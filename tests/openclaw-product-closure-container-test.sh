#!/usr/bin/env bash
# Validates the P6/P8 OpenClaw product surface in a locally built image. It
# never accepts RuntimeSecretFile input and reports only HTTP status/config
# hashes. The same persisted Home is intentionally used across URL_PREFIX
# changes so named-workspace routing cannot retain stale runtime state.
set -euo pipefail

LOCAL_IMAGE="${LOCAL_IMAGE:-quay.io/labnow/labnow-open-openclaw:che-595-named-workspace-basepath-local}"
CONTAINER_NAME=""
WORK_DIR="$(mktemp -d /private/tmp/labnow-open-p6-product.XXXXXX)"

cleanup() {
  [ -z "$CONTAINER_NAME" ] || docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf '%s\n' "FAIL openclaw-product-closure: $1" >&2
  exit 1
}

wait_for_route() {
  local path="$1" status=000
  for _ in {1..30}; do
    status="$(docker exec "$CONTAINER_NAME" curl --max-time 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1${path}" || true)"
    [ "$status" = 200 ] && return 0
    sleep 1
  done
  fail "route ${path} returned ${status}"
}

start_workspace() {
  local prefix="$1" route_prefix gateway_status=""
  route_prefix="${prefix%/}"
  CONTAINER_NAME="labnow-open-p8-product-${RANDOM}${RANDOM}"

  docker run --rm -d --platform linux/amd64 --name "$CONTAINER_NAME" \
    -e "URL_PREFIX=${prefix}" \
    -e MODEL_ACCESS_MODE=unmanaged \
    -v "$WORK_DIR/data:/root/.openclaw/data" \
    "$LOCAL_IMAGE" >/dev/null

  for _ in {1..45}; do
    gateway_status="$(docker exec "$CONTAINER_NAME" supervisord ctl status openclaw 2>/dev/null || true)"
    case "$(printf '%s' "$gateway_status" | tr '[:lower:]' '[:upper:]')" in
      *RUNNING*) break ;;
    esac
    sleep 1
  done
  case "$(printf '%s' "$gateway_status" | tr '[:lower:]' '[:upper:]')" in
    *RUNNING*) ;;
    *) fail "openclaw supervisor program did not reach RUNNING" ;;
  esac

  # This is an independent CLI process, not the Adapter probe. It inherits
  # only image runtime environment and must resolve the persisted config.
  docker exec "$CONTAINER_NAME" bash -lc '
    [ "$OPENCLAW_CONFIG" = /root/.openclaw/data/openclaw.json ]
    [ "$OPENCLAW_CONFIG_PATH" = /root/.openclaw/data/openclaw.json ]
    openclaw config validate >/dev/null
  ' || fail "independent OpenClaw CLI did not inherit the shared config path"

  wait_for_route "${route_prefix}/openclaw/"
  wait_for_route "${route_prefix}/api"
}

stop_workspace() {
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  CONTAINER_NAME=""
}

assert_preserved_config() {
  local expected_base_path="$1"
  jq -e --arg base_path "$expected_base_path" '
    .models.providers.user.baseUrl == "https://user.example.invalid"
    and .agents.defaults.model == "user/model"
    and .gateway.mode == "local"
    and .gateway.controlUi.basePath == $base_path
    and .tools.allow == ["exec"]
  ' "$WORK_DIR/data/openclaw.json" >/dev/null || fail "gateway rendering did not preserve user config"
  [ "$(stat -f '%Lp' "$WORK_DIR/data/openclaw.json")" = 600 ] || fail "rendered config permissions are not 0600"
}

assert_unconfigured_tools_remain_unconfigured() {
  local expected_base_path="$1"
  jq -e --arg base_path "$expected_base_path" '
    .models.providers.user.baseUrl == "https://user.example.invalid"
    and .agents.defaults.model == "user/model"
    and .gateway.mode == "local"
    and .gateway.controlUi.basePath == $base_path
    and (has("tools") | not)
  ' "$WORK_DIR/data/openclaw.json" >/dev/null || fail "gateway rendering enabled tools for an unconfigured user"
}

mkdir -p "$WORK_DIR/data"
printf '%s\n' '{"models":{"providers":{"user":{"baseUrl":"https://user.example.invalid","models":[]}}},"gateway":{"mode":"local","controlUi":{"basePath":"/stale/openclaw"}},"agents":{"defaults":{"model":"user/model"}},"tools":{"allow":["exec"]}}' > "$WORK_DIR/data/openclaw.json"
chmod 0600 "$WORK_DIR/data/openclaw.json"

# First workspace A, then a different workspace B using the exact same
# persisted Home, then repeated B and a recreated A. Every run must converge
# only the managed basePath and retain user-owned fields.
start_workspace /user/workspace-a/
assert_preserved_config /user/workspace-a/openclaw
stop_workspace

start_workspace /user/workspace-b/
assert_preserved_config /user/workspace-b/openclaw
hash_b_first="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
stop_workspace

start_workspace /user/workspace-b/
assert_preserved_config /user/workspace-b/openclaw
hash_b_repeat="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
[ "$hash_b_first" = "$hash_b_repeat" ] || fail "repeated workspace prefix was not idempotent"
stop_workspace

start_workspace /user/workspace-a/
assert_preserved_config /user/workspace-a/openclaw
stop_workspace

if rg -q --fixed-strings 'api_key' "$WORK_DIR/data/openclaw.json"; then
  fail "generated config unexpectedly contains api_key"
fi

# Invalid prefixes fail before the persistent configuration can be changed.
invalid_hash_before="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
set +e
docker run --rm --platform linux/amd64 \
  --entrypoint bash \
  -e URL_PREFIX=not-an-absolute-prefix \
  -e MODEL_ACCESS_MODE=unmanaged \
  -v "$WORK_DIR/data:/root/.openclaw/data" \
  "$LOCAL_IMAGE" \
  -lc 'start-labnow-openclaw.sh gateway' >/dev/null 2>&1
invalid_prefix_exit=$?
set -e
[ "$invalid_prefix_exit" -eq 64 ] || fail "invalid URL_PREFIX was accepted"
invalid_hash_after="$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
[ "$invalid_hash_before" = "$invalid_hash_after" ] || fail "invalid URL_PREFIX changed persisted config"

# A user who did not configure tools must not receive an implicit exec grant.
# Retain the otherwise-valid fixture shape so the independent CLI validation in
# start_workspace continues to exercise the rendered configuration.
printf '%s\n' '{"models":{"providers":{"user":{"baseUrl":"https://user.example.invalid","models":[]}}},"gateway":{"mode":"local","controlUi":{"basePath":"/stale/openclaw"}},"agents":{"defaults":{"model":"user/model"}}}' > "$WORK_DIR/data/openclaw.json"
chmod 0600 "$WORK_DIR/data/openclaw.json"
start_workspace /user/unconfigured-tools/
assert_unconfigured_tools_remain_unconfigured /user/unconfigured-tools/openclaw
stop_workspace

printf 'PASS openclaw-product-closure image=%s config_sha256=%s idempotent_sha256=%s invalid_prefix_exit=%s\n' \
  "$LOCAL_IMAGE" "$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')" \
  "$hash_b_repeat" "$invalid_prefix_exit"
