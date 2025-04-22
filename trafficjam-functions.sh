#!/usr/bin/env bash
function tj_trap() {
	log_debug "Trapping signal"
	if [[ -n "$SWARM_DAEMON" ]]; then
		remove_service || {
			log_error                  "Could not remove swarm worker service"
			exit                                                                     1
		}
	fi
	exit 0
}

function tj_sleep() {
	if ((SLEEP_TIME > MAX_POLL_INTERVAL)); then
		SLEEP_TIME="$MIN_POLL_INTERVAL"
	fi
	log_debug "Current SLEEP_TIME: $SLEEP_TIME"

	# This pattern, along with the trap above, allows for quick script exits
	sleep "${SLEEP_TIME}s" &
	wait $!
}

function log() {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"
}

function log_error() {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: $1" >&2
	# Slow logging on errors
	SLEEP_TIME=$((SLEEP_TIME * 2))
}

function log_debug() {
	if [[ -n "$DEBUG" ]]; then
		echo "[$(date "+%Y-%m-%d %H:%M:%S")] DEBUG: $1"
	fi
}

function clear_rules() {
	if [[ -z "${NETWORK_DRIVER:-}" ]]; then
		get_network_driver || NETWORK_DRIVER=local
	fi

	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		get_netns
	fi

	DATE=$(date "+%Y-%m-%d %H:%M:%S")
	remove_old_rules TRAFFICJAM || true # this would normally fail if no rules exist but we don't want to exit
	remove_old_rules TRAFFICJAM_INPUT || true

	exit 0
}

function remove_service() {
	local ID
	if ID=$(docker service ls --quiet --filter "label=trafficjam.id=$INSTANCE_ID") && [[ -n "$ID" ]]; then
		local RESULT
		if ! RESULT=$(docker service rm "$ID" 2>&1); then
			log_error "Unexpected error while removing existing service: $RESULT"
		else
			log "Removed service $ID: $RESULT"
		fi
	else
		log_debug "No existing service found to remove"
	fi
}

function deploy_service() {
	if ! docker inspect "$(docker service ls --quiet --filter "label=trafficjam.id=$INSTANCE_ID")" &> /dev/null; then
		if ! SERVICE_ID=$(
			# rslave bind-propagation is needed so that any new mounts in the host docker/netns appear in the container
			docker service create \
				--quiet \
				--detach \
				--name "trafficjam_$INSTANCE_ID" \
				--mount type=bind,source=/var/run/docker.sock,destination=/var/run/docker.sock \
				--mount type=bind,source=/var/run/docker/netns,destination=/var/run/netns,bind-propagation=rslave \
				--env TZ="$TZ" \
				--env POLL_INTERVAL="$POLL_INTERVAL" \
				--env NETWORK="$NETWORK" \
				--env ALLOW_LIST_NETWORK="$ALLOW_LIST_NETWORK" \
				--env ALLOW_LIST_HOST="$ALLOW_LIST_HOST" \
				--env ALLOW_LIST_LAN="$ALLOW_LIST_LAN" \
				--env ALLOW_LIST_WAN="$ALLOW_LIST_WAN" \
				--env DEBUG="$DEBUG" \
				--cap-add NET_ADMIN \
				--cap-add SYS_ADMIN \
				--mode global \
				--restart-condition on-failure \
				--network host \
				--label trafficjam.id="$INSTANCE_ID" \
				"$SWARM_IMAGE" 2>&1
		); then
			log_error "Unexpected error while deploying service: $SERVICE_ID"
			return 1
		else
			# docker service create may print warnings to stderr even if it succeeds
			# particularly due to the trafficjam image not being accessible in a registry during CI
			SERVICE_ID=$(printf '%s' "$SERVICE_ID" | tail -n1)
			log "Created service trafficjam_$INSTANCE_ID: $SERVICE_ID"
		fi
	else
		log_debug "Existing service found, not deploying"
	fi
}

