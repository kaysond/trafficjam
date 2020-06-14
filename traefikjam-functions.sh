function log () {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"
}

function log_error () {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >&2
}

function log_debug () {
	if [[ -n "$DEBUG" ]]; then
		echo "[$(date "+%Y-%m-%d %H:%M:%S")] DEBUG: $1"
	fi
}

function get_network_driver () {
	if ! DRIVER=$(docker network inspect --format="{{ .Driver }}" "$NETWORK" 2>&1) || [ -z "$DRIVER" ]; then
		log_error "Unexpected error while determining network driver: $DRIVER"
		return 1
	else
		log_debug "Network driver of $NETWORK is $DRIVER"
	fi
}

function get_network_subnet () {
	if ! SUBNET=$(docker network inspect --format="{{ range .IPAM.Config }}{{ .Subnet }}{{ end }}" "$NETWORK" 2>&1) || [ -z "$SUBNET" ]; then
		log_error "Unexpected error while determining network subnet: $SUBNET"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log_debug "Subnet of $NETWORK is $SUBNET"
	fi
}

function get_container_whitelist () {
	WHITELIST=()
	local ID
	for FILTER in $WHITELIST_FILTERS; do
		if ! ID=$(docker ps --filter "$FILTER" --filter network="$NETWORK" --format="{{.ID}}" 2>&1); then
			log_error "Unexpected error while getting container whitelist for filter '$FILTER': $ID"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		fi
		if [[ -z "$ID" ]]; then
			log_error "Retrieved empty ID for whitelisted containers"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		fi
		WHITELIST+=($ID)
	done
	log_debug "Whitelisted containers: ${WHITELIST[*]}"
}

function add_chain () {
	local RESULT
	if ! iptables -t filter -L TRAEFIKJAM >& /dev/null; then
		if ! RESULT=$(iptables -N TRAEFIKJAM); then
			log_error "Unexpected error while adding chain TRAEFIKJAM: $RESULT"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			log "Added chain: TRAEFIKJAM"
		fi
	fi
	if ! iptables -t filter -L DOCKER-USER | grep "TRAEFIKJAM" >& /dev/null; then
		if ! RESULT=$(iptables -t filter -I DOCKER-USER -j TRAEFIKJAM); then
			log_error "Unexpected error while adding jump rule: $RESULT"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			log "Added rule: -t filter -I DOCKER-USER -j TRAEFIKJAM"
		fi
	fi
}

function block_subnet_traffic () {
	local RESULT
	if ! RESULT=$(iptables -t filter -I TRAEFIKJAM -s "$SUBNET" -d "$SUBNET" -j DROP -m comment --comment "traefikjam-$TJINSTANCE $DATE" 2>&1); then
		log_error "Unexpected error while setting subnet blocking rule: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I TRAEFIKJAM -s $SUBNET -d $SUBNET -j DROP"
	fi
}

function allow_whitelist_traffic () {
	local IP
	local RESULT
	for CONTID in "${WHITELIST[@]}"; do
		if ! IP=$(docker inspect --format="{{ (index .NetworkSettings.Networks \"$NETWORK\").IPAddress }}" "$CONTID" 2>&1) || [ -z "$IP" ]; then
			log_error "Unexpected error while determining container '$CONTID' IP address: $IP"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		else
			if ! RESULT=$(iptables -t filter -I TRAEFIKJAM -s "$IP" -d "$SUBNET" -j RETURN -m comment --comment "traefikjam-$TJINSTANCE $DATE"); then
				log_error "Unexpected error while setting whitelist allow rule: $RESULT"
				ERRCOUNT=$((ERRCOUNT+1))
				return 1
			else
				log "Added rule: -t filter -I TRAEFIKJAM -s $IP -d $SUBNET -j RETURN"
			fi
			if ! RESULT=$(iptables -t filter -I TRAEFIKJAM -s "$SUBNET" -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN -m comment --comment "traefikjam-$TJINSTANCE $DATE"); then
				log_error "Unexpected error while setting whitelist allow rule: $RESULT"
				ERRCOUNT=$((ERRCOUNT+1))
				return 1
			else
				log "Added rule: -t filter -I TRAEFIKJAM -s $SUBNET -d $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
			fi
		fi
	done
}

function block_host_traffic () {
	local RESULT
	#Drop local socket-bound packets coming from the target subnet
	if ! RESULT=$(iptables -t filter -I INPUT -s "$SUBNET" -j DROP -m comment --comment "traefikjam-$TJINSTANCE $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I INPUT -s $SUBNET -j DROP"
	fi

	#But allow them if the connection was initiated by the host
	if ! RESULT=$(iptables -t filter -I INPUT -s "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "traefikjam-$TJINSTANCE $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I INPUT -s $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
	fi
}

function remove_old_rules () {
	local RULENUMS
	local RESULT
	local RULES

	if ! RULES=$(iptables --line-numbers -t filter -L "$1" 2>&1); then
		log_error "Could not get old $1 rules for removal: $RULES"
		return 1
	fi
	#Make sure to reverse sort rule numbers othwerise the numbers change!
	RULENUMS=$(echo "$RULES" | grep "traefikjam-$TJINSTANCE" | grep -v "$DATE" | awk '{ print $1 }' | sort -nr)
	for RULENUM in $RULENUMS; do
		RULE=$(iptables -t filter -L "$1" "$RULENUM")
		if ! RESULT=$(iptables -t filter -D "$1" "$RULENUM"); then
			log_error "Could not remove $1 rule: $RULE"
		else
			log "Removed $1 rule: $RULE"
		fi
	done
}
