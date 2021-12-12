setup_file() {
	if iptables -t filter -L | grep -q trafficjam; then
		echo "Found existing trafficjam rules" >&2 && exit 1
	fi
	#Wait for images to finish building on container startup for 60s
	while ! docker image ls | grep -q whoami; do
		if (( ++i > 12 )); then
			echo "Timed out waiting for images to build" >&2
			docker image ls >&2
			exit 1
		fi
		sleep 5
	done
	docker-compose -f /opt/trafficjam/test/docker-compose-dind.yml up -d
	docker exec traefik apk add --no-cache curl
}

@test "whoami containers are responsive" {
	curl --verbose --max-time 5 localhost:8000

	curl --verbose --max-time 5 localhost:8001

	curl --verbose --max-time 5 localhost:8002
}

@test "whitelisted containers can communicate with all other containers on the specified network" {
	#Sometimes this ping fails for no reason on github CI, so try it again
	docker exec traefik ping -c 2 -w 10 public1 || docker exec traefik ping -c 2 -w 10 public1

	docker exec traefik curl --verbose --max-time 5 public1:8000

	docker exec traefik ping -c 2 -w 10 public2 || docker exec traefik ping -c 2 -w 10 public2

	docker exec traefik curl --verbose --max-time 5 public2:8000
}

@test "containers on the specified network can not communicate with one another" {
	run docker exec public1 ping -c 2 -w 10 public2
	[ "$status" -eq 1 ]

	run docker exec public1 curl --verbose --max-time 5 public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with one another (opposite direction)" {
	run docker exec public2 ping -c 2 -w 10 public1
	[ "$status" -eq 1 ]

	run docker exec public2 curl --verbose --max-time 5 public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with others via host-mapped ports" {
	run docker exec public1 sh -c "curl --verbose --max-time 5 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on non-specified networks can communicate" {
	docker exec private1 ping -c 2 -w 10 traefik
	docker exec traefik ping -c 2 -w 10 private1
	docker exec traefik curl --verbose --max-time 5 private1:8000
}

@test "clearing rules with SIGUSR1 works properly" {
	docker kill --signal SIGUSR1 trafficjam
	sleep 5
	run bash -c "docker ps | grep trafficjam"
	[ "$status" -eq 1 ]
	[ "$(iptables --numeric --list TRAFFICJAM | wc -l)" -eq 2 ]
	[ "$(iptables --numeric --list TRAFFICJAM_INPUT | wc -l)" -eq 2 ]
}

@test "deploy with ALLOW_HOST_TRAFFIC" {
	docker-compose -f /opt/trafficjam/test/docker-compose-dind.yml down
	sleep 5
	docker-compose -f /opt/trafficjam/test/docker-compose-dind-allowhost.yml up -d
}

@test "containers can communicate via host-mapped ports (public1)" {
	HOST_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
	docker exec public1 ping -c 2 -w 10 "$HOST_IP"
	docker exec public1 curl --verbose --max-time 5 "$HOST_IP":80
	docker exec public1 curl --verbose --max-time 5 "$HOST_IP":8000
	docker exec public1 curl --verbose --max-time 5 "$HOST_IP":8002
}

@test "containers can communicate via host-mapped ports (public2)" {
	HOST_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
	docker exec public2 ping -c 2 -w 10 "$HOST_IP"
	docker exec public2 curl --verbose --max-time 5 "$HOST_IP":80
	docker exec public2 curl --verbose --max-time 5 "$HOST_IP":8000
	docker exec public2 curl --verbose --max-time 5 "$HOST_IP":8001
}

@test "clearing rules with a command works properly" {
	docker run \
		--volume "/var/run/docker.sock:/var/run/docker.sock" \
		--cap-add NET_ADMIN \
		--network host \
		trafficjam --clear
	iptables --numeric --list
	[ "$(iptables --numeric --list TRAFFICJAM | wc -l)" -eq 2 ]
	[ "$(iptables --numeric --list TRAFFICJAM_INPUT | wc -l)" -eq 2 ]
}