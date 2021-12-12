FROM docker:20.10.11

RUN apk add --no-cache bash iproute2 iptables tzdata

COPY trafficjam.sh /usr/local/bin/trafficjam.sh
COPY trafficjam-functions.sh /usr/local/bin/trafficjam-functions.sh

HEALTHCHECK --timeout=3s CMD ps aux | grep [t]rafficjam.sh

ENTRYPOINT ["/usr/local/bin/trafficjam.sh"]