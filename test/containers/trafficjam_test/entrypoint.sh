#!/usr/bin/env bash

/usr/local/bin/dockerd-entrypoint.sh dockerd &
# Wait for docker daemon to start up so we can build the containers
while ! docker ps &> /dev/null; do
    if (( ++i > 24 )); then
        echo "Timed out waiting for docker to start up" >&2
        exit 1
    fi
    sleep 5
done
docker build -t trafficjam /opt/trafficjam || exit 1;
docker build -t whoami /opt/trafficjam/test/containers/whoami || exit 1;
sleep infinity
