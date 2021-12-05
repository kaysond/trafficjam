FROM docker:20.10.11-dind

ARG BATS_VER=v1.2.1
ARG DOCKER_COMPOSE_VER=v2.0.1

#Install Testing Dependencies
RUN apk add --no-cache iptables git bash curl && \
    curl -SL https://github.com/docker/compose/releases/download/v2.0.1/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose && \
    chmod a+x /usr/local/bin/docker-compose && \
    git clone --depth 1 --branch $BATS_VER  https://github.com/bats-core/bats-core.git /opt/bats && \
    /opt/bats/install.sh /usr/local

#Copy Repo
COPY . /opt/trafficjam

ENTRYPOINT /opt/trafficjam/test/containers/trafficjam_test/entrypoint.sh
