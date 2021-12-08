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
	docker-compose --file "$BATS_TEST_DIRNAME"/docker-compose.yml --project-name trafficjam_test up --detach
}

@test "Test the non-swarm environment" {
	docker exec trafficjam_test bats /opt/trafficjam/test/test-dind.bats
}

@test "Deploy the non-swarm environment with nftables" {
	docker-compose --file "$BATS_TEST_DIRNAME"/docker-compose-nftables.yml --project-name trafficjam_test_nftables up --detach
}

@test "Test the non-swarm environment with nftables" {
	docker exec trafficjam_test_nftables bats /opt/trafficjam/test/test-dind.bats
}

@test "Deploy the swarm environment" {
	docker-compose --file "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml --project-name trafficjam_test_swarm up --detach
	sleep 5 #Wait for the daemons to start
	docker exec swarm-manager docker swarm init
	docker exec swarm-worker $(docker exec swarm-manager docker swarm join-token worker | grep "join --token")
}

@test "Test the swarm manager" {
	docker exec swarm-manager bats /opt/trafficjam/test/test-dind-swarm.bats
}

@test "Test the swarm worker" {
	docker exec swarm-worker bats /opt/trafficjam/test/test-dind-swarm.bats
}

function teardown_file() {
	docker-compose --file "$BATS_TEST_DIRNAME"/docker-compose.yml --project-name trafficjam_test down
	docker-compose --file "$BATS_TEST_DIRNAME"/docker-compose-nftables.yml --project-name trafficjam_test_nftables down
	docker-compose --file "$BATS_TEST_DIRNAME"/docker-compose-swarm.yml --project-name trafficjam_test_swarm down
	docker image rm --force trafficjam_bats trafficjam_test
}