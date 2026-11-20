# GnosisVPN Exit Node - DAppNode Package

Runs a [GnosisVPN](https://vpn.gnosis.eth.limo) exit node on DAppNode: a HOPR node that sends client traffic through the HOPR mixnet, paired with `gnosis_vpn-server`, which terminates that traffic on a local WireGuard interface and forwards it to the internet.

## Services

- **`node`** - Relays HOPR mixnet traffic and forwards GnosisVPN Session traffic to `gnosisvpn-server`.
- **`gnosisvpn-server`** - runs [`gnosis_vpn-server`](https://github.com/gnosis/gnosis_vpn-server), which manages a
  real WireGuard interface (`wggvpn`) and terminates/forwards client traffic to the internet. `gnosisvpn-server` runs as an ordinary container with just `cap_add: NET_ADMIN`. That's
  still enough to create a real kernel WireGuard interface and manage it via `wg-quick`
  (`--sync-wg-interface`) - verified directly. It runs as a normal DAppNode service, on the
  same `dncore_network` every DAppNode package service gets attached to (a non-core package
  can't get `network_mode: "service:node"` here either - DAppNode's `dappmanager` forces that
  `networks:` attachment onto every service regardless, and Docker Compose rejects
  `network_mode` and `networks` together on the same service). `node` reaches it at
  **`172.33.255.254`** (`:51820` WireGuard, `:8000` control API) - see "Fixed address".

## Fixed address

`gnosisvpn-server`'s address is `172.33.255.254` on every install and across recreates.

DAppNode doesn't let a package pin a container IP: `dappmanager` strips `ipv4_address` and
only allows its own networks. So
[`gvpn-fixed-address.sh`](gnosisvpn-server/gvpn-fixed-address.sh) adds the address to
`gnosisvpn-server`'s `dncore_network` interface itself. It is inside `dncore_network`'s
`172.33.0.0/16`, so `node` reaches it directly. The script:

- refuses the address if anything else already answers for it,
- announces it, so `node` stops using a previous container's MAC,
- claims it again within 30s if a network reconnect drops it.

Limits: Docker doesn't know about the address, but it hands out the lowest free one first, so
it only reaches `172.33.255.254` on a nearly full network. If DAppNode retires
`dncore_network`, the address must move to `dnprivate_network` (`10.20.0.0/24`).

## Firewall

`gnosisvpn-server` has its own network namespace, and
[`gnosisvpn-server/wg-hooks.sh`](gnosisvpn-server/wg-hooks.sh) sets its forwarding policy.
`wg-quick` runs the script from `PostUp`/`PreDown` in `wggvpn.conf`. It is a port of the
`wg-hooks.sh` + `iptables.rules` pair from the exit-node appliance image (`gnosis_vpn-exit_os`).
The appliance version can't be used as-is, because a DAppNode package never sees the host's
network namespace (see "Known limitations" below).

VPN clients are untrusted. Without the firewall, their traffic can reach the DAppNode host, the
dappmanager, every package on `dncore_network` and the LAN behind the host. With it, only
public destinations are reachable:

- FORWARD policy is DROP. Client traffic goes through `GVPN_PRIVATE` first, which drops:
  - RFC1918, CGNAT, link-local, loopback, `0.0.0.0/8` and multicast/reserved
  - `dncore_network` (`172.33.0.0/16`), which is not in RFC1918
  - the subnet this container is attached to
- Only `wggvpn -> <uplink>` is accepted. Return traffic is `RELATED,ESTABLISHED` only, so the
  exit node can't open connections to clients.
- INPUT from `wggvpn` accepts only the ICMP echo that the GnosisVPN client sends to check the
  tunnel (`connection.ping`, default `10.128.0.1`). The control API on port 8000 and all other
  local services are not reachable from the tunnel.
- `up` removes its old rules first, so a restart doesn't add duplicates. `down` leaves FORWARD
  at DROP.
- `entrypoint.sh` sets FORWARD to DROP before it starts `gnosis_vpn-server`. `wg-quick` brings
  `wggvpn` up before `PostUp` runs the hook, so this closes that gap.

Not covered:

- IPv6. `gnosis_vpn-server` adds peers with IPv4 `allowed-ips` only and `wggvpn` has no IPv6
  address, so WireGuard drops IPv6 client packets. The appliance also drops IPv6 with
  `ip6tables`; this package does not. Re-check this when `gnosis_vpn-server` gets IPv6 support
  ([gnosis/gnosis_vpn-client#330](https://github.com/gnosis/gnosis_vpn-client/issues/330)).
- The DAppNode's own public IPv4 address. It is a public destination, so it passes. (The
  appliance finds and blocks it with an external HTTPS lookup; this package doesn't.) What a
  client reaches there depends on where the address lives:
  - On the host's NIC (a VPS, or a public IP from the ISP): every service the host listens on
    and every published port, e.g. SSH and the hoprd API on `3001`. Don't run this package on
    such a host unless the host firewall restricts those services by source.
  - On a router in front of the host: whatever the router hairpins back, e.g. its admin UI if
    it listens on WAN, and every forwarded port. Assume NAT loopback is on.
`just test-firewall` and `just test-firewall-image` check these rules (see
[`test/README.md`](test/README.md)).

## Blocklist

[`gnosisvpn-server/gvpn-blocklist-update.sh`](gnosisvpn-server/gvpn-blocklist-update.sh) fills
the `gvpn-blocklist` ipset, and `wg-hooks.sh` drops traffic to it, and traffic from it back to
clients, before the client ACCEPT. Ported from the appliance, which uses the same FireHOL level1
feed:

- `entrypoint.sh` loads the cached list before it starts the server, so the last known-good list
  filters the first forwarded packet. The cache lives in the `gnosisvpn-data` volume.
- It then runs the refresher as a child process. A container has no timer, so the appliance's
  twice-daily systemd timer becomes "refresh now, then every 12 h plus up to 1 h of jitter".
- A refresh swaps the whole set in atomically (`ipset swap`), so forwarding never sees a
  half-built list.
- It fails open. An unreachable feed, or one that parses to fewer than 1000 or more than 131072
  entries, leaves the previous list in place and logs why. A poisoned `0.0.0.0/1` can't
  blackhole every session, because prefixes shorter than /8 are only accepted for the 224/3
  bogon range.
- IPv4 only, like the isolation rules - see "Not covered" above for why client IPv6 never
  reaches the tunnel.

Feeds are configured from the DAppNode UI, see "Settings in the DAppNode UI" below.

## Per-peer shaping

[`gnosisvpn-server/gvpn-peer-shaping.sh`](gnosisvpn-server/gvpn-peer-shaping.sh) builds an HTB
tree on `wggvpn` when `wg-hooks.sh` runs, with one class per peer slot:

- Download (server to client) is classified by destination address on `wggvpn` egress.
- Upload (client to internet) is mirrored from `wggvpn` ingress onto an `ifb-gvpn` device and
  classified there by source address. It has to happen on the `wggvpn` side: the uplink only
  ever sees post-MASQUERADE addresses.
- Each peer is capped at `GVPN_PEER_RATE_KBIT` (default 10000) and all peers together at
  `GVPN_PEER_SHAPING_AGGREGATE_KBIT` (default 25000). It queues rather than drops, so TCP
  settles at the cap instead of sawtoothing, and fq_codel signals with delay before loss
  because a dropped packet costs an end-to-end retransmit across the mixnet.
- `entrypoint.sh` derives the peer range from `WIREGUARD_CIDR` and `MAX_SLOTS`, the same way it
  derives the pool for `config.toml`, and exports it for the `wg-quick` process that runs the
  hook.
- Unlike the appliance, a shaping failure does not stop the exit node. `tc` and the `ifb`/`sch_*`
  modules come from the DAppNode host's kernel, and this container can't load modules into it. A
  host without them serves unshaped and logs `per-peer shaping failed` on every interface sync.

`just test-traffic` and `just test-traffic-image` check both of these (see
[`test/README.md`](test/README.md)).

## Settings in the DAppNode UI

The exit node's limits and blocklist are optional fields in the package's setup wizard, so they
are set in the DAppNode UI (the package's **Config**, or the wizard on install) rather than by
editing `docker-compose.yml`. Leaving a field empty keeps the default:

| UI field | Variable | Default |
|---|---|---|
| Per-client bandwidth limit | `GVPN_PEER_RATE_KBIT` | `10000` kbit/s |
| Total bandwidth limit for all clients | `GVPN_PEER_SHAPING_AGGREGATE_KBIT` | `25000` kbit/s |
| Blocklist feeds | `GVPN_BLOCKLIST_FEEDS` | FireHOL level1 |
| Blocklist refresh interval | `GVPN_BLOCKLIST_REFRESH_INTERVAL_S` | `43200` s |
| WireGuard client subnet | `WIREGUARD_CIDR` | `10.128.0.0/24` |
| Maximum connected peers | `MAX_SLOTS` | `4` |

Feed URLs are space-separated; one per line works too. The rest of the `GVPN_BLOCKLIST_*`
variables (minimum entries, download timeout, jitter) stay environment-only, with the
appliance's defaults.

## Known limitations vs. production

A regular (non-core) DAppNode package can't get `network_mode: host` or a custom docker
network with a pinned subnet (DAppNode's SDK validates this: non-`dncore_network` names in a
compose file's `networks:` are rejected outright), so `gnosisvpn-server` never reaches the
DAppNode host's own network namespace, only its own container namespace on `dncore_network`
(see above). That rules out explicit host firewall exceptions: a host-level deployment
punches two rules through the host's
`DOCKER-USER` iptables chain - one accepting `wggvpn -> <public NIC>` traffic, and one
accepting the return leg (`<public NIC> -> wggvpn`) but only for `RELATED,ESTABLISHED`
connections, deliberately not `NEW`, so the exit node can't be used to originate unsolicited
inbound connections into WireGuard clients. `DOCKER-USER` is created once by `dockerd` in the
host's own default network namespace, so it doesn't exist inside this package's namespace at
all - there's nothing to add those rules to here.

This isn't actually a gap in practice: `gnosisvpn-server` publishes no ports of its own (see
`docker-compose.yml`), so nothing on the public internet has a route to send fresh inbound
packets to it in the first place. The same effect - only established/related traffic ever
reaches `wggvpn` - is achieved structurally, by not being reachable, rather than by an
explicit firewall rule.

For the same reason, this exit node's internal `gnosisvpn-server` address is **not** the
fixed `172.30.0.1` a production, Ansible-managed exit node presents (a fixed docker bridge
gateway, identical across that whole fleet because every host pins the same subnet -
something this package structurally can't do). It is `172.33.255.254` instead, so a
`gnosis_vpn-client` needs its `[connection.bridge]`/`[connection.wg]` `target` set to
`172.33.255.254:8000`/`172.33.255.254:51820`. That setting is global to the client. The proper
fix is upstream: `hoprd` telling a connecting client the target itself.

## Local testing

See [`test/README.md`](test/README.md) - `just local-up`/`local-down` runs the real
docker-compose stack outside DAppNode, and `just validate-config` checks `hoprd.cfg.yaml.tpl`
against the real hoprd binary's config parser.

## Building the package

See [`DEVELOPING.md`](DEVELOPING.md).
