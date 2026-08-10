#!/usr/bin/env bash
# Validates the P6 OpenClaw product surface in a locally built image. It never
# accepts RuntimeSecretFile input and reports only HTTP status/config hashes.
set -euo pipefail

LOCAL_IMAGE="${LOCAL_IMAGE:-quay.io/labnow/labnow-open:che-563-openclaw-product-closure-local}"
CONTAINER_NAME="labnow-open-p6-product-${RANDOM}${RANDOM}"
WORK_DIR="$(mktemp -d /private/tmp/labnow-open-p6-product.XXXXXX)"

cleanup() {
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  find "$WORK_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf '%s\n' "FAIL openclaw-product-closure: $1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/data"
printf '%s\n' '{"models":{"providers":{"user":{"baseUrl":"https://user.example.invalid","models":[]}}},"gateway":{"mode":"local"},"agents":{"defaults":{"model":"user/model"}}}' > "$WORK_DIR/data/openclaw.json"
chmod 0600 "$WORK_DIR/data/openclaw.json"

docker run --rm -d --platform linux/amd64 --name "$CONTAINER_NAME" \
  -e URL_PREFIX=/user/p6/ \
  -v "$WORK_DIR/data:/root/.openclaw/data" \
  "$LOCAL_IMAGE" >/dev/null

gateway_status=""
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

# This is an independent CLI process, not the Adapter probe. It inherits only
# the image runtime environment and must resolve the shared workspace config.
docker exec "$CONTAINER_NAME" bash -lc '
  [ "$OPENCLAW_CONFIG" = /root/.openclaw/data/openclaw.json ]
  [ "$OPENCLAW_CONFIG_PATH" = /root/.openclaw/data/openclaw.json ]
  openclaw config validate >/dev/null
' || fail "independent OpenClaw CLI did not inherit the shared config path"

wait_for_route() {
  local path="$1" status=000
  for _ in {1..30}; do
    status="$(docker exec "$CONTAINER_NAME" curl --max-time 3 -s -o /dev/null -w '%{http_code}' "http://127.0.0.1${path}" || true)"
    [ "$status" = 200 ] && return 0
    sleep 1
  done
  fail "route ${path} returned ${status}"
}

wait_for_route /user/p6/openclaw/
wait_for_route /user/p6/api

jq -e '
  .models.providers.user.baseUrl == "https://user.example.invalid"
  and .agents.defaults.model == "user/model"
  and .gateway.mode == "local"
  and .gateway.controlUi.basePath == "/user/p6/openclaw"
' "$WORK_DIR/data/openclaw.json" >/dev/null || fail "gateway rendering did not preserve user config"

if rg -q --fixed-strings 'api_key' "$WORK_DIR/data/openclaw.json"; then
  fail "generated config unexpectedly contains api_key"
fi

printf 'PASS openclaw-product-closure image=%s config_sha256=%s\n' \
  "$LOCAL_IMAGE" "$(shasum -a 256 "$WORK_DIR/data/openclaw.json" | awk '{print $1}')"
