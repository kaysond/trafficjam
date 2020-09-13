setup_file () {
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" -p test up -d 
	for container in traefik public1 public2 private1; do
		docker exec "$container" apk add --no-cache curl
	done
}

teardown_file() {
#	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" down
echo "a"
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

@test "containers on the specified network can communicate with whitelisted containers" {
	docker exec public1 ping traefik -c 2 -w 2
}

@test "containers (another one) on the specified network can communicate with whitelisted images" {
        docker exec public2 ping traefik -c 2 -w 2
}

@test "containers on the specified network can not communicate with one another" {
        run docker exec public1 ping public2 -c 2 -w 2
        [ "$status" -eq 1 ]

        run docker exec public1 curl -s -S -m 2 public2:8000
        [ "$status" -ne 0 ]
}

@test "containers on the specified network can not communicate with one another (opposite direction)" {
        run docker exec public2 ping public1 -c 2 -w 2
        [ "$status" -eq 1 ]

        run docker exec public2 curl -s -S -m 2 public1:8000
        [ "$status" -ne 0 ]
}

@test "containers on the specified network can not communicate with others via host-mapped ports" {
	curl -s -S localhost:8002

	run docker exec public1 curl -s -S -m 2 public2:8002
	[ "$status" -ne 0 ]
}

@test "containers on non-specified networks can communicate" {
	docker exec private1 ping traefik -c 2 -w 2
}
