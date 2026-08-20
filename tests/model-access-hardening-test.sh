#!/usr/bin/env bash
# PH-3 host regression tests for serialized generation updates and trusted paths.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="${MODEL_ACCESS_FIXTURES_DIR:-$REPO_ROOT/../lab_project_analysis/contracts/model-access/v1alpha1/fixtures}"
[[ -d "$FIXTURES" ]] || { printf 'FAIL: contract fixtures not found at %s; set MODEL_ACCESS_FIXTURES_DIR\n' "$FIXTURES" >&2; exit 1; }
WRAPPER="$REPO_ROOT/tests/helpers/run-model-access-adapter-test-wrapper.sh"
OPENCLAW_ADAPTER="$REPO_ROOT/src/labnow-open-etc/openclaw-model-access-adapter.sh"
HERMES_ADAPTER="$REPO_ROOT/src/labnow-open-etc/hermes-model-access-adapter.sh"
WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -depth -delete' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

write_manifest() {
  local target="$1" adapter="$2" generation="$3" lease_id="$4" base_url="$5"
  jq --arg adapter "$adapter" --argjson generation "$generation" --arg lease_id "$lease_id" --arg base_url "$base_url" '
    .adapter_id = $adapter | .generation = $generation | .lease_id = $lease_id | .base_url = $base_url
  ' "$FIXTURES/valid/runtime-manifest.json" > "$target"
}

write_secret() {
  local target="$1" generation="$2" lease_id="$3"
  jq --argjson generation "$generation" --arg lease_id "$lease_id" '
    .generation = $generation | .lease_id = $lease_id
  ' "$FIXTURES/valid/runtime-secret-file.json" > "$target"
  chmod 0400 "$target"
}

expect_exit() {
  local expected="$1" label="$2" actual
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [ "$actual" = "$expected" ] || fail "$label exit=$actual expected=$expected"
}

run_openclaw() {
  local manifest="$1" secret="$2" status="$3" state_root="$4" action="$5"
  MODEL_ACCESS_TEST_MANIFEST_PATH="$manifest" \
  MODEL_ACCESS_TEST_SECRET_PATH="$secret" \
  MODEL_ACCESS_TEST_STATUS_PATH="$status" \
  OPENCLAW_STATE_DIR="$state_root" \
  OPENCLAW_CONFIG_PATH="$state_root/openclaw.json" \
  LABNOW_MODEL_ACCESS_STATE_DIR="$state_root/labnow-model-access" \
  OPENCLAW_BIN=true \
  "$WRAPPER" "$OPENCLAW_ADAPTER" "$action"
}

run_hermes() {
  local manifest="$1" secret="$2" status="$3" home="$4" action="$5"
  MODEL_ACCESS_TEST_MANIFEST_PATH="$manifest" \
  MODEL_ACCESS_TEST_SECRET_PATH="$secret" \
  MODEL_ACCESS_TEST_STATUS_PATH="$status" \
  HERMES_HOME="$home" \
  HERMES_MANAGED_DIR="$home/labnow-model-access" \
  HERMES_BIN=true \
  "$WRAPPER" "$HERMES_ADAPTER" "$action"
}

assert_openclaw_generation_guards() {
  local root="$WORK_DIR/openclaw-generation" runtime config_hash
  runtime="$root/runtime"
  mkdir -p "$runtime" "$root/state"
  printf '{}\n' > "$root/state/openclaw.json"
  write_manifest "$runtime/g1-manifest.json" openclaw 1 lease-generation-001 https://generation-1.invalid/v1
  write_secret "$runtime/g1-secret.json" 1 lease-generation-001
  write_manifest "$runtime/g2-manifest.json" openclaw 2 lease-generation-002 https://generation-2.invalid/v1
  write_secret "$runtime/g2-secret.json" 2 lease-generation-002

  run_openclaw "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/state" apply
  config_hash="$(sha256sum "$root/state/openclaw.json" | awk '{print $1}')"
  run_openclaw "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/state" apply
  [ "$config_hash" = "$(sha256sum "$root/state/openclaw.json" | awk '{print $1}')" ] || fail 'openclaw same-generation apply changed config'
  run_openclaw "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status.json" "$root/state" apply
  jq -e '.generation == 2' "$root/state/labnow-model-access/binding.json" >/dev/null || fail 'openclaw high generation did not advance state'
  expect_exit 74 'openclaw low-generation apply' run_openclaw "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/state" apply
  expect_exit 74 'openclaw late low-generation remove' run_openclaw "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/state" remove
  jq -e '.models.providers.labnow.baseUrl == "https://generation-2.invalid/v1"' "$root/state/openclaw.json" >/dev/null || fail 'openclaw late remove changed generation 2 config'
  run_openclaw "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status.json" "$root/state" remove
  run_openclaw "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status.json" "$root/state" remove
  jq -e '.models.providers.labnow == null' "$root/state/openclaw.json" >/dev/null || fail 'openclaw matching remove left managed config'
}

