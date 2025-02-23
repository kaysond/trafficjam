function setup_file() {
	if command -v docker-compose; then
		export DOCKER_COMPOSE_CMD=docker-compose
	else
		export DOCKER_COMPOSE_CMD='docker compose'
	fi
}

@test "Run shellcheck" {
	shellcheck "$BATS_TEST_DIRNAME/../trafficjam-functions.sh"
	shellcheck -x "$BATS_TEST_DIRNAME/../trafficjam.sh"
}

@test "Build the image" {
	docker build --tag trafficjam_bats --file "$BATS_TEST_DIRNAME"/../Dockerfile "$BATS_TEST_DIRNAME"/..
}

@test "Build the test image" {
	docker build --tag trafficjam_test --file "$BATS_TEST_DIRNAME"/containers/trafficjam_test/Dockerfile  "$BATS_TEST_DIRNAME"/..
}

@test "Deploy the non-swarm environment" {
	$DOCKER_COMPOSE_CMD --file "$BATS_TEST_DIRNAME"/docker-compose.yml --project-name trafficjam_test up --detach
}

@test "Test the non-swarm environment" {
	docker exec trafficjam_test bats /opt/trafficjam/test/test-dind.bats
}

@test "Deploy the swarm environment" {
	$DOCKER_COMPOSE_CMD --file "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml --project-name trafficjam_test_swarm up --detach
	sleep 5
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
	$DOCKER_COMPOSE_CMD --file "$BATS_TEST_DIRNAME"/docker-compose-nftables.yml --project-name trafficjam_test_nftables down
	$DOCKER_COMPOSE_CMD --file "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml --project-name trafficjam_test_swarm down
	docker image rm --force trafficjam_bats trafficjam_test
}