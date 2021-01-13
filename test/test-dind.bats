setup_file () {
	if iptables -t filter -L | grep traefikjam; then
		echo "found existing traefikjam rules" >&2 && exit 1
	fi
	while ! docker image ls | grep whoami; do sleep 1; done #wait for images to finish building on container startup
	docker-compose -f /opt/traefikjam/test/docker-compose-dind.yml up -d
	docker exec traefik apk add --no-cache curl
}

@test "whoami containers are responsive" {
	curl -s -S localhost:8000

	curl -s -S localhost:8001

	curl -s -S localhost:8002
}

@test "whitelisted containers can communicate with all other containers" {
	docker exec traefik ping -c 2 -w 2 public1

	docker exec traefik curl -s -S -m 2 public1:8000

	docker exec traefik ping -c 2 -w 2 public2

	docker exec traefik curl -s -S -m 2 public2:8000

	docker exec traefik ping -c 2 -w 2 private1

	docker exec traefik curl -s -S -m 2 private1:8000
}

@test "containers on the specified network can not communicate with one another" {
	run docker exec public1 ping public2 -c 2 -w 2
	echo "$status"
	echo "${lines[@]}"
	[ "$status" -eq 1 ]

	run docker exec public1 curl -s -S -m 2 public2:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with one another (opposite direction)" {
	run docker exec public2 ping public1 -c 2 -w 2
	echo "$status"
	echo "${lines[@]}"
	[ "$status" -eq 1 ]

	run docker exec public2 curl -s -S -m 2 public1:8000
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on the specified network can not communicate with others via host-mapped ports" {
	curl -s -S localhost:8002

	run docker exec public1 sh -c "curl -s -S -m 2 `ip route | grep default | awk '{ print $3 }'`:8002" #get to host via default gateway
	[ "$status" -eq 7 -o "$status" -eq 28 ]
}

@test "containers on non-specified networks can communicate" {
	docker exec private1 ping traefik -c 2 -w 2
}
