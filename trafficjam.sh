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
SWARM_DAEMON="${SWARM_DAEMON:-}"
SWARM_IMAGE="${SWARM_IMAGE:-kaysond/trafficjam}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
ALLOW_HOST_TRAFFIC="${ALLOW_HOST_TRAFFIC:-}"
DEBUG="${DEBUG:-}"
TZ="${TZ:-}"
NETNS=""
OLD_SUBNET=""
OLD_WHITELIST=""
OLD_LOCAL_LOAD_BALANCER_IP=""
LOAD_BALANCER_IPS="${LOAD_BALANCER_IPS:-}"
OLD_LOAD_BALANCER_IPS=""

if [[ -n "$TZ" ]]; then
	cp /usr/share/zoneinfo/"$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

#CRC32 without packages
TJINSTANCE=$(echo -n "$NETWORK $WHITELIST_FILTER" | gzip -c | tail -c8 | hexdump -n4 -e '"%08X"')

. trafficjam-functions.sh

ERRCOUNT=0
if [[ -n "$SWARM_DAEMON" ]]; then
	remove_service

	while true; do
		tj_sleep

    	deploy_service || continue

		get_load_balancer_ips || continue

		if [[ "$LOAD_BALANCER_IPS" != "$OLD_LOAD_BALANCER_IPS" ]]; then
			update_service || continue

			OLD_LOAD_BALANCER_IPS="$LOAD_BALANCER_IPS"
		fi

		ERRCOUNT=0
	done
else
	while true; do
		tj_sleep

		get_network_driver || continue 

		get_network_subnet || continue

		get_whitelisted_container_ids || continue

		DATE=$(date "+%Y-%m-%d %H:%M:%S")

		if [[ "$SUBNET" != "$OLD_SUBNET" || "${WHITELIST[*]}" != "${OLD_WHITELIST[*]}" ]]; then
			if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
				get_netns || continue
				get_local_load_balancer_ip || continue
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

			remove_old_rules TRAFFICJAM; remove_old_rules TRAFFICJAM_INPUT || continue

			OLD_SUBNET="$SUBNET"

			OLD_WHITELIST=("${WHITELIST[@]}")
		fi

		ERRCOUNT=0
	done
fi
