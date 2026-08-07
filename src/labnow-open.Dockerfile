# Use the existing image as the base
ARG BASE_NAMESPACE="quay.io"
ARG BASE_IMG_BUILD="node:latest"
ARG BASE_IMG="developer:latest"

# this ENV will be used in /opt/utils/script-localize.sh
ARG PROFILE_LOCALIZE="aliyun-pub"

FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG_BUILD} AS builder
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY ./labnow-open-web /tmp/labnow-open-web
COPY ./labnow-open-etc /opt/labnow-open/etc
RUN set -eux \
 && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 && source /opt/utils/script-setup-core.sh && setup_node_pnpm 11 \
 && cd /tmp/labnow-open-web \
 && export CI=true && export CARBON_TELEMETRY_DISABLED=1 && pnpm install --no-strict-peer-dependencies --ignore-scripts && pnpm run build \
 && mkdir -pv /opt/labnow-open && mv dist /opt/labnow-open/web \
 && ls -alh /opt/labnow-open/web /opt/labnow-open/etc


FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS runtime
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY --from=builder /opt/labnow-open/ /opt/labnow-open/

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 ## install Caddy and link the configuration files
 && (type caddy || (source /opt/utils/script-setup-net.sh && setup_caddy && echo "Caddy installed")) \
 && mkdir -pv /etc/caddy && ln -sf /opt/labnow-open/etc/Caddy* /etc/caddy/ \
 && ([ ! -f /usr/local/bin/start-caddy.sh ] && printf '#!/bin/bash\ncaddy run --config /etc/caddy/Caddyfile\n' > /usr/local/bin/start-caddy.sh || true ) \
 ## handle control scripts and extensions
 && (type supervisord || (source /opt/utils/script-setup-sys.sh && setup_supervisord && echo "Supervisord installed")) \
 && mkdir -pv /etc/supervisord \
 && ([ ! -f /etc/supervisord/supervisord.conf ] && ln -sf /opt/labnow-open/etc/supervisord.conf /etc/supervisord/ || true ) \
 && printf '\n[program:caddy]\ncommand=/usr/local/bin/start-caddy.sh\nautostart=true\n\n' >> /etc/supervisord/supervisord.conf \
 && ([ ! -f /usr/local/bin/start-supervisord.sh ] && printf '#!/bin/bash\nLOG_FORMAT=json exec supervisord -c /etc/supervisord/supervisord.conf\n' > /usr/local/bin/start-supervisord.sh || true ) \
 ## handle supervisord start options
 && (type jupyter      && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json || true) \
 && (type jupyter      && printf "[program:jupyter]\ncommand=/usr/local/bin/start-jupyterlab.sh\n"  >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/jupyter.caddy  ) \
 && (type code-server  && printf "[program:vscode]\ncommand=/usr/local/bin/start-code-server.sh\n"  >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/vscode.caddy   ) \
 && (type rserver      && printf "[program:rserver]\ncommand=/usr/local/bin/start-rserver.sh\n"     >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/rserver.caddy  ) \
 && (type shiny-server && printf "[program:rshiny]\ncommand=/usr/local/bin/start-shiny-server.sh\n" >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/shiny.caddy    ) \
 && (type openclaw     && printf "[program:openclaw]\ncommand=/usr/local/bin/start-openclaw.sh\n"   >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/openclaw.caddy ) \
 && (type hermes       && echo "Skipping configure supervisord for hermes as already processed..."  >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/hermes.caddy   ) \
 && (                  && echo "Skipping selkies process as not implemented yet..."                 >> /etc/supervisord/supervisord.conf || rm -f /opt/labnow-open/etc/CaddyRoutes/selkies.caddy  ) \
 ## cleanup of any temporary or cache files to keep the image size down
 && chmod +x /usr/local/bin/start-caddy.sh /usr/local/bin/start-supervisord.sh \
 && source /opt/utils/script-utils.sh && install__clean

WORKDIR $HOME_DIR
ENV STATIC_DIR=/opt/labnow-open/web
ENV URL_PREFIX="/"
EXPOSE 80
CMD ["/bin/bash", "start-supervisord.sh"]
