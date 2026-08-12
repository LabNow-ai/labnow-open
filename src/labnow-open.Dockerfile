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

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # handle control scripts and extensions
 && (type supervisord || (source /opt/utils/script-setup-sys.sh && setup_supervisord && echo "Supervisord installed")) \
 && (type caddy       || (source /opt/utils/script-setup-net.sh && setup_caddy       && echo "Caddy installed")) \
 && mkdir -pv /etc/supervisord && ln -sf /opt/labnow-open/etc/supervisord.conf   /etc/supervisord/ \
 && mkdir -pv /etc/caddy /etc/caddy/enabled-routes && ln -sf /opt/labnow-open/etc/Caddyfile /etc/caddy/ \
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
 && chmod +x /usr/local/bin/start-caddy.sh /usr/local/bin/start-supervisord.sh \
 && (type jupyter      && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json || true) \
 && (type jupyter      && printf "[program:jupyter]\ncommand=/usr/local/bin/start-jupyterlab.sh\n"  >> /etc/supervisord/supervisord.conf || true) \
 && (type code-server  && printf "[program:vscode]\ncommand=/usr/local/bin/start-code-server.sh\n"  >> /etc/supervisord/supervisord.conf || true) \
 && (type rserver      && printf "[program:rserver]\ncommand=/usr/local/bin/start-rserver.sh\n"     >> /etc/supervisord/supervisord.conf || true) \
 && (type shiny-server && printf "[program:rshiny]\ncommand=/usr/local/bin/start-shiny-server.sh\n" >> /etc/supervisord/supervisord.conf || true) \
 && (type openclaw     && printf "[program:openclaw]\ncommand=/usr/local/bin/start-labnow-openclaw.sh\nautostart=true\n"   >> /etc/supervisord/supervisord.conf || true) \
 && (type openclaw     && ln -sf /opt/labnow-open/etc/routes/openclaw-readiness.caddy /etc/caddy/enabled-routes/openclaw-readiness.caddy || true) \
 && (type hermes       && printf "[program:hermes-gateway]\ncommand=/usr/local/bin/start-labnow-hermes.sh gateway\nautostart=true\n\n[program:hermes-dashboard]\ncommand=/usr/local/bin/start-labnow-hermes.sh dashboard --host 127.0.0.1 --port 9119 --no-open\nautostart=true\n" >> /etc/supervisord/supervisord.conf || true) \
 && (type hermes       && ln -sf /opt/labnow-open/etc/routes/hermes-readiness.caddy /etc/caddy/enabled-routes/hermes-readiness.caddy || true) \
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
CMD ["/bin/bash", "start-supervisord.sh"]
