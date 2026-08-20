#!/usr/bin/env bash
# Validates the rendered adapter as installed in the locally built P7 product
# image. The input is a local-only image tag; the test reports its immutable ID.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${MODEL_ACCESS_FIXTURES_DIR:-$REPO_ROOT/../lab_project_analysis/contracts/model-access/v1alpha1/fixtures}"
[[ -d "$FIXTURES" ]] || { printf 'FAIL: contract fixtures not found at %s; set MODEL_ACCESS_FIXTURES_DIR\n' "$FIXTURES" >&2; exit 1; }
LOCAL_IMAGE="${LOCAL_IMAGE:?set LOCAL_IMAGE to quay.io/labnow/labnow-open:che-568-hermes-console-experience-local}"
case "$LOCAL_IMAGE" in quay.io/labnow/labnow-open:*) ;; *) printf '%s\n' 'FAIL: LOCAL_IMAGE must be a local quay.io/labnow/labnow-open tag' >&2; exit 64 ;; esac
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
image_id="$(docker image inspect --format '{{.Id}}' "$LOCAL_IMAGE")" || fail "local image unavailable"

mkdir -p "$WORK_DIR/runtime" "$WORK_DIR/status" "$WORK_DIR/hermes" "$WORK_DIR/bin"
touch "$WORK_DIR/start-result"
chmod 0600 "$WORK_DIR/start-result"
touch "$WORK_DIR/status/manifest.json" "$WORK_DIR/status/secret.json"
chmod 0600 "$WORK_DIR/status/manifest.json" "$WORK_DIR/status/secret.json"
cp "$FIXTURES/valid/runtime-manifest.json" "$WORK_DIR/runtime/manifest.json"
jq '.adapter_id = "hermes"' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.hermes.json"
mv "$WORK_DIR/runtime/manifest.hermes.json" "$WORK_DIR/runtime/manifest.json"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
printf '%s\n' 'model: {provider: user, default: user-model}' > "$WORK_DIR/hermes/config.yaml"
chmod 0600 "$WORK_DIR/hermes/config.yaml"
user_config_hash="$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')"

cat > "$WORK_DIR/bin/start-hermes.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${HERMES_MANAGED_DIR:-}" = "/root/.hermes/labnow-model-access" ]
[ -n "${OPENAI_API_KEY:-}" ]
printf '%s\n' '{"started":true}' > /tmp/labnow-hermes-start-result.json
EOF
chmod 0700 "$WORK_DIR/bin/start-hermes.sh"

run_in_image() {
  docker run --rm --platform linux/amd64 --entrypoint bash \
    -v "$WORK_DIR/status:/run/labnow/model-access" \
    -v "$WORK_DIR/runtime/manifest.json:/run/labnow/model-access/manifest.json:ro" \
    -v "$WORK_DIR/runtime/secret.json:/run/labnow/model-access/secret.json:ro" \
    -v "$WORK_DIR/hermes:/root/.hermes" \
    "$LOCAL_IMAGE" -lc "$1"
}

expected_adapter_sha="$(sha256sum "$REPO_ROOT/src/labnow-open-etc/hermes-model-access-adapter.sh" | awk '{print $1}')"
image_adapter_sha="$(run_in_image 'sha256sum /usr/local/bin/hermes-model-access-adapter | awk "{print \$1}"')"
[ "$image_adapter_sha" = "$expected_adapter_sha" ] || fail "image adapter does not match source"
expected_common_lib_sha="$(sha256sum "$REPO_ROOT/src/labnow-open-etc/lib/model-access-adapter-common.sh" | awk '{print $1}')"
image_common_lib_sha="$(run_in_image 'sha256sum /opt/labnow-open/etc/lib/model-access-adapter-common.sh | awk "{print \$1}"')"
[ "$image_common_lib_sha" = "$expected_common_lib_sha" ] || fail "image common adapter library does not match source"
expected_starter_sha="$(sha256sum "$REPO_ROOT/src/labnow-open-etc/start-labnow-hermes.sh" | awk '{print $1}')"
image_starter_sha="$(run_in_image 'sha256sum /usr/local/bin/start-labnow-hermes.sh | awk "{print \$1}"')"
[ "$image_starter_sha" = "$expected_starter_sha" ] || fail "image Hermes starter does not match source"
run_in_image 'test "$HERMES_MANAGED_DIR" = /root/.hermes/labnow-model-access'
# Hermes TUI uses node and npm at runtime. They must be supplied by the fixed
# image, never first-use downloaded into the mounted Workspace home.
run_in_image 'node --version >/dev/null && npm --version >/dev/null'
run_in_image 'test ! -e /root/.hermes/node'
# This is the same node-resolution path used by `hermes --tui`, without
# starting an interactive TUI process that could outlive a non-TTY test shell.
run_in_image 'HERMES_SKIP_NODE_BOOTSTRAP=1 python3 -c "from hermes_cli.main import _make_tui_argv; from pathlib import Path; argv, _ = _make_tui_argv(Path(\"/opt/hermes/ui-tui\"), False); assert argv[0].endswith(\"node\")"'
run_in_image 'test ! -e /root/.hermes/node'

