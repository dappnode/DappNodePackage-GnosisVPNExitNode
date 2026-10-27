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
  `network_mode` and `networks` together on the same service). Since `hoprd`'s
  `session_ip_forwarding` needs a literal `ip:port` (hostnames are rejected by hoprd's own
  config parser) and a non-core package can't pin a static IP on `dncore_network` either (see
  below), `node`'s `entrypoint.sh` resolves `gnosisvpn-server`'s DAppNode DNS alias
  (`gnosisvpn-server.<dnpName>.dappnode`) to its current IP at boot and renders that into
  `hoprd.cfg.yaml.tpl` before `hoprd` starts (see `GNOSISVPN_SERVER_HOST` in
  `docker-compose.yml`). Unlike the loopback address this replaced, this IP is **not** fixed
  across installs, and isn't guaranteed stable across a `gnosisvpn-server` recreate - see
  "Known limitations" below.

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
- The appliance's FireHOL blocklist and per-peer traffic shaping. They aren't about local
  access.

`just test-firewall` and `just test-firewall-image` check these rules (see
[`test/README.md`](test/README.md)).

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
something this package structurally can't do). Worse, unlike a first attempt at working
around this (sharing `node`'s network namespace to get a fixed loopback address - see git
history), the address DAppNode assigns `gnosisvpn-server` on `dncore_network` is **not fixed
across installs either**: it's a normal dynamic bridge IP, different on every install and not
guaranteed stable across a `gnosisvpn-server` recreate on the same install (though it survives
an ordinary restart). `entrypoint.sh` logs it on every `node` boot
(`gnosisvpn-server resolved to ...`), so it's discoverable per-install from DAppNode's log
viewer, but there's currently no single documented value a `gnosis_vpn-client` can be
pre-configured with the way `172.30.0.1` works for the production fleet - a client would need
to be told this specific exit node's current address out of band. The proper fix is upstream,
in `hoprd`: an in-progress change to have `hoprd` inform a connecting client of the correct
target itself, so clients don't need this hardcoded at all. Until that lands, this is a real
gap for this package's exit nodes specifically.

## Local testing

See [`test/README.md`](test/README.md) - `just local-up`/`local-down` runs the real
docker-compose stack outside DAppNode, and `just validate-config` checks `hoprd.cfg.yaml.tpl`
against the real hoprd binary's config parser.

## Building the package

See [`DEVELOPING.md`](DEVELOPING.md).
