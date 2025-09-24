#!/usr/bin/env bash
function tj_trap() {
	log_debug "Trapping signal"
	if [[ -n "$SWARM_DAEMON" ]]; then
		remove_service || exit 1
	fi
	exit 0
}

function tj_sleep() {
	#Slow logging on errors
	log_debug "Error Count: $ERRCOUNT"
	if ((ERRCOUNT > 10)); then
		SLEEP_TIME=$((POLL_INTERVAL * 11))
	else
		SLEEP_TIME=$((POLL_INTERVAL * (ERRCOUNT + 1)))
	fi

	# This pattern, along with the trap above, allows for quick script exits
	sleep "${SLEEP_TIME}s" &
	wait $!
}

function log() {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"
}

function log_error() {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] ERROR: $1" >&2
	ERRCOUNT=$((ERRCOUNT + 1))
}

function log_debug() {
	if [[ -n "$DEBUG" ]]; then
		echo "[$(date "+%Y-%m-%d %H:%M:%S")] DEBUG: $1"
	fi
}

function detect_iptables_version() {
	IPTABLES_CMD=iptables-nft
	if ! iptables-nft --numeric --list DOCKER-USER &> /dev/null; then
		IPTABLES_CMD=iptables-legacy
		log "DEPRECATION NOTICE: support for legacy iptables is deprecated and will be removed in a future relase"
	fi
}

function detect_br_netfilter() {
	if lsmod | grep -q br_netfilter; then
		log_debug "br_netfilter already loaded"
		return 0
	fi

	log_error "br_netfilter is required by trafficjam and could not be detected. (See https://github.com/kaysond/trafficjam/#dependencies)"

}

