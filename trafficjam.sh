#!/usr/bin/env bash
set -Eeuo pipefail
# disable history expansion so we can easily use '!'
set +H

if [[ "${1:-}" != "--clear" && -z "${NETWORK:-}" ]]; then
	echo "NETWORK is not set" >&2
	exit 1
fi

#Initialize variables since we set -u
: "${INSTANCE_ID:=default}"
if [[ "$INSTANCE_ID" =~ [^a-zA-Z0-9_] ]]; then
	echo "INSTANCE_ID contains invalid characters" >&2
	exit 1
fi

: "${TZ:=}"
if [[ -n "$TZ" ]]; then
	cp /usr/share/zoneinfo/"$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

: "${MIN_POLL_INTERVAL:=4}"
SLEEP_TIME="$MIN_POLL_INTERVAL"
: "${MAX_POLL_INTERVAL:=128}"
: "${DEBUG:=}"

: "${SWARM_DAEMON:=}"
: "${SWARM_IMAGE:=kaysond/trafficjam}"

# Default allowlists
: "${ALLOWLIST_NETWORK_SOURCES:=label=trafficjam.$INSTANCE_ID.allow_network}"
: "${ALLOWLIST_NETWORK_DESTINATIONS:=SUBNET}"

: "${ALLOWLIST_LAN_SOURCES:=label=trafficjam.$INSTANCE_ID.allow_lan}"
: "${ALLOWLIST_LAN_DESTINATIONS:=$LAN_SUBNET}"

: "${ALLOWLIST_HOST_SOURCES:=label=trafficjam.$INSTANCE_ID.allow_host}"
: "${ALLOWLIST_HOST_DESTINATIONS:=0.0.0.0/0}"
: "${ALLOWLIST_HOST_CHAIN:=TRAFFICJAM_INPUT}"

: "${ALLOWLIST_WAN_SOURCES:=label=trafficjam.$INSTANCE_ID.allow_wan}"
: "${ALLOWLIST_WAN_DESTINATIONS:=192.168.0.0/16 172.16.0.0/12 10.0.0.0/8}"
: "${ALLOWLIST_WAN_INVERT:=}"

ALLOWLISTS=NETWORK LAN HOST WAN "${CUSTOM_ALLOWLISTS[@]:-}"

NETNS=""
LOCAL_LOAD_BALANCER_IP=""
OLD_LOCAL_LOAD_BALANCER_IP=""
SERVICE_LOGS_SINCE=""
: "${ALLOWED_SWARM_IPS:=}"
OLD_ALLOWED_SWARM_IPS=""

. trafficjam-functions.sh

trap tj_trap EXIT
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

		SLEEP_TIME="$MIN_POLL_INTERVAL"
	done
fi

while true; do
	tj_sleep

	get_network_driver || continue

	get_network_subnet || continue

	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		get_netns || continue
		if [[ -n "$NETNS" ]]; then
			get_local_load_balancer_ip || continue
		else
			continue
		fi
	fi

	DATE=$(date "+%Y-%m-%d %H:%M:%S")

	if ! rules_need_updating; then
		continue
	fi

	add_chains || continue

	block_network_traffic || continue
	allow_response_traffic || continue

	for ALLOWLIST in $ALLOWLISTS; do
		process_allowlist "$ALLOWLIST"
		declare -n SOURCE_IPS="ALLOWLIST_${ALLOWLIST}_SOURCE_IPS"
		declare -n OLD_SOURCE_IPS="ALLOWLIST_${ALLOWLIST}_OLD_SOURCE_IPS"
		OLD_SOURCE_IPS="$SOURCE_IPS"

		declare -n DESTINATION_IPS="ALLOWLIST_${ALLOWLIST}_SOURCE_IPS"
		declare -n OLD_DESTINATION_IPS="ALLOWLIST_${ALLOWLIST}_OLD_DESTINATION_IPS"
		OLD_DESTINATION_IPS="$DESTINATION_IPS"
	done

	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		report_local_allowlist_ips || continue
		allow_local_load_balancer_traffic || continue
		allow_swarm_traffic || continue
	fi

	remove_old_rules || continue

	OLD_SUBNET="$SUBNET"
	OLD_LOCAL_LOAD_BALANCER_IP="$LOCAL_LOAD_BALANCER_IP"

	SLEEP_TIME="$MIN_POLL_INTERVAL"
done
