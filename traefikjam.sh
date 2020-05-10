#!/bin/bash
#set -Eeuo pipefail
set -uo pipefail

if [[ -z "${NETWORK:-}" ]]; then
	echo "NETWORK is not set" >&2
	exit 1
fi

if [[ -z "${WHITELIST_FILTERS:-}" ]]; then
	echo "WHITELIST_FILTERS is not set" >&2
	exit 1
fi

#Initialize variables since we set -u
POLL_INTERVAL="${POLL_INTERVAL:-5}"
ALLOW_HOST_TRAFFIC="${ALLOW_HOST_TRAFFIC:-}"
DEBUG="${DEBUG:-}"
OLD_SUBNET=""
OLD_WHITELIST=""

#CRC32 without packages
TJINSTANCE=$(echo -n "$NETWORK ${WHITELIST_FILTERS[*]}" | gzip -c | tail -c8 | hexdump -n4 -e '"%08X"')

. traefikjam-functions.sh

get_network_driver || exit 1

if [[ "$DRIVER" == "bridge" ]]; then #not swarm
	ERRCOUNT=0
	while true; do
		#Slow logging on errors
		log_debug "Error Count: $ERRCOUNT"
		if (( ERRCOUNT > 10 )); then
			SLEEP_TIME=$(( POLL_INTERVAL*11 ))
		else
			SLEEP_TIME=$(( POLL_INTERVAL*(ERRCOUNT+1) ))
		fi

		sleep "${SLEEP_TIME}s"
		get_network_subnet || continue

		get_container_whitelist || continue

		DATE=$(date "+%Y-%m-%d %H:%M:%S")

		if [[ "$SUBNET" != "$OLD_SUBNET" && "${WHITELIST[*]}" != "${OLD_WHITELIST[*]}" ]]; then
			block_subnet_traffic  || continue

			if [[ -z "$ALLOW_HOST_TRAFFIC" ]]; then
				block_host_traffic  || continue
			fi

			allow_whitelist_traffic  || continue

			remove_old_rules DOCKER-USER; remove_old_rules INPUT || continue

			OLD_SUBNET="$SUBNET"

			OLD_WHITELIST=("${WHITELIST[@]}")
		fi

		ERRCOUNT=0
	done
elif [[ "$DRIVER" == "overlay" ]]; then #swarm
	echo
fi

#block traffic from docker network to local processes (i.e. published ports)
#sudo iptables -I INPUT -s 172.23.0.0/24 -j DROP


# ---------
# swarm (DRIVER == "overlay")
# ---------

#get container ip address:
#docker inspect --format="{{ (index .NetworkSettings.Networks \"${NETWORK_NAME}\").IPAddress }}" "${CONTAINER_ID}"
#NEED TO GET SERVICE VIP


#setup:
 #ln -s /var/run/docker/netns /var/run/netns

#get network id (for namespace):
#NETWORK_ID=$(docker network inspect --format="{{.ID}}" "${NETWORK_NAME}")

#get netns:
#NETNS=$(ls /var/run/netns | grep -vE "^lb_" | grep "${NETWORK_ID:0:9}")
