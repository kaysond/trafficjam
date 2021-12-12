# Architecture
[`trafficjam.sh`](trafficjam.sh) is the main script that sets up configuration and runs commands in a loop. It is a series of well-named function calls so that it is easy to read an understand, improving security. All of the functions are defined in [`trafficjam-functions.sh`](trafficjam-functions.sh). If any function fails, it calls `log_error` which prints a message to stderr and increments an error counter, then returns 1. The calls are all appended with `|| continue` so the loop restarts if any function fails. `tj_sleep` sets the loop interval, and will slow itself down as the error counter increases (successfully completed loops reset the counter).

## Principal of Operation
TrafficJam limits traffic between containers by adding the necessary iptables rules on the host. When Docker Swarm is in use, TrafficJam acts as a daemon that spawns a global mode service so that the rules are added to the correct network namespace on each host. This daemon-service method is also required because Docker Swarm employs a separate load balancer on each node whose IP address must be permitted to communicate to the subnet. Since each node (even a manager) is only aware of its own load balancer's IP address, the daemon must start the service, collect the reported load balancer IP addresses of all nodes, then update the service.

First, TrafficJam queries the docker daemon to determine the specified network's subnet and the ID's of whitelisted containers. If Docker Swarm is in use, TrafficJam also determines the correct network namespace and load balancer IP on the host.

TrafficJam then adds its own chain in the `filter` table called `TRAFFICJAM`. It also adds a jump rule to the `DOCKER-USER` chain (or `FORWARD` for Docker Swarm) to jump to this chain: `iptables --table filter --insert <chain> --jump TRAFFICJAM`

Then, TrafficJam inserts several rules to the `TRAFFICJAM` chain in the `filter` table which are ultimately evaluated top to bottom:
1. Accept already-established traffic whose source and destination are the network subnet - `iptables --table filter --insert TRAFFICJAM --source $SUBNET --destination $SUBNET --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN`
2. Accept traffic from whitelisted containers destined for the network subnet (this requires one rule per container) - `iptables --table filter --insert TRAFFICJAM --source "$IP" --destination "$SUBNET" --jump RETURN`
3. (Docker Swarm only) Accept traffic from all load balancers (this requires one rule per node) - `iptables --table filter --insert TRAFFICJAM --source "$LOAD_BALANCER_IP" --destination "$SUBNET" --jump RETURN`
4. Drop traffic whose source and destination are the network subnet - `iptables --table filter --insert TRAFFICJAM --source "$SUBNET" --destination "$SUBNET" --jump DROP`
(Note that the script inserts the rules in reverse order since they're inserted to the top of the chain)

Thus all traffic on the relevant subnet hits the `DROP` on Rule 4 except traffic initiated by the whitelisted containers (usually the reverse proxy).

This alone is not sufficient to prevent inter-container communication, however. If a container has a port mapped to the host, other containers are still able to access it via the host ip address and the mapped port. This is because Rule 4 above only drops traffic within the subnet, not traffic to the outside, to allow containers to have internet access.

This is blocked by another chain and set of rules. First, TrafficJam adds another chain in the `filter` table: `TRAFFICJAM_INPUT`. Then it adds a jump rule to the `INPUT` chain: `iptables --table filter --insert input --jump TRAFFICJAM_INPUT`. The `INPUT` chain is used here because the incoming packet is destined for an IP address assigned to the host and does not need to be forwarded.

TrafficJam adds two rules to this new chain, again shown in final order:
1. Accept already-established traffic whose source is the network subnet - `iptables --table filter --insert TRAFFICJAM_INPUT --source $SUBNET --match conntrack --ctstate RELATED,ESTABLISHED --jump RETURN`
2. Drop traffic whose source is the network subnet - `iptables --table filter --insert TRAFFICJAM_INPUT --source "$SUBNET" --jump DROP`

## Testing
The test suite uses `bats` for automation. In order to avoid issues with iptables verison mismatches, docker-in-docker is used to test `trafficjam` inside a container. This also facilitates docker swarm testing, by utilizing two test containers connected to a docker network. The test container (`trafficjam_test`) checks which version of `iptables` it should use, launches the docker daemon, then builds the necessary images.

In the CI runner, `bats` is used to build the test image, deploy it, then run another `bats` test inside the container itself. The internal `bats` test (e.g. `test-dind.bats`) then deploys `trafficjam` and some `whoami` containers on the containerized docker host waits for rules to be created, then checks for connectivity to be present and absent where appropriate.

There are three iterations of this procedure: one to check vanilla docker with legacy `iptables` one to check vanilla docker with `nftables`, and another to check docker swarm (with legacy `iptables`).