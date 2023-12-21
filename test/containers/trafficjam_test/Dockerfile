FROM docker:24.0.7-dind

ARG BATS_VER=v1.8.0

#Install Testing Dependencies
RUN apk add --no-cache iptables git bash curl && \
    git clone --depth 1 --branch $BATS_VER  https://github.com/bats-core/bats-core.git /opt/bats && \
    /opt/bats/install.sh /usr/local

#Copy Repo
COPY . /opt/trafficjam

ENTRYPOINT /opt/trafficjam/test/containers/trafficjam_test/entrypoint.sh