function get_allowed_swarm_ips() {
	local RESULT
	if ! RESULT=$(docker service inspect --format '{{ if .UpdateStatus }}{{ .UpdateStatus.State }}{{ end }}' "$SERVICE_ID" 2>&1); then
		log_error "Unexpected error while getting service update state: $RESULT"
		return 1
	elif [[ "$RESULT" != "updating" ]]; then
		# Filter out any service container that is not running
		local CONT_IDS
		if ! CONT_IDS=$(docker service ps --quiet --filter desired-state=running "$SERVICE_ID" | cut -c -12 2>&1); then
			log_error "Unexpected error while determining service container IDs: $CONT_IDS"
			return 1
		fi
		local SERVICE_LOGS
		if ! SERVICE_LOGS=$(docker service logs --timestamps --since "$SERVICE_LOGS_SINCE" "$SERVICE_ID" 2>&1); then
			log_error "Unexpected error while retrieving service logs: $SERVICE_LOGS"
			return 1
		fi
		# We have to only grab the latest log entries because of https://github.com/moby/moby/issues/38640
		SERVICE_LOGS_SINCE=$(tail -n1 <<< "$SERVICE_LOGS" | cut -d ' ' -f 1)

		#This mess searches the service logs for running containers' "#ALLOWLIST_IPS#" output
		#and saves the most recent output from each container into the variable
		if ! ALLOWED_SWARM_IPS=$({ printf '%s' "$SERVICE_LOGS" |
			grep -E "$(printf '(%s)' "$CONT_IDS" | tr '\n' '|')" |
			grep -E "#ALLOWLIST_IPS#" |
			# reverse the lines
			tac |
			# only get the first (newest) log entry per container
			awk '!a[$1]++ { print }' |
			# delete everything up to and including the tag
			sed 's/^.*#ALLOWLIST#//' |
			# one IP per line
			tr ' ' '\n' |
			sort -t . -d |
			uniq |
			# back to one line for nicer debug log output
			tr '\n' ' '; } 2>&1); then
			log_debug "No swarm allowlist ips found"
			ALLOWED_SWARM_IPS="$OLD_ALLOWED_SWARM_IPS"
		else
			log_debug "Allowed Swarm IPs: $ALLOWED_SWARM_IPS"
		fi
	else
		log_debug "Skipping swarm ip check because service is still updating"
	fi
}

function update_service() {
	local RESULT
	if ! RESULT=$(docker service update --detach --env-add "ALLOWED_SWARM_IPS=$ALLOWED_SWARM_IPS" "$SERVICE_ID" 2>&1); then
		log_error "Unexpected error while updating service: $RESULT"
	else
		log "Updated service $SERVICE_ID"
	fi
}

function get_network_driver() {
	if ! NETWORK_DRIVER=$(docker network inspect --format="{{ .Driver }}" "$NETWORK" 2>&1) || [[ -z "$NETWORK_DRIVER" ]]; then
		if grep --quiet "network $NETWORK not found" <<< "$NETWORK_DRIVER"; then
			# this isn't strictly an error since the network doesn't have to be up
			# when the container starts (common for swarm overlay networks if a node
			# doesn't have a container on that network) but we still want to slow logging/polling
			log "Network '$NETWORK' was not found."
			SLEEP_TIME=$((SLEEP_TIME * 2))
		else
			log_error "Unexpected error while determining network driver: $NETWORK_DRIVER"
		fi
		return 1
	else
		log_debug "Network driver of $NETWORK is $NETWORK_DRIVER"
	fi
}

function get_network_subnet() {
	if ! SUBNET=$(docker network inspect --format="{{ (index .IPAM.Config 0).Subnet }}" "$NETWORK" 2>&1) || [[ -z "$SUBNET" ]]; then
		log_error "Unexpected error while determining network subnet: $SUBNET"
		return 1
	else
		log_debug "Subnet of $NETWORK is $SUBNET"
	fi
}