function clear_rules() {
	if [[ -z "${NETWORK_DRIVER:-}" ]]; then
		get_network_driver || NETWORK_DRIVER=local
	fi

	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		get_netns
	fi

	DATE=$(date "+%Y-%m-%d %H:%M:%S")
	remove_old_rules TRAFFICJAM || true #this would normally fail if no rules exist but we don't want to exit
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
				--env WHITELIST_FILTER="$WHITELIST_FILTER" \
				--env DEBUG="$DEBUG" \
				--env SWARM_WORKER=true \
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
			#docker service create may print warnings to stderr even if it succeeds
			#particularly due to the trafficjam image not being accessible in a registry during CI
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
		#Filter out any service container that is not running
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

		#This mess searches the service logs for running containers' "#WHITELIST_IPS#" output
		#and saves the most recent output from each container into the variable
		if ! ALLOWED_SWARM_IPS=$({ printf '%s' "$SERVICE_LOGS" |
			grep -E "$(printf '(%s)' "$CONT_IDS" | tr '\n' '|')" |
			grep -E "#WHITELIST_IPS#" |
			# reverse the lines
			tac |
			# only get the first (newest) log entry per container
			awk '!a[$1]++ { print }' |
			# delete everything up to and including the tag
			sed 's/^.*#WHITELIST_IPS#//' |
			# one IP per line
			tr ' ' '\n' |
			sort -t . -d |
			uniq |
			# back to one line for nicer debug log output
			tr '\n' ' '; } 2>&1); then
			log_debug "No swarm whitelist ips found"
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
		if [[ -n "$SWARM_WORKER" ]]; then
			log_debug "Network was not found, but this is a swarm node"
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

function get_whitelisted_container_ips() {
	local CONTAINER_IDS
	if ! CONTAINER_IDS=$(docker ps --filter "$WHITELIST_FILTER" --filter network="$NETWORK" --format="{{ .ID }}" 2>&1); then
		log_error "Unexpected error while getting whitelist container IDs: $CONTAINER_IDS"
		return 1
	fi

	if [[ -z "$CONTAINER_IDS" ]]; then
		WHITELIST_IPS=""
		log_debug "No containers matched the whitelist"
		return 0
	fi

	log_debug "Whitelisted containers: $CONTAINER_IDS"

	if ! WHITELIST_IPS=$(xargs docker inspect --format="{{ (index .NetworkSettings.Networks \"$NETWORK\").IPAddress }}" <<< "$CONTAINER_IDS" 2>&1) || [[ -z "$WHITELIST_IPS" ]]; then
		log_error "Unexpected error while getting whitelisted container IPs: ${WHITELIST_IPS}"
		return 1
	fi

	log_debug "Whitelisted container IPs: $WHITELIST_IPS"

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
		if [[ -n "$SWARM_WORKER" ]]; then
			log_debug "No container on network $NETWORK on this node, skipping"
		else
			log_error "Could not retrieve network namespace for network ID $NETWORK_ID"
			return 1
		fi
	else
		log_debug "Network namespace of $NETWORK (ID: $NETWORK_ID) is $NETNS"
	fi
}

function get_local_load_balancer_ip() {
	if ! LOCAL_LOAD_BALANCER_IP=$(docker network inspect "$NETWORK" --format "{{ (index .Containers \"lb-$NETWORK\").IPv4Address  }}" | awk -F/ '{ print $1 }') || { [ -z "$LOCAL_LOAD_BALANCER_IP" ] && [[ -z "$SWARM_WORKER" ]]; }; then
		log_error "Could not retrieve load balancer IP for network $NETWORK"
		return 1
	fi

	if [[ -z "$LOCAL_LOAD_BALANCER_IP" ]] && [[ -n "$SWARM_WORKER" ]]; then
		log_debug "No load balancer found on this node"
	else
		log_debug "Load balancer IP of $NETWORK is $LOCAL_LOAD_BALANCER_IP"
	fi
}

function iptables_tj() {
	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		nsenter --net="$NETNS" -- "$IPTABLES_CMD" "$@"
	else
		$IPTABLES_CMD "$@"
	fi
}

function add_chain() {
	local RESULT
	if ! iptables_tj --table filter --numeric --list TRAFFICJAM >&/dev/null; then
		if ! RESULT=$(iptables_tj --new TRAFFICJAM 2>&1); then
			if [[ -z "$SWARM_WORKER" ]]; then
				log_error "Unexpected error while adding chain TRAFFICJAM: $RESULT"
				return 1
			else
				# Ugly workaround for nsenter: setns(): can't reassociate to namespace: Invalid argument
				log_error "Unexpected error while adding chain TRAFFICJAM: $RESULT."
				log_error "killing container to get access to the new network namespace (ugly workaround)"
				kill 1
			fi
		else
			log "Added chain: TRAFFICJAM"
		fi
	fi

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
}

function block_subnet_traffic() {
	local RESULT
	if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM --source "$SUBNET" --destination "$SUBNET" --jump DROP --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
		log_error "Unexpected error while setting subnet blocking rule: $RESULT"
		return 1
	else
		log "Added rule: --table filter --insert TRAFFICJAM --source $SUBNET --destination $SUBNET --jump DROP"
	fi
}

function add_input_chain() {
	local RESULT
	if ! iptables_tj --table filter --numeric --list TRAFFICJAM_INPUT >&/dev/null; then
		if ! RESULT=$(iptables_tj --new TRAFFICJAM_INPUT); then
			log_error "Unexpected error while adding chain TRAFFICJAM_INPUT: $RESULT"
			return 1
		else
			log "Added chain: TRAFFICJAM_INPUT"
		fi
	fi
	if ! iptables_tj --table filter --numeric --list INPUT | grep "TRAFFICJAM_INPUT" >&/dev/null; then
		if ! RESULT=$(iptables_tj --table filter --insert INPUT --jump TRAFFICJAM_INPUT); then
			log_error "Unexpected error while adding jump rule: $RESULT"
			return 1
		else
			log "Added rule: --table filter --insert INPUT --jump TRAFFICJAM_INPUT"
		fi
	fi
}

function block_host_traffic() {
	local RESULT
	#Drop local socket-bound packets coming from the target subnet
	if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM_INPUT --source "$SUBNET" --jump DROP --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		return 1
	else
		log "Added rule: --table filter --insert TRAFFICJAM_INPUT --source $SUBNET --jump DROP"
	fi

	#But allow them if the connection was initiated by the host
	if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM_INPUT --source "$SUBNET" --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		return 1
	else
		log "Added rule: --table filter --insert TRAFFICJAM_INPUT --source $SUBNET --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN"
	fi
}

function report_local_whitelist_ips() {
	log "#WHITELIST_IPS#$WHITELIST_IPS $LOCAL_LOAD_BALANCER_IP"
}

function allow_local_load_balancer_traffic() {
	if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM --source "$LOCAL_LOAD_BALANCER_IP" --destination "$SUBNET" --jump RETURN --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
		log_error "Unexpected error while setting load balancer allow rule: $RESULT"
		return 1
	else
		log "Added rule: --table filter --insert TRAFFICJAM --source $LOCAL_LOAD_BALANCER_IP --destination $SUBNET --jump RETURN"
	fi
}

function allow_swarm_whitelist_traffic() {
	if [[ -n "$ALLOWED_SWARM_IPS" ]]; then
		for IP in $ALLOWED_SWARM_IPS; do
			if ! grep -q "$IP" <<< "$WHITELIST_IPS" && ! grep -q "$IP" <<< "$LOCAL_LOAD_BALANCER_IP"; then
				if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM --source "$IP" --destination "$SUBNET" --jump RETURN --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
					log_error "Unexpected error while setting allow swarm whitelist rule: $RESULT"
					return 1
				else
					log "Added rule: --table filter --insert TRAFFICJAM --source $IP --destination $SUBNET --jump RETURN"
				fi
			else
				log_debug "$IP is local; skipping in swarm whitelist rules"
			fi
		done
	fi
}

function allow_local_whitelist_traffic() {
	local IP
	local RESULT
	for IP in $WHITELIST_IPS; do
		if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM --source "$IP" --destination "$SUBNET" --jump RETURN --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
			log_error "Unexpected error while setting whitelist allow rule: $RESULT"
			return 1
		else
			log "Added rule: --table filter --insert TRAFFICJAM --source $IP --destination $SUBNET --jump RETURN"
		fi
	done
	if ! RESULT=$(iptables_tj --table filter --insert TRAFFICJAM --source "$SUBNET" --destination "$SUBNET" --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN --match comment --comment "trafficjam_$INSTANCE_ID $DATE" 2>&1); then
		log_error "Unexpected error while setting whitelist allow rule: $RESULT"
		return 1
	else
		log "Added rule: --table filter --insert TRAFFICJAM --source $SUBNET --destination $SUBNET --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN"
	fi
}

function remove_old_rules() {
	local RULENUMS
	local RESULT
	local RULES

	if ! RULES=$(iptables_tj --line-numbers --table filter --numeric --list "$1" 2>&1); then
		log_error "Could not get rules from chain '$1' for removal: $RULES"
		return 1
	fi
	#Make sure to reverse sort rule numbers othwerise the numbers change!
	if ! RULENUMS=$(echo "$RULES" | grep "trafficjam_$INSTANCE_ID" | grep -v "$DATE" | awk '{ print $1 }' | sort -nr); then
		log "No old rules to remove from chain '$1'"
	else
		for RULENUM in $RULENUMS; do
			RULE=$(iptables_tj --table filter --numeric --list "$1" "$RULENUM" 2> /dev/null) # Suppress warnings since its just logging
			if ! RESULT=$(iptables_tj --table filter --delete "$1" "$RULENUM" 2>&1); then
				log_error "Could not remove $1 rule \"$RULE\": $RESULT"
			else
				log "Removed $1 rule: $RULE"
			fi
		done
	fi
}
