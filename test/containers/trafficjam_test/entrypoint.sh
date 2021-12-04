#!/usr/bin/env bash

#Check for nftables testing
if [[ -n "$NFTABLES" ]]; then
  ln -s /sbin/xtables-nft-multi /sbin/iptables -f
fi
/usr/local/bin/dockerd-entrypoint.sh dockerd &
#Wait for docker startup for 60s
while ! docker ps; do
    if (( ++i > 12 )); then
        echo "Timed out waiting for docker to start up" >&2
        exit 1
    fi
    sleep 5
done
docker build -t trafficjam /opt/trafficjam || exit 1;
docker build -t whoami /opt/trafficjam/test/containers/whoami || exit 1;
sleep infinity
