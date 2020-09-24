# TraefikJam (ALPHA) [![Build Status](https://travis-ci.com/kaysond/traefikjam.svg?branch=master)](https://travis-ci.com/kaysond/traefikjam)
A Docker firewall for your reverse proxy network

## Threat Model
**Why do you need something like TraefikJam?** Reverse proxies are often used to authenticate external access to internal services, providing benefits such as access control, 2FA and SSO. In a typical Docker setup, multiple services are connected to the reverse proxy via a single network. If a user authenticates to one service and is able to compromise that service (such as by using [this Pi-Hole vulnerability](http://https://natedotred.wordpress.com/2020/03/28/cve-2020-8816-pi-hole-remote-code-execution/ "this Pi-Hole vulnerability")), that user will gain access to the entire network *behind* the reverse proxy, and can access every service on the network whether they would normally have permission or not.

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
  

## Tested Environments
* Ubuntu (20.04) + Docker (19.03.13)

## Setup
```
docker run -d --name traefikjam --cap-add NET_ADMIN --network host \
	-v "/var/run/docker.sock:/var/run/docker.sock"
	-e POLL_INTERVAL=5 \
	-e NETWORK=traefik_network \
	-e WHITELIST_FILTERS="ancestor=traefik:latest" \
	kaysond/traefikjam
```