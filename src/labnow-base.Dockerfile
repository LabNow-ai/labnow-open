# Use the existing image as the base
ARG BASE_NAMESPACE="quay.io"
ARG BASE_IMG="labnow/developer:latest"
ARG PROFILE_LOCALIZE="aliyun-pub"

FROM ${BASE_NAMESPACE:+$BASE_NAMESPACE/}${BASE_IMG}
# this ENV will be used in /opt/utils/script-localize.sh
ENV PROFILE_LOCALIZE=${PROFILE_LOCALIZE}

COPY ./src/labnow-base /opt/labnow-base


RUN set -eux && source /opt/utils/script-localize.sh \
 # handle control scripts and extensions
 && mkdir -pv /etc/supervisord && mv /opt/labnow-base/control/supervisord.conf /etc/supervisord/ \
 && mkdir -pv /etc/caddy       && mv /opt/labnow-base/control/Caddyfile /etc/caddy/ \
 # install data science packages
 && pip install pandas scikit-learn xlrd scipy seaborn matplotlib statsmodels xgboost plotly \
 # cleanup of any temporary or cache files to keep the image size down
 && rm -rf /opt/conda/share/jupyter/lab/staging \
 && source /opt/utils/script-utils.sh && install__clean

WORKDIR $HOME_DIR
CMD ["/bin/bash", "start-supervisord.sh"]
