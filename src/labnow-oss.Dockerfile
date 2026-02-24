# Use the existing image as the base
ARG BASE_NAMESPACE="quay.io"
ARG BASE_IMG="labnow/developer:latest"

# this ENV will be used in /opt/utils/script-localize.sh
ARG PROFILE_LOCALIZE="aliyun-pub"

FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS builder
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY ./src/labnow-oss-web /tmp/labnow-oss-web
RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 && cd /tmp/labnow-oss-web \
 && export CI=true && npx pnpm i && npm run build \
 && ls -alh /tmp/labnow-oss-web/dist


FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG} AS runtime
ARG PROFILE_LOCALIZE="aliyun-pub"

ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}
ENV STATIC_DIR=/opt/labnow-oss/web

COPY --from=builder /tmp/labnow-oss-web/dist /opt/labnow-oss/web
COPY ./src/labnow-oss-etc /opt/labnow-oss

RUN set -eux && source /opt/utils/script-localize.sh ${PROFILE_LOCALIZE} \
 # handle control scripts and extensions
 && (type code-server && printf "[program:vscode]\ncommand=/usr/local/bin/start-code-server.sh\n" >> /opt/labnow-oss/supervisord.conf || true) \
 && (type reserver    && printf "[program:rserver]\ncommand=/usr/local/bin/start-rserver.sh\n"    >> /opt/labnow-oss/supervisord.conf || true) \
 && mkdir -pv /etc/supervisord && ln -sf /opt/labnow-oss/supervisord.conf   /etc/supervisord/ \
 && mkdir -pv /etc/caddy       && ln -sf /opt/labnow-oss/Caddyfile          /etc/caddy/ \
 && echo '{"ServerApp":{"ip":"0.0.0.0","port":8888,"root_dir":"/root","default_url":"/home","token":"","password":"","allow_root":true,"allow_origin":"*","open_browser":false}}' > /opt/conda/etc/jupyter/jupyter_server_config.json \
 # cleanup of any temporary or cache files to keep the image size down
 && rm -rf /opt/conda/share/jupyter/lab/staging \
 && source /opt/utils/script-utils.sh && install__clean

WORKDIR $HOME_DIR
CMD ["/bin/bash", "start-supervisord.sh"]
