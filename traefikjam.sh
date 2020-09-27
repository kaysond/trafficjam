#!/bin/bash
set -Eeuo pipefail

if [[ -z "${NETWORK:-}" ]]; then
	echo "NETWORK is not set" >&2
	exit 1
fi

if [[ -z "${WHITELIST_FILTER:-}" ]]; then
	echo "WHITELIST_FILTER is not set" >&2
	exit 1
fi

#Initialize variables since we set -u
POLL_INTERVAL="${POLL_INTERVAL:-5}"
ALLOW_HOST_TRAFFIC="${ALLOW_HOST_TRAFFIC:-}"
DEBUG="${DEBUG:-}"
TZ="${TZ:-}"
NETNS=""
OLD_SUBNET=""
OLD_WHITELIST=""

if [[ -n "$TZ" ]]; then
	cp /usr/share/zoneinfo/"$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

#CRC32 without packages
TJINSTANCE=$(echo -n "$NETWORK $WHITELIST_FILTER" | gzip -c | tail -c8 | hexdump -n4 -e '"%08X"')

. traefikjam-functions.sh

get_network_driver || { log_error "Could not get network driver"; exit 1; }

ERRCOUNT=0
while true; do
	#Slow logging on errors
	log_debug "Error Count: $ERRCOUNT"
	if (( ERRCOUNT > 10 )); then
		SLEEP_TIME=$(( POLL_INTERVAL*11 ))
	else
		SLEEP_TIME=$(( POLL_INTERVAL*(ERRCOUNT+1) ))
	fi

	sleep "${SLEEP_TIME}s" &
	wait $!
	get_network_subnet || continue

	get_whitelisted_container_ids || continue

	DATE=$(date "+%Y-%m-%d %H:%M:%S")

	if [[ "$SUBNET" != "$OLD_SUBNET" || "${WHITELIST[*]}" != "${OLD_WHITELIST[*]}" ]]; then
		if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
			get_netns || continue
			get_load_balancer_ip || continue
		fi
		add_chain || continue

		block_subnet_traffic  || continue

		if [[ -z "$ALLOW_HOST_TRAFFIC" ]]; then
			add_input_chain || continue

			block_host_traffic  || continue
		fi

		if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
			allow_load_balancer_traffic || continue
		fi

		allow_whitelist_traffic || continue

		remove_old_rules TRAEFIKJAM; remove_old_rules TRAEFIKJAM_INPUT || continue

		OLD_SUBNET="$SUBNET"

		OLD_WHITELIST=("${WHITELIST[@]}")
	fi

	ERRCOUNT=0
done

# ---------
# swarm (DRIVER == "overlay")
# ---------

#get_subnet

#container setup:
#ln -s /var/run/docker/netns /var/run/netns
#apk add --no-cache iproute2

#get network id (for namespace):
#NETWORK_ID=$(docker network inspect --format="{{.ID}}" "${NETWORK}")

#get netns:
#NETNS=$(ls /var/run/netns | grep -vE "^lb_" | grep "${NETWORK_ID:0:9}")

#block subnet traffic on ns
#ip netns exec "${NETNS}" iptables -t filter -A FORWARD -s "${SUBNET}" -d "${SUBNET}" -j DROP

#get whitelist container ids

#get whitelist service id
#SERVICE_ID=$(docker service ls --filter "${WHITELIST}" --format="{{.ID}}") <-- needs to be looped for multiple ids

#get containers matching service id
#docker ps --filter network="$NETWORK" --filter "label=com.docker.swarm.service.id=${SERVICE_ID}" --format="{{.ID}}"

#get service vip:
#docker service inspect --format="{{ range .Endpoint.VirtualIPs }}{{ .Addr }}{{ end }}" "${SERVICE_ID}"

#get load balancer ip:
#docker network inspect "${NETWORK_ID}" --format "{{ (index .Containers \"lb-${NETWORK}\").IPv4Address  }}"

#block subnet traffic on ns
#block_swarm_subnet_traffic
#ip netns exec 1-plg9ow19dq iptables -t filter -A FORWARD -s 10.0.1.0/24 -d 10.0.1.0/24 -j DROP

#allow subnet traffic from load balancer and from whitelisted containers/services


#figure out how to access the right namespace from within the container
#apk add --no-cache iproute2

#allows whitelisted service container
# Chain FORWARD (policy ACCEPT)                                                                                                       │/ #
# target     prot opt source               destination                                                                                │/ #
# ACCEPT     all  --  10.0.1.0/24          10.0.1.0/24             ctstate RELATED,ESTABLISHED                                           │/ #
# ACCEPT     all  --  10.0.1.13            10.0.1.0/24        #from whitelisted containers
# ACCEPT		 all  --  10.0.1.4             10.0.1.0/24        #from loadbalancer                                                                      │/ #
# DROP       all  --  10.0.1.0/24          10.0.1.0/24  