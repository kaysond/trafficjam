setup_file() {
	#Wait for images to finish building on container startup for 45s
	i=0
	while ! docker image ls | grep -q whoami; do
		sleep $(( ++i )) && \
		(( i < 10 )) || {
			echo Timed out waiting for images to be built >&2
			docker image ls >&2
			exit 1
		}
	done

	#Only run these checks on the manager
	if docker node ls &> /dev/null; then
		#Wait for containers to startup for 45s
		i=0
		while [[ "$(docker ps | wc -l)" != "7" ]]; do
			sleep $(( ++i )) && \
			(( i < 10 )) || { 
				echo Timed out waiting for container startup >&2
				docker ps >&2
				exit 1
			}
		done

		#Wait for load balancer ips to get reported for 45s
		i=0
		while ! docker inspect --format '{{ .Config.Env }}' $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') | \
			grep -q -E "LOAD_BALANCER_IPS=172\.23\.0\.[[:digit:]] 172\.23\.0\.[[:digit:]]"; do

			sleep $(( ++i )) && \
			(( i < 10 )) || { 
				echo Timed out waiting for load balancer IPs to be reported >&2
				docker inspect --format '{{ .Config.Env }}' $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') >&2
				exit 1
			}
		done

		#Wait for all rules to get added (causing log entries to repeat) for 135s
		i=0
		while [[ $(docker logs $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') | \
			awk -F']' '{ print $2 }' | \
			grep -v Whitelisted | \
			tail -n 6 | \
			grep -c "DEBUG: Error Count: 0") != "2" ]]; do

			sleep $(( ++i )) && \
			(( i < 20 )) || {
				echo Timed out waiting for rules to be added >&2
				docker logs $(docker ps --quiet --filter 'name=trafficjam_FDB2E498') | awk -F']' '{ print $2 }' | grep -v Whitelisted | tail -n 6 >&2
				exit 1
			}
		done
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
