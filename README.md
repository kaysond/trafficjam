# TraefikJam (Beta)
A Docker firewall for your reverse proxy network

| Master | Develop |
| ------------ | ------------ |
|[![Release](https://github.com/kaysond/traefikjam/workflows/Release/badge.svg)](https://github.com/kaysond/traefikjam/actions?query=workflow%3ARelease)|[![Build](https://github.com/kaysond/traefikjam/workflows/Build/badge.svg)](https://github.com/kaysond/traefikjam/actions?query=workflow%3ABuild)|
|[![CI](https://github.com/kaysond/traefikjam/workflows/CI/badge.svg?branch=master)](https://github.com/kaysond/traefikjam/actions?query=workflow%3ACI+branch%3Amaster)|[![CI](https://github.com/kaysond/traefikjam/workflows/CI/badge.svg?branch=develop)](https://github.com/kaysond/traefikjam/actions?query=workflow%3ACI+branch%3Adevelop)|

## Threat Model
**Why do you need something like TraefikJam?** Reverse proxies are often used to authenticate external access to internal services, providing benefits such as centralized user management, access control, 2FA and SSO. In a typical Docker setup, multiple services are connected to the reverse proxy via a single network. If a user authenticates to one service and is able to compromise that service (such as by using [this Pi-Hole vulnerability](http://https://natedotred.wordpress.com/2020/03/28/cve-2020-8816-pi-hole-remote-code-execution/ "this Pi-Hole vulnerability")), that user will gain access to the entire network *behind* the reverse proxy, and can access every service on the network whether they would normally have permission or not.

Potential solutions include:
* Use each service's own authentication
  * Not all services provide 2FA :(
  * Many services do not support centralized user management (LDAP)  :(
  * Many services do not support SSO  :(
* Have each service on a unique network
  * Reverse proxy network connections must be updated every time a service is added or removed :(
  * Manually configuring every service and reverse proxy entry is painful and error-prone even with tools like Ansible :(
* Use a reverse proxy with auto-discovery and a firewall to isolate services
  * Enables 2FA, LDAP, ACL, SSO, etc. regardless of service support :)
  * Routes are automatically discovered by the proxy without manual configuration :)
  * Every service only needs a connection to one network :)

## Configuration
TraefikJam is configured via several environment variables:
* **TZ** - Timezone (for logging)
* **POLL_INTERVAL** - How often TraefikJam checks Docker for changes
* **NETWORK** - The name of the Docker network this instance of TraefikJam should manage (multiple instances can be run for different networks)
* **WHITELIST_FILTER** - A Docker `--filter` parameter that designates which containers should be permitted to openly access the network. See [Docker Docs - filtering](https://docs.docker.com/engine/reference/commandline/ps/#filtering)
* **ALLOW_HOST_TRAFFIC** - By default TraefikJam blocks traffic from containers to the Docker host in order to block communication via mapped ports (i.e. with `-p`). The host, however, can still initiate communication with the containers. Setting this variable allows containers to initiate communication with the host, and any port-mapped containers.
* **DEBUG** - Setting this variable turns on debug logging
* **SWARM_DAEMON** - Setting this variable is required for swarm and activates a daemon that determines network load balancer IP addresses and properly configures the traefikjam service
* **SWARM_IMAGE** - The image the traefikjam swarm daemon should deploy (defaults to `kaysond/traefikjam`). The best practice is to pin this to a particular image hash (e.g. `kaysond/traefikjam:v1.0.0@sha256:8d41599fa564e058f7eb396016e229402730841fa43994124a8fb3a14f1a9122`)

## Setup Examples

### Vanilla Docker
`docker-cli`:
```
docker run -d --name traefikjam --cap-add NET_ADMIN --network host \
	-v "/var/run/docker.sock:/var/run/docker.sock" \
	--env TZ=America/Los_Angeles \
	--env POLL_INTERVAL=5 \
	--env NETWORK=traefik_network \
	--env WHITELIST_FILTER="ancestor=traefik:latest" \
	kaysond/traefikjam
```

`docker-compose.yml`:
```
version: '3.8'
services:
  traefikjam:
    container_name: traefikjam
    image: kaysond/traefikjam
	cap_add:
      - NET_ADMIN
    network_mode: host
    volumes:
     - /var/run/docker.sock:/var/run/docker.sock
    environment:
      TZ: America/Los_Angeles
      POLL_INTERVAL: 5
      NETWORK: nginx_network
      WHITELIST_FILTER: ancestor=nginx:latest

  nginx:
    container_name: nginx
    image: nginx:latest
    networks:
      nginx_network:

  example_service:
    container_name: whoami2
    image: jwilder/whoami
    ports:
      - "8000:8000"
    networks:
      nginx_network:

networks:
  nginx_network:
```

### Docker Swarm
`docker-cli`:
```
docker service create \
  --name traefikjam \
  --mount type=bind,source=/var/run/docker.sock,destination=/var/run/docker.sock \
  --env TZ=America/Los_Angeles \
  --env POLL_INTERVAL=5 \
  --env NETWORK=traefik_network \
  --env WHITELIST_FILTER=ancestor=traefik:v2.3.7@sha256:0aca29bb8e51aa69569b15b8b7f08328e6957cbec201dd532304b3329e5a82a9 \
  --env SWARM_DAEMON=true \
  --replicas 1 \
  --constraint node.role==manager \
  kaysond/traefikjam
```

`docker-compose.yml`:
```
version: '3.8'

services:
  traefikjam:
    image: traefikjam
    volumes:
     - /var/run/docker.sock:/var/run/docker.sock
    environment:
      TZ: America/Los_Angeles
      POLL_INTERVAL: 5
      NETWORK: traefik_network
      WHITELIST_FILTER: ancestor=traefik:v2.3.7@sha256:0aca29bb8e51aa69569b15b8b7f08328e6957cbec201dd532304b3329e5a82a9
      SWARM_DAEMON: "true"
    deploy:
      replicas: 1
      placement:
        constraints: ['node.role==manager']
```

#### Notes on docker swarm
* Docker swarm services tag images with a sha256 hash to guarantee that every node runs the exact same container (since tags are mutable). When using the `ancestor` tag, ensure that the appropriate hash is included as shown in the examples.
* Docker swarm employs a load balancer on each node whose IP address must be permitted to communicate to the subnet. Since each node (even a manager) is only aware of its own load balancer's IP address, TraefikJam must operate as a daemon to start a "child" service, collect the reported load balancer IP addresses, and update the service with the information.

## Operation
TraefikJam limits traffic between containers by adding rules to the host iptables. The Docker network subnet and the IP addresses of whitelisted containers are determined. A rule is added to the end of the `DOCKER-USER` chain to jump to a `TRAEFIKJAM` chain. Then, several rules are added to a `TRAEFIKJAM`  chain in the filter table:
1. Accept already-established traffic whose source and destination are the network subnet - `-s $SUBNET -d $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN`
2. Accept traffic from whitelisted containers destined for the network subnet (this requires one rule per container) - `-s "$IP" -d "$SUBNET" -j RETURN`
3. Drop traffic whose source and destination are the network subnet - `-s "$SUBNET" -d "$SUBNET" -j DROP`

For Docker Swarm, another rule is added in the **2.** position allowing traffic from the overlay network's load balancers

Additionally, a jump rule is added from the `INPUT` chain to the `TRAEFIKJAM_INPUT` chain. Two rules are added here:
1. Accept already-established traffic whose source is the network subnet - `-s $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN`
2. Drop traffic whose source is the network subnet - `-s "$SUBNET" -j DROP`

## Dependencies
* Linux with iptables whose version matches the iptables in TraefikJam (currently `1.8.4 (legacy)`)
* Docker >20.10.0