run_in_image 'hermes-model-access-adapter apply'
run_in_image 'hermes-model-access-adapter probe'
first_hash="$(sha256sum "$WORK_DIR/hermes/labnow-model-access/config.yaml" | awk '{print $1}')"
run_in_image 'hermes-model-access-adapter apply'
repeat_hash="$(sha256sum "$WORK_DIR/hermes/labnow-model-access/config.yaml" | awk '{print $1}')"
[ "$first_hash" = "$repeat_hash" ] || fail "apply is not idempotent"
[ "$user_config_hash" = "$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')" ] || fail "user config changed"
jq -e '.adapter_id == "hermes" and .phase == "applied" and .generation == 1' "$WORK_DIR/status/status.json" >/dev/null || fail "generation-1 RuntimeStatus"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/hermes" "$WORK_DIR/status"; then fail "secret leaked into managed files"; fi

# The mounted upstream launcher is a non-persistent test probe: it proves the
# production wrapper supplies the key only to its child environment.
docker run --rm --platform linux/amd64 --entrypoint bash \
  -e MODEL_ACCESS_MODE=managed \
  -v "$WORK_DIR/status:/run/labnow/model-access" \
  -v "$WORK_DIR/runtime/manifest.json:/run/labnow/model-access/manifest.json:ro" \
  -v "$WORK_DIR/runtime/secret.json:/run/labnow/model-access/secret.json:ro" \
  -v "$WORK_DIR/hermes:/root/.hermes" \
  -v "$WORK_DIR/bin/start-hermes.sh:/usr/local/bin/start-hermes.sh:ro" \
  -v "$WORK_DIR/start-result:/tmp/labnow-hermes-start-result.json" \
  "$LOCAL_IMAGE" -lc 'start-labnow-hermes.sh gateway'
jq -e '.started == true' "$WORK_DIR/start-result" >/dev/null || fail "managed starter"

jq '.generation = 2' "$WORK_DIR/runtime/manifest.json" > "$WORK_DIR/runtime/manifest.next.json"
mv "$WORK_DIR/runtime/manifest.next.json" "$WORK_DIR/runtime/manifest.json"
jq '.generation = 2' "$WORK_DIR/runtime/secret.json" > "$WORK_DIR/runtime/secret.next.json"
mv -f "$WORK_DIR/runtime/secret.next.json" "$WORK_DIR/runtime/secret.json"
chmod 0400 "$WORK_DIR/runtime/secret.json"
run_in_image 'hermes-model-access-adapter apply'
run_in_image 'hermes-model-access-adapter probe'
jq -e '.adapter_id == "hermes" and .phase == "ready" and .generation == 2' "$WORK_DIR/status/status.json" >/dev/null || fail "generation-2 RuntimeStatus"

run_in_image 'hermes-model-access-adapter remove'
run_in_image 'hermes-model-access-adapter remove'
[ ! -e "$WORK_DIR/hermes/labnow-model-access/config.yaml" ] || fail "managed config remains after remove"
[ "$user_config_hash" = "$(sha256sum "$WORK_DIR/hermes/config.yaml" | awk '{print $1}')" ] || fail "remove changed user config"

printf 'PASS hermes-console-experience-container image_id=%s\n' "$image_id"
