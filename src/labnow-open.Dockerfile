# Use the existing image as the base
ARG BASE_NAMESPACE="quay.io"
ARG BASE_IMG="labnow/developer:latest"
ARG NODE_BUILD_IMG="labnow/node@sha256:fd09d9de9b7aa927493acbafbb7d399c089465e988f2a6a240428cdbbd5424e2"

# this ENV will be used in /opt/utils/script-localize.sh
ARG PROFILE_LOCALIZE="aliyun-pub"

# The frozen Node image supplies both the Web build and the Hermes TUI runtime.
# Hermes accepts a modern PATH Node; keeping it in the image avoids an unsafe
# first-use download/extraction into the Workspace persistent volume.
FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${NODE_BUILD_IMG} AS builder
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}
COPY ./src/labnow-open-web /tmp/labnow-open-web
COPY ./src/labnow-open-etc /opt/labnow-open/etc
RUN set -eux \
 && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # The frozen Node build base installs pnpm 10 as a standalone binary.
 && source /opt/utils/script-setup-core.sh && setup_node_pnpm 10 \
 && cd /tmp/labnow-open-web \
 && export CI=true && pnpm install --no-strict-peer-dependencies && pnpm run build \
 && mkdir -pv /opt/labnow-open && mv dist /opt/labnow-open/web \
 && ls -alh /opt/labnow-open/web /opt/labnow-open/etc


FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS runtime
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}
# Keep the OpenClaw CLI, the Gateway and the LabNow adapter on the same
# workspace-local configuration file. The adapter only stores a file SecretRef.
ENV OPENCLAW_CONFIG=/root/.openclaw/data/openclaw.json \
    OPENCLAW_CONFIG_PATH=/root/.openclaw/data/openclaw.json
# Hermes merges this private managed scope over user-owned ~/.hermes/config.yaml.
ENV HERMES_MANAGED_DIR=/root/.hermes/labnow-model-access

COPY --from=builder /opt/labnow-open/ /opt/labnow-open/
COPY --from=builder /opt/labnow-open/etc/Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /opt/labnow-open/etc/supervisord.conf /etc/supervisord/supervisord.conf
COPY --from=builder /opt/labnow-open/etc/supervisor/available.d/ /etc/supervisord/available.d/
COPY --from=builder /opt/labnow-open/etc/caddy/ /etc/caddy/
COPY --from=builder /opt/labnow-open/etc/labnow-open-entrypoint.sh /usr/local/bin/labnow-open-entrypoint.sh

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # handle control scripts and extensions
 && (type supervisord || (source /opt/utils/script-setup-sys.sh && setup_supervisord && echo "Supervisord installed")) \
 && (type caddy       || (source /opt/utils/script-setup-net.sh && setup_caddy       && echo "Caddy installed")) \
 && mkdir -pv /etc/supervisord/enabled-programs /etc/caddy/routes.d/enabled /etc/labnow-open \
 && chmod +x /opt/labnow-open/etc/openclaw-model-access-adapter.sh \
 && ln -sf /opt/labnow-open/etc/openclaw-model-access-adapter.sh /usr/local/bin/openclaw-model-access-adapter \
 && chmod +x /opt/labnow-open/etc/start-labnow-openclaw.sh \
 && ln -sf /opt/labnow-open/etc/start-labnow-openclaw.sh /usr/local/bin/start-labnow-openclaw.sh \
 && chmod +x /opt/labnow-open/etc/hermes-model-access-adapter.sh \
 && ln -sf /opt/labnow-open/etc/hermes-model-access-adapter.sh /usr/local/bin/hermes-model-access-adapter \
 && chmod +x /opt/labnow-open/etc/start-labnow-hermes.sh \
 && ln -sf /opt/labnow-open/etc/start-labnow-hermes.sh /usr/local/bin/start-labnow-hermes.sh \
 && ([ ! -f /usr/local/bin/start-supervisord.sh ] && printf '#!/bin/bash\nLOG_FORMAT=json exec supervisord -c /etc/supervisord/supervisord.conf\n' > /usr/local/bin/start-supervisord.sh || true ) \
 && ([ ! -f /usr/local/bin/start-caddy.sh ] && printf '#!/bin/bash\ncaddy run --config /etc/caddy/Caddyfile\n' > /usr/local/bin/start-caddy.sh || true ) \
 && chmod +x /usr/local/bin/labnow-open-entrypoint.sh /usr/local/bin/start-caddy.sh /usr/local/bin/start-supervisord.sh \
 && (type jupyter      && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json || true) \
 && (type jupyter      && ln -sf /etc/supervisord/available.d/jupyter.conf /etc/supervisord/enabled-programs/jupyter.conf || true) \
 && (type code-server  && ln -sf /etc/supervisord/available.d/vscode.conf /etc/supervisord/enabled-programs/vscode.conf || true) \
 && (type rserver      && ln -sf /etc/supervisord/available.d/rserver.conf /etc/supervisord/enabled-programs/rserver.conf || true) \
 && (type shiny-server && ln -sf /etc/supervisord/available.d/rshiny.conf /etc/supervisord/enabled-programs/rshiny.conf || true) \
 && app_kind='' \
 && if type openclaw >/dev/null 2>&1; then app_kind='openclaw'; fi \
 && if type hermes >/dev/null 2>&1; then \
      [ -z "$app_kind" ] || { echo 'ambiguous app kind: both openclaw and hermes are installed' >&2; exit 1; }; \
      app_kind='hermes'; \
    fi \
 && [ -n "$app_kind" ] || { echo 'unable to determine app kind: neither openclaw nor hermes is installed' >&2; exit 1; } \
 && printf 'APP_KIND=%s\n' "$app_kind" > /etc/labnow-open/app-kind.env \
 && chmod 0644 /etc/labnow-open/app-kind.env \
 && ln -sf "/etc/caddy/routes.d/${app_kind}-readiness.caddy" /etc/caddy/routes.d/enabled/readiness.caddy \
 && if [ "$app_kind" = 'openclaw' ]; then \
      ln -sf /etc/supervisord/available.d/openclaw.conf /etc/supervisord/enabled-programs/openclaw.conf; \
    else \
      ln -sf /etc/supervisord/available.d/hermes.conf /etc/supervisord/enabled-programs/hermes.conf; \
    fi \
 # cleanup of any temporary or cache files to keep the image size down
 && rm -rf /opt/conda/share/jupyter/lab/staging \
 && source /opt/utils/script-utils.sh && install__clean

# Keep this after the product setup layer so the fixed Node runtime does not
# re-run unrelated network installation steps during a Hermes-only rebuild.
COPY --from=builder /opt/node/ /opt/node/
ENV PATH=/opt/node/bin:${PATH}

WORKDIR $HOME_DIR
ENV STATIC_DIR=/opt/labnow-open/web
EXPOSE 80
ENTRYPOINT ["/usr/local/bin/labnow-open-entrypoint.sh"]
CMD ["/bin/bash", "start-supervisord.sh"]
