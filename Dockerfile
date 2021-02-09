FROM docker

RUN apk add --no-cache bash iproute2 iptables tzdata

COPY traefikjam.sh /usr/local/bin/traefikjam.sh
COPY traefikjam-functions.sh /usr/local/bin/traefikjam-functions.sh

HEALTHCHECK --timeout=3s CMD ps aux | grep [t]raefikjam.sh

ENTRYPOINT ["/usr/local/bin/traefikjam.sh"]
