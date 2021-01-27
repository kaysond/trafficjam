@test "Run shellcheck" {
	shellcheck "$BATS_TEST_DIRNAME/../traefikjam-functions.sh"
	shellcheck -x "$BATS_TEST_DIRNAME/../traefikjam.sh"
}

@test "Build the test image" {
	docker build --tag traefikjam_test --file "$BATS_TEST_DIRNAME"/containers/traefikjam_test/Dockerfile  "$BATS_TEST_DIRNAME"/..
}

@test "Deploy the non-swarm environment" {
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose.yml up -d
}

@test "Test the non-swarm environment" {
	docker exec traefikjam_test bats /opt/traefikjam/test/test-dind.bats
}

@test "Deploy the swarm environment" {
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml up -d
	docker exec swarm-manager docker swarm init
	docker exec swarm-worker $(docker exec swarm-manager docker swarm join-token worker | grep "join --token")
	docker exec swarm-manager docker stack deploy -c /opt/traefikjam/test/docker-compose-dind-swarm.yml test
}

@test "Test the swarm manager" {
	docker exec swarm-manager bats /opt/traefikjam/test/test-dind-swarm.bats
}

@test "Test the swarm worker" {
	docker exec swarm-worker bats /opt/traefikjam/test/test-dind-swarm.bats
}

function teardown_file() {
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose.yml down
	#docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml down
}
