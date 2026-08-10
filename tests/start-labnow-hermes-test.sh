#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTER="$REPO_ROOT/src/labnow-open-etc/start-labnow-hermes.sh"
FIXTURES="/Users/chengeng/Projects/GitHub/lab_project_analysis/contracts/model-access/v1alpha1/fixtures"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/hermes/labnow-model-access" "$WORK_DIR/bin"
cp "$FIXTURES/valid/runtime-secret-file.json" "$WORK_DIR/secret.json"
chmod 0400 "$WORK_DIR/secret.json"
printf '%s\n' '{"model":{"provider":"custom","api_key":"${OPENAI_API_KEY}"}}' > "$WORK_DIR/hermes/labnow-model-access/config.yaml"
chmod 0600 "$WORK_DIR/hermes/labnow-model-access/config.yaml"

cat > "$WORK_DIR/bin/start-hermes.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${HERMES_HOME:-}" = "$EXPECTED_HERMES_HOME" ]
[ "${HERMES_MANAGED_DIR:-}" = "$EXPECTED_HERMES_MANAGED_DIR" ]
if [ "$EXPECT_MANAGED" = "1" ]; then
  [ -n "${OPENAI_API_KEY:-}" ]
else
  [ -z "${OPENAI_API_KEY:-}" ]
fi
printf '%s\n' '{"started":true}' > "$START_RESULT"
EOF
chmod 0700 "$WORK_DIR/bin/start-hermes.sh"

env -i \
  PATH="$PATH" \
  LABNOW_ALLOW_TEST_PATHS=1 \
  LABNOW_RUNTIME_SECRET_PATH="$WORK_DIR/secret.json" \
  LABNOW_HERMES_START_BIN="$WORK_DIR/bin/start-hermes.sh" \
  HERMES_HOME="$WORK_DIR/hermes" \
  HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
  EXPECTED_HERMES_HOME="$WORK_DIR/hermes" \
  EXPECTED_HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
  EXPECT_MANAGED=1 \
  START_RESULT="$WORK_DIR/start-result.json" \
  "$STARTER" gateway

jq -e '.started == true' "$WORK_DIR/start-result.json" >/dev/null || fail "managed start"
if rg -n --fixed-strings 'test-secret-not-valid' "$WORK_DIR/hermes" "$WORK_DIR/start-result.json"; then
  fail "secret leaked by starter"
fi

rm -f "$WORK_DIR/hermes/labnow-model-access/config.yaml" "$WORK_DIR/start-result.json"
env -i \
  PATH="$PATH" \
  LABNOW_ALLOW_TEST_PATHS=1 \
  LABNOW_RUNTIME_SECRET_PATH="$WORK_DIR/missing-secret.json" \
  LABNOW_HERMES_START_BIN="$WORK_DIR/bin/start-hermes.sh" \
  HERMES_HOME="$WORK_DIR/hermes" \
  HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
  EXPECTED_HERMES_HOME="$WORK_DIR/hermes" \
  EXPECTED_HERMES_MANAGED_DIR="$WORK_DIR/hermes/labnow-model-access" \
  EXPECT_MANAGED=0 \
  START_RESULT="$WORK_DIR/start-result.json" \
  "$STARTER" dashboard
jq -e '.started == true' "$WORK_DIR/start-result.json" >/dev/null || fail "unmanaged start"

printf 'PASS start-labnow-hermes\n'
