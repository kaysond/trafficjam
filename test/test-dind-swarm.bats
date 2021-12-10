setup_file() {
	#Only run this on the manager
	if docker node ls &> /dev/null; then
		#Wait up to 3min for test swarm to reach desired state 
		READY=""
		i=0
		LIMIT=36
		while [[ -z "$READY" ]]; do
			sleep 5
			READY="true"
			ERRORS=()

			#Images are built
			if ! docker image ls |& grep -q whoami; then
				READY=""
				ERRORS=("${ERRORS[@]}" "Images aren't built" "$(docker image ls)")
			fi

			#All containers are started
			if [[ "$(docker ps 2> /dev/null | wc -l)" != "7" ]]; then
				READY=""
				ERRORS=("${ERRORS[@]}" "Containers aren't started" "$(docker ps)")
			fi

			if docker service ls | grep -q trafficjam_FDB2E498; then
				#Two trafficjam tasks exist with LOAD_BALANCER_IPS env vars set
				if [[ "$(docker inspect --format '{{ .Spec.ContainerSpec.Env }}' $(docker service ps --quiet --filter desired-state=running trafficjam_FDB2E498) | \
						grep -cE 'LOAD_BALANCER_IPS=172\.23\.0\.[[:digit:]]{1,3} 172\.23\.0\.[[:digit:]]{1,3}')" != "2" ]]; then
					READY=""
					ERRORS=("${ERRORS[@]}" "trafficjam tasks aren't ready" "$(docker inspect --format '{{ .Spec.ContainerSpec.Env }}' $(docker service ps --quiet --filter desired-state=running trafficjam_FDB2E498))")
				fi
			
				#All rules are added on both running trafficjam tasks
				for TASKID in $(docker service ps trafficjam_FDB2E498 | grep Running | cut -d' ' -f1); do
					if [[ "$(docker service logs trafficjam_FDB2E498 | grep "$TASKID" | awk -F']' '{ print $2 }' | grep -v Whitelisted | tail -n 6 | grep -c 'DEBUG: Error Count: 0')" != "2" ]]; then
						READY=""
						ERRORS=("${ERRORS[@]}" "rules are not added on task $TASKID" "$(docker logs $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') | awk -F']' '{ print $2 }' | grep -v Whitelisted | tail -n 6)")
					fi
				done
			else
				READY=""
				ERRORS=("${ERRORS[@]}" "trafficjam service doesn't exist" "$(docker service ls)")
			fi

			#All whoami servicecs are running
			if [[ "$(docker inspect --format '{{ .Status.State }}' $(docker service ps -q test_public1 | head -n1))" != "running" || \
                "$(docker inspect --format '{{ .Status.State }}' $(docker service ps -q test_public2 | head -n1))" != "running" || \
                "$(docker inspect --format '{{ .Status.State }}' $(docker service ps -q test_private1 | head -n1))" != "running" ]]; then
                READY=""
				ERRORS=("${ERRORS[@]}" "whoami services aren't ready" "$(docker service ls)" "$(docker service ps test_public1)" "$(docker service ps test_public2)" "$(docker service ps test_private1)" )
			fi

			if (( i >= LIMIT )); then
				echo "Timed out waiting for swarm state to converge" >&2
				IFS='\n'
				echo -e "${ERRORS[@]}" >&2
				IFS=' \n\t'
				exit 1
			fi
		done
	fi
	export RP_ID=$(docker ps --quiet --filter 'name=test_reverseproxy')
	export TJ_ID=$(docker ps --quiet --filter 'name=trafficjam_FDB2E498')
	export TPU1_ID=$(docker ps --quiet --filter 'name=test_public1')
	export TPU2_ID=$(docker ps --quiet --filter 'name=test_public2')
	export TPR1_ID=$(docker ps --quiet --filter 'name=test_private1')
	docker exec "$RP_ID" apk add --no-cache curl
}

@test "whitelisted containers can communicate with all other containers on the specified network" {
	#Each is run twice to hit both nodes
	docker exec "$RP_ID" curl --verbose --max-time 5 test_public1:8000 || { docker service logs trafficjam_FDB2E498; docker service logs test_public1; exit 1; }
	docker exec "$RP_ID" curl --verbose --max-time 5 test_public1:8000

	docker exec "$RP_ID" curl --verbose --max-time 5 test_public2:8000
	docker exec "$RP_ID" curl --verbose --max-time 5 test_public2:8000
}

@test "containers on the specified network can not communicate with one another" {
	run docker exec "$TPU1_ID" ping -c 2 -w 10 test_public2
	[ "$status" -eq 1 ]

	run docker exec "$TPU1_ID" curl --verbose --max-time 5 test_public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
	run docker exec "$TPU1_ID" curl --verbose --max-time 5 test_public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with one another (opposite direction)" {
	run docker exec "$TPU2_ID" ping -c 2 -w 10 test_public1
	[ "$status" -eq 1 ]

	run docker exec "$TPU2_ID" curl --verbose --max-time 5 test_public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
	run docker exec "$TPU2_ID" curl --verbose --max-time 5 test_public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with others via host-mapped ports" {
	run docker exec "$TPU1_ID" sh -c "curl --verbose --max-time 5 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]

	run docker exec "$TPU1_ID" sh -c "curl --verbose --max-time 5 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on non-specified networks can communicate" {
	docker exec "$TPR1_ID" curl --verbose --max-time 5 test_reverseproxy
	docker exec "$TPR1_ID" curl --verbose --max-time 5 test_reverseproxy

	docker exec "$RP_ID" curl --verbose --max-time 5 test_private1:8000
	docker exec "$RP_ID" curl --verbose --max-time 5 test_private1:8000
}
