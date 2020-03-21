FROM docker

RUN apk add --update --no-cache bash

COPY traefikjam.sh /usr/local/bin/traefikjam.sh
COPY traefikjam-functions.sh /us/local/bin/traefikjam-functions.sh

ENTRYPOINT ["/usr/local/bin/traefikjam.sh"]