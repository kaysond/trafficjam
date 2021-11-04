setup_file() {
	if iptables -t filter -L | grep trafficjam; then
		echo "found existing trafficjam rules" >&2 && exit 1
	fi
	while ! docker image ls | grep whoami; do sleep 1; done #wait for images to finish building on container startup
	docker-compose -f /opt/trafficjam/test/docker-compose-dind.yml up -d
	docker exec traefik apk add --no-cache curl
}

@test "whoami containers are responsive" {
	curl --silent --show-error --max-time 5 localhost:8000

	curl --silent --show-error --max-time 5 localhost:8001

	curl --silent --show-error --max-time 5 localhost:8002
}

@test "whitelisted containers can communicate with all other containers on the specified network" {
	#Sometimes this ping fails for no reason on github CI, so try it again
	docker exec traefik ping -c 2 -w 10 public1 || docker exec traefik ping -c 2 -w 10 public1

	docker exec traefik curl --silent --show-error --max-time 5 public1:8000

	docker exec traefik ping -c 2 -w 10 public2 || docker exec traefik ping -c 2 -w 10 public2

	docker exec traefik curl --silent --show-error --max-time 5 public2:8000
}

@test "containers on the specified network can not communicate with one another" {
	run docker exec public1 ping -c 2 -w 10 public2
	[ "$status" -eq 1 ]

	run docker exec public1 curl --silent --show-error --max-time 5 public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with one another (opposite direction)" {
	run docker exec public2 ping -c 2 -w 10 public1
	[ "$status" -eq 1 ]

	run docker exec public2 curl --silent --show-error --max-time 5 public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with others via host-mapped ports" {
	run docker exec public1 sh -c "curl --silent --show-error --max-time 5 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on non-specified networks can communicate" {
	docker exec private1 ping -c 2 -w 10 traefik
	docker exec traefik ping -c 2 -w 10 private1
	docker exec traefik curl --silent --show-error --max-time 5 private1:8000
}
