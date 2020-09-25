# TraefikJam (ALPHA) [![Build Status](https://travis-ci.com/kaysond/traefikjam.svg?branch=master)](https://travis-ci.com/kaysond/traefikjam)
A Docker firewall for your reverse proxy network

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
  * Every service only needs connection to one network :)

## Configuration
TraefikJam is configured via several environment variables:
* **TZ** - Timezone (for logging)
* **POLL_INTERVAL** - How often TraefikJam checks Docker for changes
* **NETWORK** - The name of the Docker network this instance of TraefikJam should manage
* **WHITELIST_FILTER** - A Docker `--filter` parameter that designates which containers should be permitted to openly access the network. See [Docker Docs - filtering](https://docs.docker.com/engine/reference/commandline/ps/#filtering)
* **DEBUG** - Turns on debug logging

## Setup Examples

### Vanilla Docker
`docker-cli`:
```
docker run -d --name traefikjam --cap-add NET_ADMIN --network host \
	-v "/var/run/docker.sock:/var/run/docker.sock" \
	-e TZ=America/Los_Angeles \
	-e POLL_INTERVAL=5 \
	-e NETWORK=traefik_network \
	-e WHITELIST_FILTER="ancestor=traefik:latest" \
	kaysond/traefikjam
```

`docker-compose.yml`:
```
version: "3.3"
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
      NETWORK: traefik_network
      WHITELIST_FILTER: ancestor=traefik:latest

  traefik:
    container_name: traefik
    image: traefik:latest
    networks:
      traefik_network:

  example_service:
    container_name: whoami2
    image: jwilder/whoami
    ports:
      - "8000:8000"
    networks:
      traefik_network:

networks:
  traefik_network:
```

### Docker Swarm
`docker-cli`:
```

```

`docker-compose.yml`:
```

```

## Operation
TraefikJam limits traffic between containers by adding rules to the host iptables. The Docker network subnet and the IP addresses of whitelisted containers are determined. Then, several rules are added to a TRAEFIKJAM chain in the filter table:
1. Accept already-established traffic whose source and destination are the network subnet - `-s $SUBNET -d $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN`
2. Accept traffic from whitelisted containers destined for the network subnet (this requires one rule per container) - `-s "$IP" -d "$SUBNET" -j RETURN`
3. Drop traffic whose source and destination are the network subnet - `-s "$SUBNET" -d "$SUBNET" -j DROP`

For Docker Swarm, another rule is added in the **2.** position allowing traffic from the load balancer

## Tested Environments
* Ubuntu (20.04) + Docker (19.03.13)