assert_hermes_generation_guards() {
  local root="$WORK_DIR/hermes-generation" runtime config_hash
  runtime="$root/runtime"
  mkdir -p "$runtime" "$root/home"
  write_manifest "$runtime/g1-manifest.json" hermes 1 lease-generation-001 https://generation-1.invalid/v1
  write_secret "$runtime/g1-secret.json" 1 lease-generation-001
  write_manifest "$runtime/g2-manifest.json" hermes 2 lease-generation-002 https://generation-2.invalid/v1
  write_secret "$runtime/g2-secret.json" 2 lease-generation-002

  run_hermes "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/home" apply
  config_hash="$(sha256sum "$root/home/labnow-model-access/config.yaml" | awk '{print $1}')"
  run_hermes "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/home" apply
  [ "$config_hash" = "$(sha256sum "$root/home/labnow-model-access/config.yaml" | awk '{print $1}')" ] || fail 'hermes same-generation apply changed config'
  run_hermes "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status.json" "$root/home" apply
  jq -e '.generation == 2' "$root/home/labnow-model-access/state/binding.json" >/dev/null || fail 'hermes high generation did not advance state'
  expect_exit 74 'hermes low-generation apply' run_hermes "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/home" apply
  expect_exit 74 'hermes late low-generation remove' run_hermes "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status.json" "$root/home" remove
  jq -e '.model.base_url == "https://generation-2.invalid/v1"' "$root/home/labnow-model-access/config.yaml" >/dev/null || fail 'hermes late remove changed generation 2 config'
  run_hermes "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status.json" "$root/home" remove
  run_hermes "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status.json" "$root/home" remove
  [ ! -e "$root/home/labnow-model-access/config.yaml" ] || fail 'hermes matching remove left managed config'
}

assert_concurrent_openclaw_apply() {
  local root="$WORK_DIR/openclaw-concurrent" runtime g1_pid
  runtime="$root/runtime"
  mkdir -p "$runtime" "$root/state"
  printf '{}\n' > "$root/state/openclaw.json"
  write_manifest "$runtime/g1-manifest.json" openclaw 1 lease-concurrent-001 https://generation-1.invalid/v1
  write_secret "$runtime/g1-secret.json" 1 lease-concurrent-001
  write_manifest "$runtime/g2-manifest.json" openclaw 2 lease-concurrent-002 https://generation-2.invalid/v1
  write_secret "$runtime/g2-secret.json" 2 lease-concurrent-002

  jq() {
    if [ "${PH3_TEST_DELAY:-0}" = 1 ] && [ "${PH3_TEST_DELAY_USED:-0}" = 0 ]; then
      PH3_TEST_DELAY_USED=1
      export PH3_TEST_DELAY_USED
      sleep 1
    fi
    command jq "$@"
  }
  export -f jq
  PH3_TEST_DELAY=1 run_openclaw "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status-g1.json" "$root/state" apply &
  g1_pid=$!
  sleep 0.2
  PH3_TEST_DELAY=0 run_openclaw "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status-g2.json" "$root/state" apply
  wait "$g1_pid"
  unset -f jq
  jq -e '.models.providers.labnow.baseUrl == "https://generation-2.invalid/v1"' "$root/state/openclaw.json" >/dev/null || fail 'serialized concurrent apply did not retain highest generation'
  jq -e '.generation == 2' "$root/state/labnow-model-access/binding.json" >/dev/null || fail 'serialized concurrent apply state did not retain highest generation'
}

