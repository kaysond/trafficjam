#!/usr/bin/env bash
/usr/local/bin/dockerd-entrypoint.sh dockerd &
while ! docker ps; do sleep 1; done #wait for docker to start up
docker build -t traefikjam /opt/traefikjam
docker build -t whoami /opt/traefikjam/test/containers/whoami
sleep infinity
