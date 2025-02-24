#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" != "--clear" ]]; then
	if [[ -z "${NETWORK:-}" ]]; then
		echo "NETWORK is not set" >&2
		exit 1
	fi

	if [[ -z "${WHITELIST_FILTER:-}" ]]; then
		echo "WHITELIST_FILTER is not set" >&2
		exit 1
	fi
fi

#Initialize variables since we set -u
: "${INSTANCE_ID:=DEFAULT}"
: "${SWARM_DAEMON:=}"
: "${SWARM_IMAGE:=kaysond/trafficjam}"
: "${POLL_INTERVAL:=5}"
: "${ALLOW_HOST_TRAFFIC:=}"
: "${DEBUG:=}"
: "${TZ:=}"
NETNS=""
OLD_SUBNET=""
OLD_WHITELIST_IPS=""
LOCAL_LOAD_BALANCER_IP=""
OLD_LOCAL_LOAD_BALANCER_IP=""
SERVICE_LOGS_SINCE=""
: "${ALLOWED_SWARM_IPS:=}"
OLD_ALLOWED_SWARM_IPS=""

if [[ -n "$TZ" ]]; then
	cp /usr/share/zoneinfo/"$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

if [[ "$INSTANCE_ID" =~ [^a-zA-Z0-9_] ]]; then
	echo "INSTANCE_ID contains invalid characters" >&2
	exit 1
fi

. trafficjam-functions.sh

trap tj_trap EXIT

ERRCOUNT=0

detect_iptables_version

trap clear_rules SIGUSR1

if [[ "${1:-}" == "--clear" ]]; then
	clear_rules
fi

if [[ -n "$SWARM_DAEMON" ]]; then
	remove_service

	while true; do
		tj_sleep

		deploy_service || continue

		get_allowed_swarm_ips || continue

		if [[ "$ALLOWED_SWARM_IPS" != "$OLD_ALLOWED_SWARM_IPS" ]]; then
			update_service || continue

			OLD_ALLOWED_SWARM_IPS="$ALLOWED_SWARM_IPS"
		fi

		ERRCOUNT=0
	done
else
	while true; do
		tj_sleep

		get_network_driver || continue

		get_network_subnet || continue

		get_whitelisted_container_ips || continue

		if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
			get_netns || continue
			get_local_load_balancer_ip || continue
		fi

		DATE=$(date "+%Y-%m-%d %H:%M:%S")

		if [[ 
			"$SUBNET" != "$OLD_SUBNET" ||
			"$WHITELIST_IPS" != "$OLD_WHITELIST_IPS" ||
			"$LOCAL_LOAD_BALANCER_IP" != "$OLD_LOCAL_LOAD_BALANCER_IP" ]] \
			; then

			add_chain || continue

			block_subnet_traffic || continue

			if [[ -z "$ALLOW_HOST_TRAFFIC" ]]; then
				add_input_chain || continue
				block_host_traffic || continue
			fi

			if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
				report_local_whitelist_ips || continue
				allow_local_load_balancer_traffic || continue
				allow_swarm_whitelist_traffic || continue
			fi

			allow_local_whitelist_traffic || continue

			remove_old_rules TRAFFICJAM || continue

			if [[ -z "$ALLOW_HOST_TRAFFIC" ]]; then
				remove_old_rules TRAFFICJAM_INPUT || continue
			fi

			OLD_SUBNET="$SUBNET"
			OLD_WHITELIST_IPS="$WHITELIST_IPS"
			OLD_LOCAL_LOAD_BALANCER_IP="$LOCAL_LOAD_BALANCER_IP"
		fi

		ERRCOUNT=0
	done
fi
