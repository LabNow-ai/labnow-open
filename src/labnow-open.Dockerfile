# Use the existing image as the base
ARG BASE_NAMESPACE="quay.io"
ARG BASE_IMG="labnow/developer:latest"

# this ENV will be used in /opt/utils/script-localize.sh
ARG PROFILE_LOCALIZE="aliyun-pub"

FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS builder
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY ./src/labnow-open-web /tmp/labnow-open-web
COPY ./src/labnow-open-etc /opt/labnow-open/etc
RUN set -eux \
 && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 && source /opt/utils/script-setup-core.sh && setup_node_pnpm 11 \
 && cd /tmp/labnow-open-web \
 && export CI=true && pnpm install --no-strict-peer-dependencies && pnpm run build \
 && mkdir -pv /opt/labnow-open && mv dist /opt/labnow-open/web \
 && ls -alh /opt/labnow-open/web /opt/labnow-open/etc


FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS runtime
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY --from=builder /opt/labnow-open/ /opt/labnow-open/
COPY ./src/labnow-open-etc/healthcheck-server.py /usr/local/bin/healthcheck-server.py

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # handle control scripts and extensions
 && (type supervisord || (source /opt/utils/script-setup-sys.sh && setup_supervisord && echo "Supervisord installed")) \
 && (type caddy       || (source /opt/utils/script-setup-net.sh && setup_caddy       && echo "Caddy installed")) \
 && (type openclaw    && type caddy && printf '#!/bin/bash\ncaddy run --config /etc/caddy/Caddyfile\n' > /usr/local/bin/start-caddy.sh && chmod +x /usr/local/bin/start-caddy.sh) \
 && mkdir -pv /etc/supervisord && ln -sf /opt/labnow-open/etc/supervisord.conf   /etc/supervisord/ \
 && mkdir -pv /etc/caddy       && ln -sf /opt/labnow-open/etc/Caddyfile          /etc/caddy/ \
 && (type jupyter      && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json || true) \
 && (type jupyter      && printf "[program:jupyter]\ncommand=/usr/local/bin/start-jupyterlab.sh\n"  >> /etc/supervisord/supervisord.conf || true) \
 && (type code-server  && printf "[program:vscode]\ncommand=/usr/local/bin/start-code-server.sh\n"  >> /etc/supervisord/supervisord.conf || true) \
 && (type rserver      && printf "[program:rserver]\ncommand=/usr/local/bin/start-rserver.sh\n"     >> /etc/supervisord/supervisord.conf || true) \
 && (type shiny-server && printf "[program:rshiny]\ncommand=/usr/local/bin/start-shiny-server.sh\n" >> /etc/supervisord/supervisord.conf || true) \
 && (type openclaw     && printf "[program:openclaw]\ncommand=/usr/local/bin/start-openclaw.sh gateway --allow-unconfigured\nautostart=true\n"   >> /etc/supervisord/supervisord.conf || true) \
 && (type openclaw     && printf '[program:healthcheck]\ncommand=/usr/local/bin/healthcheck-server.py\nautostart=true\nautorestart=true\n' >> /etc/supervisord/supervisord.conf || true) \
 && (type hermes       && printf "[program:hermes]\ncommand=/usr/local/bin/start-hermes.sh\n"       >> /etc/supervisord/supervisord.conf || true) \
 # create start-supervisord.sh for JupyterHub spawner compatibility
 && printf '#!/bin/bash\n[ $BASH ] && [ -f /etc/profile ] && [ -z $ENTER_PROFILE ] && . /etc/profile\nDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"\nLOG_FORMAT=json exec supervisord -c /etc/supervisord/supervisord.conf\n' > /usr/local/bin/start-supervisord.sh \
 && chmod +x /usr/local/bin/start-supervisord.sh \
 # cleanup of any temporary or cache files to keep the image size down
 && rm -rf /opt/conda/share/jupyter/lab/staging \
 && source /opt/utils/script-utils.sh && install__clean

WORKDIR $HOME_DIR
ENV STATIC_DIR=/opt/labnow-open/web
EXPOSE 80
CMD ["/bin/bash", "start-supervisord.sh"]
