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
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose.yml up -d
}

@test "Test the non-swarm environment" {
	docker exec trafficjam_test bats /opt/trafficjam/test/test-dind.bats
}

@test "Deploy the non-swarm environment with nftables" {
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose-nftables.yml up -d
}

@test "Test the non-swarm environment with nftables" {
	docker exec trafficjam_test bats /opt/trafficjam/test/test-dind.bats
}

@test "Deploy the swarm environment" {
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml up -d
	docker exec swarm-manager docker swarm init
	docker exec swarm-worker $(docker exec swarm-manager docker swarm join-token worker | grep "join --token")
	docker exec swarm-manager docker stack deploy -c /opt/trafficjam/test/docker-compose-dind-swarm.yml test
}

@test "Test the swarm manager" {
	docker exec swarm-manager bats /opt/trafficjam/test/test-dind-swarm.bats
}

@test "Test the swarm worker" {
	docker exec swarm-worker bats /opt/trafficjam/test/test-dind-swarm.bats
}

function teardown_file() {
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose.yml down
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose-nftables.yml down
	docker-compose -f "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml down
	docker image rm --force trafficjam_bats trafficjam_test
}
