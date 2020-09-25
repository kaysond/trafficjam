function log() {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"
}

function log_error() {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >&2
}

function log_debug() {
	if [[ -n "$DEBUG" ]]; then
		echo "[$(date "+%Y-%m-%d %H:%M:%S")] DEBUG: $1"
	fi
}

function get_network_driver() {
	if ! NETWORK_DRIVER=$(docker network inspect --format="{{ .Driver }}" "$NETWORK" 2>&1) || [ -z "$NETWORK_DRIVER" ]; then
		log_error "Unexpected error while determining network driver: $NETWORK_DRIVER"
		return 1
	else
		log_debug "Network driver of $NETWORK is $NETWORK_DRIVER"
	fi
}

function get_network_subnet() {
	if ! SUBNET=$(docker network inspect --format="{{ range .IPAM.Config }}{{ .Subnet }}{{ end }}" "$NETWORK" 2>&1) || [ -z "$SUBNET" ]; then
		log_error "Unexpected error while determining network subnet: $SUBNET"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log_debug "Subnet of $NETWORK is $SUBNET"
	fi
}

function get_whitelisted_container_ids() {
	if ! WHITELIST=$(docker ps --filter "$WHITELIST_FILTER" --filter network="$NETWORK" --format="{{.ID}}" 2>&1); then
		log_error "Unexpected error while getting container IDs for filter '$WHITELIST_FILTER': $WHITELIST"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	fi
	if [[ -z "$WHITELIST" ]]; then
		log_error "Retrieved empty ID for whitelisted containers"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	fi
	log_debug "Whitelisted containers: ${WHITELIST[*]}"
}

function get_netns() {
	if ! NETWORK_ID=$(docker network inspect --format="{{.ID}}" "$NETWORK") || [ -z "$NETWORK_ID" ]; then
		log_error "Could not retrieve ID for network $NETWORK"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log_debug "ID of network $NETWORK is $NETWORK_ID"
	fi
	if ! NETNS=$(ls /var/run/netns | grep -vE "^lb_" | grep "${NETWORK_ID:0:9}") || [ -z "$NETNS" ]; then
		log_error "Could not retrieve network namespace for network ID $NETWORK_ID"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log_debug "Network namespace of $NETWORK (ID: $NETWORK_ID) is $NETNS"
	fi
}

function iptables_tj() {
	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		ip netns exec "$NETNS" iptables "$@"
	else
		iptables "$@"
	fi
}

function add_chain() {
	local RESULT
	if ! iptables_tj -t filter -L TRAEFIKJAM >& /dev/null; then
		if ! RESULT=$(iptables_tj -N TRAEFIKJAM); then
			log_error "Unexpected error while adding chain TRAEFIKJAM: $RESULT"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			log "Added chain: TRAEFIKJAM"
		fi
	fi

	local CHAIN
	if [[ "$NETWORK_DRIVER" == "overlay" ]]; then
		CHAIN="FORWARD"
	else
		CHAIN="DOCKER-USER"
	fi

	if ! iptables_tj -t filter -L "$CHAIN" | grep "TRAEFIKJAM" >& /dev/null; then
		if ! RESULT=$(iptables_tj -t filter -I "$CHAIN" -j TRAEFIKJAM); then
			log_error "Unexpected error while adding jump rule: $RESULT"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			log "Added rule: -t filter -I $CHAIN -j TRAEFIKJAM"
		fi
	fi
}

function block_subnet_traffic() {
	local RESULT
	if ! RESULT=$(iptables_tj -t filter -I TRAEFIKJAM -s "$SUBNET" -d "$SUBNET" -j DROP -m comment --comment "traefikjam-$TJINSTANCE $DATE" 2>&1); then
		log_error "Unexpected error while setting subnet blocking rule: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I TRAEFIKJAM -s $SUBNET -d $SUBNET -j DROP"
	fi
}

function get_load_balancer_ip() {
	if ! LOAD_BALANCER_IP=$(docker network inspect "$NETWORK" --format "{{ (index .Containers \"lb-$NETWORK\").IPv4Address  }}") || [ -z "$LOADBALANCER_IP" ]; then
		log_error "Could not retrieve load balancer IP for network $NETWORK"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log_debug "Load balancer IP of $NETWORK is $LOAD_BALANCER_IP"
	fi
}

