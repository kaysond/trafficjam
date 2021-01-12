FROM docker:20.10.2-dind

RUN mkdir -p /opt/traefikjam

COPY ../../* /opt/traefikjam
RUN docker build -t traefikjam /opt/traefikjam

ENTRYPOINT /opt/traefikjam/test/swarm/entrypoint.sh
