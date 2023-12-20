FROM eco4cast/rocker-neon4cast:latest

# Import GitHub Secret
ARG GITHUB_PAT
ENV GITHUB_PAT=$GITHUB_PAT

# Declares build arguments
# ARG NB_USER
# ARG NB_UID

# COPY --chown=${NB_USER} . ${HOME}

#USER ${NB_USER}
RUN install2.r --error \
  clustermq \
  dataRetrieval \
  tarchetypes \
  targets \
  && rm -rf /tmp/downloaded_packages /tmp/*.rds /tmp/Rtmp*

COPY cron.sh /etc/services.d/cron/run
