#!/usr/bin/env bash
/usr/local/bin/dockerd-entrypoint.sh dockerd &
while ! docker ps; do sleep $(( ++i )) && (( i < 10 )) || exit 1; done #wait for docker to start up for 45s
docker build -t trafficjam /opt/trafficjam || exit 1;
docker build -t whoami /opt/trafficjam/test/containers/whoami || exit 1;
sleep infinity