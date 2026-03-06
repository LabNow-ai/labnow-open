# Use the existing image as the base
ARG BASE_NAMESPACE="quay.io"
ARG BASE_IMG="labnow/developer:latest"

# this ENV will be used in /opt/utils/script-localize.sh
ARG PROFILE_LOCALIZE="aliyun-pub"

FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS builder
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY ./src/labnow-open-web /tmp/labnow-open-web
RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 && cd /tmp/labnow-open-web \
 && export CI=true && npx pnpm i \
 && URL_PREFIX='/home' npm run build \
 && ls -alh /tmp/labnow-open-web/dist


FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS runtime
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}
ENV STATIC_DIR=/opt/labnow-open/web

COPY --from=builder /tmp/labnow-open-web/dist /opt/labnow-open/web
COPY ./src/labnow-open-etc /opt/labnow-open

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # handle control scripts and extensions
 && mkdir -pv /etc/supervisord && ln -sf /opt/labnow-open/supervisord.conf   /etc/supervisord/ \
 && mkdir -pv /etc/caddy       && ln -sf /opt/labnow-open/Caddyfile          /etc/caddy/ \
 && (type code-server  && printf "[program:vscode]\ncommand=/usr/local/bin/start-code-server.sh\n" >> /etc/supervisord/supervisord.conf || true) \
 && (type rserver      && printf "[program:rserver]\ncommand=/usr/local/bin/start-rserver.sh\n"    >> /etc/supervisord/supervisord.conf || true) \
 && (type shiny-server && printf "[program:shiny]\ncommand=/usr/local/bin/start-shiny-server.sh\n" >> /etc/supervisord/supervisord.conf || true) \
 && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json \
 # cleanup of any temporary or cache files to keep the image size down
 && rm -rf /opt/conda/share/jupyter/lab/staging \
 && source /opt/utils/script-utils.sh && install__clean

WORKDIR $HOME_DIR
CMD ["/bin/bash", "start-supervisord.sh"]
