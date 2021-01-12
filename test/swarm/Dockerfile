FROM docker:20.10.2-dind

RUN mkdir -p /opt/traefikjam

COPY . /opt/traefikjam

ENTRYPOINT /opt/traefikjam/test/swarm/entrypoint.sh