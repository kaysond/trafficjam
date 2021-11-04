setup_file() {
	if docker node ls &> /dev/null; then
		#Wait for containers to startup
		while [[ "$(docker ps | wc -l)" != "7" ]]; do sleep 1; done
		#Wait for load balancer ips to get reported
		while ! docker inspect --format '{{ .Config.Env }}' $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') | grep -E "LOAD_BALANCER_IPS=172\.23\.0\.[[:digit:]] 172\.23\.0\.[[:digit:]]"; do sleep 1; done
		#Wait for all rules to get added (causing log entries to repeat)
		READY_LOGS=$(cat <<-'EOF'
			 DEBUG: Subnet of test_public is 172.23.0.0/24
			 DEBUG: Error Count: 0
			 DEBUG: Network driver of test_public is overlay
			 DEBUG: Subnet of test_public is 172.23.0.0/24
			EOF
		)
		while [[ "$(docker logs $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') | awk -F']' '{ print $2 }' | grep -v Whitelisted | tail -n 4)" != "$READY_LOGS" ]]; do sleep 1; done
	fi
	export RP_ID=$(docker ps --quiet --filter 'name=test_reverseproxy')
	export TJ_ID=$(docker ps --quiet --filter 'name=trafficjam_FDB2E498')
	export TPU1_ID=$(docker ps --quiet --filter 'name=test_public1')
	export TPU2_ID=$(docker ps --quiet --filter 'name=test_public2')
	export TPR1_ID=$(docker ps --quiet --filter 'name=test_private1')
	docker exec "$RP_ID" apk add --no-cache curl
}

@test "whoami containers are responsive" {
	curl --silent --show-error --max-time 5 localhost:8000
	curl --silent --show-error --max-time 5 localhost:8000

	curl --silent --show-error --max-time 5 localhost:8001
	curl --silent --show-error --max-time 5 localhost:8001

	curl --silent --show-error --max-time 5 localhost:8002
	curl --silent --show-error --max-time 5 localhost:8002
}

@test "whitelisted containers can communicate with all other containers on the specified network" {
	docker ps

	#Each is run twice to hit both nodes
	docker exec "$RP_ID" ping -c 2 -w 10 test_public1
	docker exec "$RP_ID" ping -c 2 -w 10 test_public1

	#docker exec "$RP_ID" curl --silent --show-error --max-time 5 test_public1:8000
	#docker exec "$RP_ID" curl --silent --show-error --max-time 5 test_public1:8000

	docker exec "$RP_ID" curl --verbose --max-time 5 test_public1:8000
	docker exec "$RP_ID" curl --verbose --max-time 5 test_public1:8000

	docker exec "$RP_ID" ping -c 2 -w 10 test_public2
	docker exec "$RP_ID" ping -c 2 -w 10 test_public2

	docker exec "$RP_ID" curl --silent --show-error --max-time 5 test_public2:8000
	docker exec "$RP_ID" curl --silent --show-error --max-time 5 test_public2:8000
}

@test "containers on the specified network can not communicate with one another" {
	run docker exec "$TPU1_ID" ping -c 2 -w 10 test_public2
	[ "$status" -eq 1 ]
	run docker exec "$TPU1_ID" ping -c 2 -w 10 test_public2
	[ "$status" -eq 1 ]

	run docker exec "$TPU1_ID" curl --silent --show-error --max-time 5 test_public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
	run docker exec "$TPU1_ID" curl --silent --show-error --max-time 5 test_public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with one another (opposite direction)" {
	run docker exec "$TPU2_ID" ping -c 2 -w 10 test_public1
	[ "$status" -eq 1 ]
	run docker exec "$TPU2_ID" ping -c 2 -w 10 test_public1
	[ "$status" -eq 1 ]

	run docker exec "$TPU2_ID" curl --silent --show-error --max-time 5 test_public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
	run docker exec "$TPU2_ID" curl --silent --show-error --max-time 5 test_public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with others via host-mapped ports" {
	run docker exec "$TPU1_ID" sh -c "curl --silent --show-error --max-time 5 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]

	run docker exec "$TPU1_ID" sh -c "curl --silent --show-error --max-time 5 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on non-specified networks can communicate" {
	docker exec "$TPR1_ID" ping -c 2 -w 10 test_reverseproxy
	docker exec "$TPR1_ID" ping -c 2 -w 10 test_reverseproxy

	docker exec "$RP_ID" ping -c 2 -w 10 test_private1
	docker exec "$RP_ID" ping -c 2 -w 10 test_private1

	docker exec "$RP_ID" curl --silent --show-error --max-time 5 test_private1:8000
	docker exec "$RP_ID" curl --silent --show-error --max-time 5 test_private1:8000
}
