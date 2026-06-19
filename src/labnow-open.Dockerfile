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

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # handle control scripts and extensions
 && (type caddy       || (source /opt/utils/script-setup-net.sh && setup_caddy && echo "Caddy installed")) \
 && (type supervisord || (source /opt/utils/script-setup-sys.sh && setup_supervisord && echo "Supervisord installed")) \
 && mkdir -pv /etc/supervisord && ln -sf /opt/labnow-open/etc/supervisord.conf   /etc/supervisord/ \
 && mkdir -pv /etc/caddy       && ln -sf /opt/labnow-open/etc/Caddyfile          /etc/caddy/ \
 && (type jupyter      && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json || true) \
 && (type code-server  && printf "[program:vscode]\ncommand=/usr/local/bin/start-code-server.sh\n"  >> /etc/supervisord/supervisord.conf || true) \
 && (type rserver      && printf "[program:rserver]\ncommand=/usr/local/bin/start-rserver.sh\n"     >> /etc/supervisord/supervisord.conf || true) \
 && (type shiny-server && printf "[program:rshiny]\ncommand=/usr/local/bin/start-shiny-server.sh\n" >> /etc/supervisord/supervisord.conf || true) \
 # cleanup of any temporary or cache files to keep the image size down
 && rm -rf /opt/conda/share/jupyter/lab/staging \
 && source /opt/utils/script-utils.sh && install__clean

WORKDIR $HOME_DIR
ENV STATIC_DIR=/opt/labnow-open/web
EXPOSE 80
CMD ["/bin/bash", "start-supervisord.sh"]
