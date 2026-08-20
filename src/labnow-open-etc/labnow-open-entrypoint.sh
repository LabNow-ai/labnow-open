#!/usr/bin/env bash
# Materialize the build-time application-kind decision for every container
# command, including explicit `docker run <image> printenv APP_KIND` audits.
set -Eeuo pipefail

readonly APP_KIND_FILE="/etc/labnow-open/app-kind.env"

[ -r "$APP_KIND_FILE" ] || {
  printf '%s\n' "labnow-open-entrypoint: missing ${APP_KIND_FILE}" >&2
  exit 64
}

# The file is emitted by the Dockerfile from a fixed literal value after the
# image capability check; constrain it before importing into this shell.
case "$(cat "$APP_KIND_FILE")" in
  APP_KIND=openclaw|APP_KIND=hermes)
    # shellcheck disable=SC1090
    source "$APP_KIND_FILE"
    export APP_KIND
    ;;
  *)
    printf '%s\n' "labnow-open-entrypoint: invalid ${APP_KIND_FILE}" >&2
    exit 64
    ;;
esac

exec "$@"
