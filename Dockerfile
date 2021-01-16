FROM docker

RUN apk add --no-cache bash iproute2 iptables tzdata

COPY traefikjam.sh /usr/local/bin/traefikjam.sh
COPY traefikjam-functions.sh /usr/local/bin/traefikjam-functions.sh

ENTRYPOINT ["/usr/local/bin/traefikjam.sh"]