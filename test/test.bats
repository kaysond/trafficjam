setup_file() {
	for container in traefik public1 public2 private1; do
		docker exec "$container" apk add --no-cache curl
	done
}

@test "whoami containers are responsive" {
	run curl localhost:8000
	[ "$status" -eq 0 ]

	run curl localhost:8001
	[ "$status" -eq 0 ]

	run curl localhost:8002
	[ "$status" -eq 0 ]
}

@test "whitelisted containers can communicate with all other containers" {
	run docker exec traefik ping -c 2 -w 2 public1
	[ "$status" -eq 0 ]

	run docker exec traefik curl -m 2 public1:8000
	[ "$status" -eq 0 ]

        run docker exec traefik ping -c 2 -w 2 public2
        [ "$status" -eq 0 ]

        run docker exec traefik curl -m 2 public2:8000
        [ "$status" -eq 0 ]

        run docker exec traefik ping -c 2 -w 2 private1
        [ "$status" -eq 0 ]

        run docker exec traefik curl -m 2 private1:8000
        [ "$status" -eq 0 ]
}

@test "containers on the specified network can communicate to whitelisted containers" {
	run docker exec public1 ping traefik -c 2 -w 2
	[ "$status" -eq 0 ]
}

@test "containers (another one) on the specified network can communicate to whitelisted images" {
        run docker exec public2 ping traefik -c 2 -w 2
        [ "$status" -eq 0 ]
}

@test "containers on the specified network can not communicate to one another" {
        run docker exec public1 ping public2 -c 2 -w 2
        [ "$status" -eq 1 ]

        run docker exec public1 curl -m 2 public2:8000
        [ "$status" -ne 0 ]
}

@test "containers on the specified network can not communicate to one another (opposite direction)" {
        run docker exec public2 ping public1 -c 2 -w 2
        [ "$status" -eq 1 ]

        run docker exec public2 curl -m 2 public1:8000
        [ "$status" -ne 0 ]
}

@test "containers on the specified network can not communicate to others via host-mapped ports" {
	run curl localhost:8002
	[ "$status" -eq 0 ]

	run docker exec public1 curl -m 2 public2:8002
	[ "$status" -ne 0 ]
}

@test "containers on non-specified networks can communicate" {
	run docker exec private1 ping traefik -c 2 -w 2
	[ "$status" -eq 0 ]
}
