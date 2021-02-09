FROM docker:20.10.2-dind

ARG BATS_VER=v1.2.1

#Install Testing Dependencies
RUN apk add --no-cache iptables git bash curl python3-dev py-pip libffi-dev openssl-dev gcc libc-dev make && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o rustup.sh && \
    chmod 700 rustup.sh && \
    ./rustup.sh -y && \
    source $HOME/.cargo/env && \
    pip install docker-compose && \
    git clone --depth 1 --branch $BATS_VER  https://github.com/bats-core/bats-core.git /opt/bats && \
    /opt/bats/install.sh /usr/local

#Copy Repo
COPY . /opt/traefikjam

ENTRYPOINT /opt/traefikjam/test/containers/traefikjam_test/entrypoint.sh
