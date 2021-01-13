setup_file () {
	docker build --tag traefikjam_test --file "$BATS_TEST_DIRNAME/containers/traefikjam_test/Dockerfile" "$BATS_TEST_DIRNAME/.."
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" up -d
#	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose-swarm.yml" up -d
}

teardown_file() {
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" down
#	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose-swarm.yml" down
}

@test "test container" {
	docker exec traefikjam_test bats /opt/traefikjam/test/test-dind.bats
}

@test "test swarm manager" {
	skip
	docker exec swarm-manager bats /opt/traefikjam/test/test-dind-swarm.bats
}

@test "test swarm worker" {
	skip
	docker exec swarm-worker bats /opt/traefikjam/test/test-dind-swarm.bats
}
