FROM docker:28.0.4-dind

ARG BATS_VER=v1.8.0

#Install Testing Dependencies
RUN apk add --no-cache bash curl && \
    git clone --depth 1 --branch $BATS_VER  https://github.com/bats-core/bats-core.git /opt/bats && \
    /opt/bats/install.sh /usr/local

#Copy Repo
COPY . /opt/trafficjam