function allow_load_balancer_traffic() {
	if ! RESULT=$(iptables_tj -t filter -I TRAEFIKJAM -s "$LOAD_BALANCER_IP" -d "$SUBNET" -j RETURN -m comment --comment "traefikjam-$TJINSTANCE $DATE"); then
		log_error "Unexpected error while setting load balancer allow rule: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I TRAEFIKJAM -s $LOAD_BALANCER_IP -d $SUBNET -j RETURN"
	fi
}

function allow_whitelist_traffic() {
	local IP
	local RESULT
	for CONTID in "${WHITELIST[@]}"; do
		if ! IP=$(docker inspect --format="{{ (index .NetworkSettings.Networks \"$NETWORK\").IPAddress }}" "$CONTID" 2>&1) || [ -z "$IP" ]; then
			log_error "Unexpected error while determining container '$CONTID' IP address: $IP"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			if ! RESULT=$(iptables_tj -t filter -I TRAEFIKJAM -s "$IP" -d "$SUBNET" -j RETURN -m comment --comment "traefikjam-$TJINSTANCE $DATE"); then
				log_error "Unexpected error while setting whitelist allow rule: $RESULT"
				ERRCOUNT=$((ERRCOUNT+1))
				return 1
			else
				log "Added rule: -t filter -I TRAEFIKJAM -s $IP -d $SUBNET -j RETURN"
			fi
		fi
	done
	if ! RESULT=$(iptables_tj -t filter -I TRAEFIKJAM -s "$SUBNET" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN -m comment --comment "traefikjam-$TJINSTANCE $DATE"); then
		log_error "Unexpected error while setting whitelist allow rule: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I TRAEFIKJAM -s $SUBNET -d $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
	fi
}

function add_input_chain() {
	local RESULT
	if ! iptables_tj -t filter -L TRAEFIKJAM_INPUT >& /dev/null; then
		if ! RESULT=$(iptables_tj -N TRAEFIKJAM_INPUT); then
			log_error "Unexpected error while adding chain TRAEFIKJAM_INPUT: $RESULT"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			log "Added chain: TRAEFIKJAM_INPUT"
		fi
	fi
	if ! iptables_tj -t filter -L INPUT | grep "TRAEFIKJAM_INPUT" >& /dev/null; then
		if ! RESULT=$(iptables_tj -t filter -I INPUT -j TRAEFIKJAM_INPUT); then
			log_error "Unexpected error while adding jump rule: $RESULT"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			log "Added rule: -t filter -I INPUT -j TRAEFIKJAM_INPUT"
		fi
	fi
}

function block_host_traffic() {
	local RESULT
	#Drop local socket-bound packets coming from the target subnet
	if ! RESULT=$(iptables_tj -t filter -I TRAEFIKJAM_INPUT -s "$SUBNET" -j DROP -m comment --comment "traefikjam-$TJINSTANCE $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I TRAEFIKJAM_INPUT -s $SUBNET -j DROP"
	fi

	#But allow them if the connection was initiated by the host
	if ! RESULT=$(iptables_tj -t filter -I TRAEFIKJAM_INPUT -s "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "traefikjam-$TJINSTANCE $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I TRAEFIKJAM_INPUT -s $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
	fi
}

function remove_old_rules() {
	local RULENUMS
	local RESULT
	local RULES

	if ! RULES=$(iptables_tj --line-numbers -t filter -L "$1" 2>&1); then
		log_error "Could not get old $1 rules for removal: $RULES"
		return 1
	fi
	#Make sure to reverse sort rule numbers othwerise the numbers change!
	RULENUMS=$(echo "$RULES" | grep "traefikjam-$TJINSTANCE" | grep -v "$DATE" | awk '{ print $1 }' | sort -nr)
	for RULENUM in $RULENUMS; do
		RULE=$(iptables_tj -t filter -L "$1" "$RULENUM")
		if ! RESULT=$(iptables_tj -t filter -D "$1" "$RULENUM"); then
			log_error "Could not remove $1 rule: $RULE"
		else
			log "Removed $1 rule: $RULE"
		fi
	done
}
