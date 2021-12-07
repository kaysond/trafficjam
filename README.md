# TrafficJam (Beta)
A Docker firewall for your reverse proxy network

[![Build - Latest](https://github.com/kaysond/trafficjam/actions/workflows/build-latest.yml/badge.svg)](https://github.com/kaysond/trafficjam/actions/workflows/build-latest.yml) [![CI - Latest](https://github.com/kaysond/trafficjam/actions/workflows/ci-latest.yml/badge.svg)](https://github.com/kaysond/trafficjam/actions/workflows/ci-latest.yml) [![Build - Nightly](https://github.com/kaysond/trafficjam/actions/workflows/build-nightly.yml/badge.svg)](https://github.com/kaysond/trafficjam/actions/workflows/build-nightly.yml) [![CI - Nightly](https://github.com/kaysond/trafficjam/actions/workflows/ci-nightly.yml/badge.svg)](https://github.com/kaysond/trafficjam/actions/workflows/ci-nightly.yml)

## Threat Model
**Why do you need something like TrafficJam?** Reverse proxies are often used to authenticate external access to internal services, providing benefits such as centralized user management, access control, 2FA and SSO. In a typical Docker setup, multiple services are connected to the reverse proxy via a single network. If a user authenticates to one service and is able to compromise that service (such as by using [this Pi-Hole vulnerability](https://natedotred.wordpress.com/2020/03/28/cve-2020-8816-pi-hole-remote-code-execution/ "this Pi-Hole vulnerability")), that user will gain access to the entire network *behind* the reverse proxy, and can access every service on the network whether they would normally have permission or not.

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

## What TrafficJam Does
TrafficJam allows you to safely and easily connect all of your backend containers to your reverse proxy using a single docker network by preventing the backend containers from communicating with each other.

![TrafficJam](./trafficjam-diagram.png)

## How TrafficJam Works
TrafficJam works by adding some firewall (`iptables`) rules to the docker network you specify. First, it blocks all traffic on the network. Then it adds a rule that only allows traffic to/from the container(s) you specify in the whitelist. It continually monitors the docker network to make sure the rules stay up to date as you add or remove containers.

## Setup Examples

### Vanilla Docker
`docker-cli`:
```
docker run \
  --name trafficjam \
  --cap-add NET_ADMIN \
  --network host \
  --volume "/var/run/docker.sock:/var/run/docker.sock" \
  --env NETWORK=traefik_public \
  --env WHITELIST_FILTER="ancestor=traefik:latest" \
  --env TZ="America/Los_Angeles" \
  --detach \
  kaysond/trafficjam
```

`docker-compose.yml`:
```
version: '3.8'
services:
  trafficjam:
    container_name: trafficjam
    image: kaysond/trafficjam
    cap_add:
      - NET_ADMIN
    network_mode: host
    volumes:
     - /var/run/docker.sock:/var/run/docker.sock
    environment:
      NETWORK: traefik_public
      WHITELIST_FILTER: ancestor=traefik:latest
      TZ: America/Los_Angeles

  traefik:
    container_name: traefik
    image: traefik:latest
    networks:
      traefik_public:

  whoami:
    container_name: whoami
    image: traefik/whoami
    networks:
      traefik_public:

networks:
  traefik_public:
```

### Docker Swarm
`docker-cli`:
```
docker service create \
  --name trafficjam \
  --mount type=bind,source=/var/run/docker.sock,destination=/var/run/docker.sock \
  --env NETWORK=traefik_public \
  --env WHITELIST_FILTER=ancestor=traefik:v2.3.7@sha256:0aca29bb8e51aa69569b15b8b7f08328e6957cbec201dd532304b3329e5a82a9 \
  --env SWARM_DAEMON=true \
  --env TZ=America/Los_Angeles \
  --replicas 1 \
  --constraint node.role==manager \
  kaysond/trafficjam
```

`docker-compose.yml`:
```
version: '3.8'

services:
  trafficjam:
    image: trafficjam
    volumes:
     - /var/run/docker.sock:/var/run/docker.sock
    environment:
      NETWORK: traefik_network
      WHITELIST_FILTER: ancestor=traefik:v2.3.7@sha256:0aca29bb8e51aa69569b15b8b7f08328e6957cbec201dd532304b3329e5a82a9
      SWARM_DAEMON: "true"
      TZ: America/Los_Angeles
    deploy:
      replicas: 1
      placement:
        constraints: ['node.role==manager']
```

**Notes:** 
Docker Swarm services tag images with a sha256 hash to guarantee that every node runs the exact same container (since tags are mutable). When using the `ancestor` tag, ensure that the appropriate hash is included as shown in the examples.

`trafficjam` requires the `NET_ADMIN` Linux capability in order to manipulate `iptables` rules. For Docker Swarm setups, `SYS_ADMIN` is also required in order to enter namespaces, though the setting of container capabilities is automatically handled by the `trafficjam` swarm daemon.

## Configuration
TrafficJam is configured via several environment variables:
* **NETWORK** - The name of the Docker network this instance of TrafficJam should manage (multiple instances can be run for different networks)
* **WHITELIST_FILTER** - A Docker `--filter` parameter that designates which containers should be permitted to openly access the network. See [Docker Docs - filtering](https://docs.docker.com/engine/reference/commandline/ps/#filtering)
* **TZ** - Timezone (for logging)
* **SWARM_DAEMON** - Setting this variable is required for swarm and activates a daemon that determines network load balancer IP addresses and properly configures the trafficjam service
* **SWARM_IMAGE** - The image the trafficjam swarm daemon should deploy (defaults to `kaysond/trafficjam`). The best practice is to pin this to a particular image hash (e.g. `kaysond/trafficjam:v1.0.0@sha256:8d41599fa564e058f7eb396016e229402730841fa43994124a8fb3a14f1a9122`)
* **POLL_INTERVAL** - How often TrafficJam checks Docker for changes
* **ALLOW_HOST_TRAFFIC** - Allow containers to initiate communication with the docker host, and thus any port-mapped containers. Most users do not need this setting enabled. (See [ARCHITECTURE.md](ARCHITECTURE.md)). Note that if this setting is enabled while old rules exist, some will not be cleared automatically and must be done so manually (See [Clearing Rules](#clearing-rules)).
* **DEBUG** - Setting this variable turns on debug logging

## Dependencies
* Linux with iptables whose version is compatible with the iptables in TrafficJam (currently `1.8.7 (legacy)` or `1.8.7 (nf_tables)`)
* Docker >20.10.0

## Clearing Rules
`trafficjam` can be run with the `--clear` argument to remove all rules that have been set. Note that the `NETWORK` and `WHITELIST_FILTER` environment variables must be set appropriately so `trafficjam` can remove the correct rules, and the host docker socket must be mounted within the container.

Example:
```
  docker run \
    --env NETWORK=network_name \
    --env WHITELIST_FILTER=ancestor=container_name \
    --volume "/var/run/docker.sock:/var/run/docker.sock" \
    --cap-add NET_ADMIN \
    --network host \
    kaysond/trafficjam --clear
```