assert_trusted_path_rejections() {
  local root="$WORK_DIR/trusted-paths" runtime outside
  runtime="$root/runtime"
  outside="$root/outside"
  mkdir -p "$runtime" "$outside" "$root/openclaw" "$root/hermes"
  write_manifest "$runtime/openclaw-manifest.json" openclaw 1 lease-trusted-001 https://generation-1.invalid/v1
  write_manifest "$runtime/hermes-manifest.json" hermes 1 lease-trusted-001 https://generation-1.invalid/v1
  write_secret "$runtime/secret.json" 1 lease-trusted-001
  ln -s "$outside" "$root/openclaw-parent-link"
  ln -s "$outside" "$root/hermes-parent-link"
  expect_exit 64 'openclaw parent symlink' run_openclaw "$runtime/openclaw-manifest.json" "$runtime/secret.json" "$runtime/openclaw-status.json" "$root/openclaw-parent-link" apply
  expect_exit 64 'hermes parent symlink' run_hermes "$runtime/hermes-manifest.json" "$runtime/secret.json" "$runtime/hermes-status.json" "$root/hermes-parent-link" apply

  set +e
  MODEL_ACCESS_TEST_MANIFEST_PATH="$runtime/openclaw-manifest.json" \
  MODEL_ACCESS_TEST_SECRET_PATH="$runtime/secret.json" \
  MODEL_ACCESS_TEST_STATUS_PATH="$outside/status.json" \
  MODEL_ACCESS_TEST_TRUSTED_RUNTIME_ROOT="$runtime" \
  OPENCLAW_STATE_DIR="$root/openclaw" \
  OPENCLAW_CONFIG_PATH="$root/openclaw/openclaw.json" \
  LABNOW_MODEL_ACCESS_STATE_DIR="$root/openclaw/labnow-model-access" \
  OPENCLAW_BIN=true \
  "$WRAPPER" "$OPENCLAW_ADAPTER" apply >/dev/null 2>&1
  local status_exit=$?
  set -e
  [ "$status_exit" = 64 ] || fail "openclaw untrusted status path exit=$status_exit"
}

assert_check_after_replace_rejected() {
  local root="$WORK_DIR/check-after-replace" runtime outside state writer_pid waiter_pid writer_exit waiter_exit
  runtime="$root/runtime"
  outside="$root/outside"
  state="$root/state"
  mkdir -p "$runtime" "$outside" "$state"
  printf '{}\n' > "$state/openclaw.json"
  write_manifest "$runtime/g1-manifest.json" openclaw 1 lease-replace-001 https://generation-1.invalid/v1
  write_secret "$runtime/g1-secret.json" 1 lease-replace-001
  write_manifest "$runtime/g2-manifest.json" openclaw 2 lease-replace-002 https://generation-2.invalid/v1
  write_secret "$runtime/g2-secret.json" 2 lease-replace-002

  jq() {
    if [ "${PH3_TEST_DELAY:-0}" = 1 ] && [ "${PH3_TEST_DELAY_USED:-0}" = 0 ]; then
      PH3_TEST_DELAY_USED=1
      export PH3_TEST_DELAY_USED
      sleep 1
    fi
    command jq "$@"
  }
  export -f jq
  PH3_TEST_DELAY=1 run_openclaw "$runtime/g1-manifest.json" "$runtime/g1-secret.json" "$runtime/status-g1.json" "$state" apply >/dev/null 2>&1 &
  writer_pid=$!
  for _ in {1..50}; do
    [ -e "$state/labnow-model-access/adapter.lock" ] && break
    sleep 0.02
  done
  [ -e "$state/labnow-model-access/adapter.lock" ] || fail 'replacement test did not acquire its first lock'
  PH3_TEST_DELAY=0 run_openclaw "$runtime/g2-manifest.json" "$runtime/g2-secret.json" "$runtime/status-g2.json" "$state" apply >/dev/null 2>&1 &
  waiter_pid=$!
  sleep 0.2
  mv "$state/labnow-model-access" "$state/labnow-model-access-before-replace"
  ln -s "$outside" "$state/labnow-model-access"
  set +e
  wait "$writer_pid"; writer_exit=$?
  wait "$waiter_pid"; waiter_exit=$?
  set -e
  unset -f jq
  [ "$writer_exit" = 64 ] || fail "writer accepted replaced managed directory exit=$writer_exit"
  [ "$waiter_exit" = 64 ] || fail "waiter accepted check-after-replace exit=$waiter_exit"
  [ ! -e "$outside/binding.json" ] && [ ! -e "$outside/adapter.lock" ] || fail 'replacement redirected adapter state outside the trusted root'
}

assert_openclaw_generation_guards
assert_hermes_generation_guards
assert_concurrent_openclaw_apply
assert_trusted_path_rejections
assert_check_after_replace_rejected
printf 'PASS model-access-hardening\n'