function get_netns() {
	if ! NETWORK_ID=$(docker network inspect --format="{{.ID}}" "$NETWORK") || [ -z "$NETWORK_ID" ]; then
		log_error "Could not retrieve ID for network $NETWORK"
		return 1
	else
		log_debug "ID of network $NETWORK is $NETWORK_ID"
	fi

	for f in /var/run/netns/*; do
		case $(basename "$f") in
			lb_*) true ;;
			*"${NETWORK_ID:0:9}"*) NETNS="$f" ;;
		esac
	done
	if [[ -z "$NETNS" ]]; then
		# Similar to the above, the network could be created, but if there are
		# no containers on it, docker won't create the namespace or load balancer
		log "No network namespace for $NETWORK (ID: $NETWORK_ID) on this node"
		SLEEP_TIME=$((SLEEP_TIME * 2))
		return 1
	else
		log_debug "Network namespace of $NETWORK (ID: $NETWORK_ID) is $NETNS"
	fi
}

function get_local_load_balancer_ip() {
	# TODO: failing on empty IPs assumes that if the network namespace exists, the load balancer does.
	#       we should verify that
	if ! LOCAL_LOAD_BALANCER_IP=$(docker network inspect "$NETWORK" --format "{{ (index .Containers \"lb-$NETWORK\").IPv4Address }}" | awk -F/ '{ print $1 }') || [[ -z "$LOCAL_LOAD_BALANCER_IP" ]] }; then
		log_error "Could not retrieve load balancer IP for network $NETWORK"
		return 1
	fi

	log_debug "Load balancer IP of $NETWORK is $LOCAL_LOAD_BALANCER_IP"
}

function iptables_tj() {
	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		nsenter --net="$NETNS" -- iptables-nft "$@"
	else
		iptables-nft "$@"
	fi
}

function add_chains() {
	# TRAFFICJAM chain
	local RESULT
	if ! iptables_tj --table filter --numeric --list TRAFFICJAM >&/dev/null; then
		if ! RESULT=$(iptables_tj --new TRAFFICJAM 2>&1); then
			log_error "Unexpected error while adding chain TRAFFICJAM: $RESULT"
			return 1
		else
			log "Added chain: TRAFFICJAM"
		fi
	fi

	# jump to TRAFFICJAM chain
	local CHAIN
	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		CHAIN="FORWARD"
	else
		CHAIN="DOCKER-USER"
	fi

	if ! iptables_tj --table filter --numeric --list "$CHAIN" | grep "TRAFFICJAM" >&/dev/null; then
		if ! RESULT=$(iptables_tj --table filter --insert "$CHAIN" --jump TRAFFICJAM 2>&1); then
			log_error "Unexpected error while adding jump rule: $RESULT"
			return 1
		else
			log "Added rule: --table filter --insert $CHAIN --jump TRAFFICJAM"
		fi
	fi

	# TRAFFICJAM_INPUT chain
	if ! iptables_tj --table filter --numeric --list TRAFFICJAM_INPUT >&/dev/null; then
		if ! RESULT=$(iptables_tj --new TRAFFICJAM_INPUT); then
			log_error "Unexpected error while adding chain TRAFFICJAM_INPUT: $RESULT"
			return 1
		else
			log "Added chain: TRAFFICJAM_INPUT"
		fi
	fi

	# jump to TRAFFICJAM_INPUT chain
	if ! iptables_tj --table filter --numeric --list INPUT | grep "TRAFFICJAM_INPUT" >&/dev/null; then
		if ! RESULT=$(iptables_tj --table filter --insert INPUT --jump TRAFFICJAM_INPUT); then
			log_error "Unexpected error while adding jump rule: $RESULT"
			return 1
		else
			log "Added rule: --table filter --insert INPUT --jump TRAFFICJAM_INPUT"
		fi
	fi
}

function apply_rule() {
	local RESULT
	if ! RESULT=$(iptables_tj "$@" --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
		log_error "Unexpected error while setting rule ($*): $RESULT"
		return 1
	else
		log "Added rule: $*"
	fi
}

function block_network_traffic() {
	apply_rule --table filter --insert TRAFFICJAM --source "$SUBNET" --jump DROP || return 1
	apply_rule --table filter --insert TRAFFICJAM_INPUT --source "$SUBNET" --jump DROP || return 1
}

function allow_response_traffic() {
	apply_rule --table filter --insert TRAFFICJAM --source "$SUBNET" --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN || return 1
	apply_rule --table filter --insert TRAFFICJAM_INPUT --source "$SUBNET" --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN || return 1
}

function get_container_ips_from_filter() {
	local -n IPS="$1"
	local FILTER="$2"
	local CONTAINER_IDS
	if ! CONTAINER_IDS=$(docker ps --filter "$FILTER" --filter network="$NETWORK" --format="{{ .ID }}" 2>&1); then
		log_error "Unexpected error while getting container IDs from filter: $CONTAINER_IDS"
		return 1
	fi

	if [[ -z "$CONTAINER_IDS" ]]; then
		IPS=""
		log_debug "No containers matched the fillter"
		return 0
	fi

	log_debug "Filtered container IDs: $CONTAINER_IDS"

	if ! IPS=$(xargs docker inspect --format="{{ (index .NetworkSettings.Networks \"$NETWORK\").IPAddress }}" <<< "$CONTAINER_IDS" 2>&1) || [[ -z "$ALLOWED_IPS" ]]; then
		log_error "Unexpected error while getting container IPs: ${IPS}"
		return 1
	fi

	log_debug "Filtered container IPs: $IPS"
}

function get_allowlist_ips() {
	NAME="$1"
	SOURCE_OR_DESTINATION="$2"
	local -n IPS="$3"
	local -n DEFINITION="ALLOWLIST_${NAME}_${SOURCE_OR_DESTINATION}"
	shift 3
	if [[ "$DEFINITION" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})? ?)+$ ]]; then
		IPS="$DEFINITION"
		return
	elif [[ "$DEFINITION" == "SUBNET" ]]; then
		IPS="$SUBNET"
	else
		get_container_ips_from_filter IPS "$DEFINITION"
	fi
}

function rules_need_updating() {
	if [[ "$SUBNET" != "$OLD_SUBNET" ]]; then
		return 0
	fi

	# shellcheck disable=SC2153
	for ALLOWLIST in $ALLOWLISTS; do
		log_debug "Checking allowlist '$ALLOWLIST' for updates"

		local SOURCE_IPS
		get_allowlist_ips "$ALLOWLIST" SOURCE SOURCE_IPS
		local -n OLD_SOURCE_IPS="ALLOWLIST_${ALLOWLIST}_OLD_SOURCE_IPS"
		if [[ "$SOURCE_IPS" != "$OLD_SOURCE_IPS" ]]; then
			return 0
		fi

		local DESTINATION_IPS
		get_allowlist_ips "$ALLOWLIST" DESTINATION DESTINATION_IPS
		local -n OLD_DESTINATION_IPS="ALLOWLIST_${ALLOWLIST}_OLD_DESTINATION_IPS"
		if [[ "$DESTINATION_IPS" != "$OLD_DESTINATION_IPS" ]]; then
			return 0
		fi
	done

	return 1
}

function process() {
	local ALLOWLIST="$1"
	log_debug "Processing allowlist '$ALLOWLIST'"

	local -n SOURCE_IPS="ALLOWLIST_{$ALLOWLIST}_SOURCE_IPS"
	get_allowlist_ips "$ALLOWLIST" SOURCE SOURCE_IPS

	local -n DESTINATION_IPS="ALLOWLIST_{$ALLOWLIST}_DESTINATION_IPS"
	get_allowlist_ips "$ALLOWLIST" DESTINATION DESTINATION_IPS

	local -n CHAIN="ALLOWLIST_{$ALLOWLIST}_CHAIN"
	local -n INVERT="ALLOWLIST_{$ALLOWLIST}_INVERT"

	for SOURCE_IP in $SOURCE_IPS; do
		for DESTINATION_IP in $DESTINATION_IPS; do
			apply_rule --table filter --insert "${CHAIN:-TRAFFICJAM}" --source "$SOURCE_IP" "${INVERT:+!}" --destination "$DESTINATION_IP" --jump RETURN || return 1
		done
	done
}

function report_local_allowlist_ips() {
	log "#ALLOWLIST_IPS#$LOCAL_ALLOWED_IPS $LOCAL_LOAD_BALANCER_IP"
}

function allow_local_load_balancer_traffic() {
	apply_rule --table filter --insert TRAFFICJAM --source "$LOCAL_LOAD_BALANCER_IP" --destination "$SUBNET" --jump RETURN || return 1
}

function allow_swarm_traffic() {
	if [[ -n "$ALLOWED_SWARM_IPS" ]]; then
		for IP in $ALLOWED_SWARM_IPS; do
			if ! grep -q "$IP" <<< "$LOCAL_ALLOWED_IPS" && ! grep -q "$IP" <<< "$LOCAL_LOAD_BALANCER_IP"; then
				apply_rule --table filter --insert TRAFFICJAM --source "$IP" --destination "$SUBNET" --jump RETURN
			else
				log_debug "$IP is local; skipping in swarm rules"
			fi
		done
	fi
}

function remove_old_rules_from_chain() {
	local CHAIN="$1"
	local RULENUMS
	local RESULT
	local RULES

	if ! RULES=$(iptables_tj --line-numbers --table filter --numeric --list "$CHAIN" 2>&1); then
		log_error "Could not get rules from chain '$CHAIN' for removal: $RULES"
		return 1
	fi
	# Make sure to reverse sort rule numbers othwerise the numbers change!
	if ! RULENUMS=$(echo "$RULES" | grep "trafficjam_$INSTANCE_ID" | grep -v "$DATE" | awk '{ print $1 }' | sort -nr); then
		log "No old rules to remove from chain '$CHAIN'"
	else
		for RULENUM in $RULENUMS; do
			RULE=$(iptables_tj --table filter --numeric --list "$CHAIN" "$RULENUM" 2> /dev/null) # Suppress warnings since its just logging
			if ! RESULT=$(iptables_tj --table filter --delete "$CHAIN" "$RULENUM" 2>&1); then
				log_error "Could not remove $CHAIN rule \"$RULE\": $RESULT"
			else
				log "Removed $CHAIN rule: $RULE"
			fi
		done
	fi
}

function remove_old_rules() {
	remove_old_rules_from_chain TRAFFICJAM
	remove_old_rules_from_chain TRAFFICJAM_INPUT
}
