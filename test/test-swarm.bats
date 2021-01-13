setup_file () {
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" up -d
	docker exec swarm-manager docker swarm init
	docker exec swarm-worker $(docker exec swarm-manager docker swarm join-token worker | grep "join --token")
	docker exec swarm-manager docker stack deploy -c /opt/traefikjam/test/swarm/docker-compose-dind.yml test
}

teardown_file() {
	docker-compose -f "$BATS_TEST_DIRNAME/docker-compose.yml" down
}