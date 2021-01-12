#!/usr/bin/env sh
dockerd &
while ! docker ps; do sleep 1; done
docker build -t traefikjam /opt/traefikjam
docker build -t whoami /opt/traefikjam/test/whoami
sleep infinity