function log () {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1"
}

function log_error () {
	echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >&2
}

function get_network_driver () {
	if ! DRIVER=$(docker network inspect --format="{{ .Driver }}" "$NETWORK" 2>&1) || [ -z "$DRIVER" ]; then
		log_error "Unexpected error while determining network driver: $DRIVER"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	fi
}

function get_network_subnet () {
	if ! SUBNET=$(docker network inspect --format="{{ range .IPAM.Config }}{{ .Subnet }}{{ end }}" "$NETWORK" 2>&1) || [ -z "$SUBNET" ]; then
		log_error "Unexpected error while determining network subnet: $SUBNET"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	fi
}

function get_container_whitelist () {
	WHITELIST=()
	local ID
	for FILTER in $WHITELIST_FILTERS; do
		if ! ID=$(docker ps --filter "$FILTER" --filter network="$NETWORK" --format="{{.ID}}" 2>&1) || [ -z  "$ID" ]; then
			log_error "Unexpected error while getting container whitelist: $IMAGES"
			ERRCOUNT=$((ERRCOUNT+1))
			return 1
		fi
		WHITELIST+=("$ID")
	done
	log "Container whitelist: ${WHITELIST[*]}"
}

function block_subnet_traffic () {
	local RESULT
	if ! RESULT=$(iptables -t filter -I DOCKER-USER -s "$SUBNET" -d "$SUBNET" -j DROP -m comment --comment "traefikjam $DATE" 2>&1); then
		log_error "Unexpected error while setting subnet blocking rule: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I DOCKER-USER -s $SUBNET -d $SUBNET -j DROP"
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
			if ! RESULT=$(iptables -t filter -I DOCKER-USER -s "$IP" -d "$SUBNET" -j ACCEPT -m comment --comment "traefikjam $DATE"); then
				log_error "Unexpected error while setting whitelist allow rule: $RESULT"
				ERRCOUNT=$((ERRCOUNT+1))
				return 1
			else
				log "Added rule: -t filter -I DOCKER-USER -s $IP -d $SUBNET -j ACCEPT"
			fi
			if ! RESULT=$(iptables -t filter -I DOCKER-USER -s "$SUBNET" -d "$IP" -j ACCEPT -m comment --comment "traefikjam $DATE"); then
				log_error "Unexpected error while setting whitelist allow rule: $RESULT"
				ERRCOUNT=$((ERRCOUNT+1))
				return 1
			else
				log "Added rule: -t filter -I DOCKER-USER -s $SUBNET -d $IP -j ACCEPT"
			fi
		fi
	done
}

function block_host_traffic () {
	local RESULT
	#Drop local socket-bound packets coming from the target subnet
	if ! RESULT=$(iptables -t filter -I INPUT -s "$SUBNET" -j DROP -m comment --comment "traefikjam $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I INPUT -s $SUBNET -j DROP"
	fi

	#But allow them if the connection was initiated by the host
	if ! RESULT=$(iptables -t filter -I INPUT -s "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "traefikjam $DATE" 2>&1); then
		log_error "Unexpected error while setting host blocking rules: $RESULT"
		ERRCOUNT=$((ERRCOUNT+1))
		return 1
	else
		log "Added rule: -t filter -I INPUT -s $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
	fi
}

function remove_old_rules () {
	local RULES
	local RULENUM
	local RESULT
	if ! RULES=$(iptables --line-numbers -t filter -L DOCKER-USER | grep "traefikjam" | grep -v "$DATE" 2>&1); then
		log_error "Could not get old DOCKER-USER rules for removal"
		return 1
	fi
	for RULE in $RULES; do
		RULENUM=$(echo "$RULE" | awk '{ print $1 }')
		if ! RESULT=$(iptables -t filter -D DOCKER-USER "$RULENUM"); then
			log_error "Could not remove DOCKER-USER rule: $RULE"
		else
			log "Removed DOCKER-USER rule: $RULE"
		fi
	done

	if ! RULES=$(iptables --line-numbers -t filter -L INPUT | grep "traefikjam" | grep -v "$DATE" 2>&1); then
		log_error "Could not get old INPUT rules for removal"
		return 1
	fi
	for RULE in $RULES; do
		RULENUM=$(echo "$RULE" | awk '{ print $1 }')
		if ! RESULT=$(iptables -t filter -D INPUT "$RULENUM"); then
			log_error "Could not remove INPUT rule: $RULE"
		else
			log "Removed INPUT rule: $RULE"
		fi
	done
}