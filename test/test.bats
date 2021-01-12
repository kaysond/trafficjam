setup_file () {
	docker build -t whoami "$BATS_TEST_DIRNAME/whoami"
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" -p test up -d 
	docker exec traefik apk add --no-cache curl
}

teardown_file() {
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" down
	docker image rm whoami
	$BATS_TEST_DIRNAME/clear_rules
}

@test "no traefikjam rules currently exist" {
	iptables=$(iptables -L)
	run bash -c "echo $iptables | grep traefikjam"
	[ "$status" -ne  0 ]
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
