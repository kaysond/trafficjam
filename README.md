# VERY BETA
# Run
```
docker run -d --name traefikjam --cap-add NET_ADMIN --network host \
	-v "/var/run/docker.sock:/var/run/docker.sock"
	-e POLL_INTERVAL=5 \
	-e NETWORK=traefik_network \
	-e WHITELIST_FILTERS="ancestor=traefik:latest" \
	kaysond/traefikjam
```
