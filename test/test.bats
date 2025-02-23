@test "Build the image" {
	docker build --tag trafficjam_bats --file "$BATS_TEST_DIRNAME"/../Dockerfile "$BATS_TEST_DIRNAME"/..
}

@test "Build the test images" {
	docker build --tag trafficjam_test --file "$BATS_TEST_DIRNAME"/containers/trafficjam_test/Dockerfile  "$BATS_TEST_DIRNAME"/..
	docker build --tag trafficjam_test_whoami --file "$BATS_TEST_DIRNAME"/containers/whoami/Dockerfile  "$BATS_TEST_DIRNAME"/containers/whoami
}

@test "Deploy the non-swarm environment" {
	docker compose --file "$BATS_TEST_DIRNAME"/docker-compose.yml --project-name trafficjam_test up --detach
	while ! docker exec trafficjam_test docker ps; do
		if (( ++i > 12 )); then
			echo "Timed out waiting for docker in docker to start up" >&2
			exit 1
		fi
		sleep 5
	done
}

@test "Test the non-swarm environment" {
	docker exec trafficjam_test bats /opt/trafficjam/test/test-dind.bats
}

@test "Deploy the swarm environment" {
	docker compose --file "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml --project-name trafficjam_test_swarm up --detach
	while ! docker exec swarm-manager docker ps || ! docker exec swarm-worker docker ps; do
		if (( ++i > 12 )); then
			echo "Timed out waiting for docker in docker to start up" >&2
			exit 1
		fi
		sleep 5
	done
	docker exec swarm-manager docker swarm init
	docker exec swarm-worker $(docker exec swarm-manager docker swarm join-token worker | grep "join --token")
	sleep 5
	docker exec swarm-manager docker stack deploy -c /opt/trafficjam/test/docker-compose-dind-swarm.yml test
}

@test "Test the swarm manager" {
	docker exec swarm-manager bats /opt/trafficjam/test/test-dind-swarm.bats
}

@test "Test the swarm worker" {
	docker exec swarm-worker bats /opt/trafficjam/test/test-dind-swarm.bats
}

@test "killing the swarm daemon removes the service" {
	docker exec swarm-manager docker service rm test_trafficjam
	sleep 5
	run bash -c "docker exec swarm-manager docker service ls | grep trafficjam_DEFAULT"
	[ "$status" -eq 1 ]
}

function teardown_file() {
	$DOCKER_COMPOSE_CMD --file "$BATS_TEST_DIRNAME"/docker-compose.yml --project-name trafficjam_test down
	$DOCKER_COMPOSE_CMD --file "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml --project-name trafficjam_test_swarm down
	docker image rm --force trafficjam_bats trafficjam_test trafficjam_test_whoami
}