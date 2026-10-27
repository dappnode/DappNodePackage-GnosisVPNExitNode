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

`gnosisvpn-server` runs in its own network namespace, so that namespace is where the exit
node's forwarding policy lives: [`gnosisvpn-server/wg-hooks.sh`](gnosisvpn-server/wg-hooks.sh),
run by `wg-quick`'s `PostUp`/`PreDown` (rendered into `wggvpn.conf` by `entrypoint.sh`). It
ports the `wg-hooks.sh` + `iptables.rules` pair from the exit-node appliance image
(`gnosis_vpn-exit_os`), which can't be reused as-is because a DAppNode package never sees the
host's network namespace (see below).

Without it, a VPN client's traffic is masqueraded to this container's address and then takes
the same path as the container's own egress traffic: to the DAppNode host, to the dappmanager,
to every other package on `dncore_network`, and to the LAN behind the host. A VPN client is an
untrusted third party, so only publicly addressed destinations are allowed through:

- FORWARD policy is DROP, and client traffic jumps to `GVPN_PRIVATE` before any rule can
  accept it. That chain drops RFC1918, CGNAT, link-local, loopback, `0.0.0.0/8`,
  multicast/reserved, DAppNode's `dncore_network` (`172.33.0.0/16` - deliberately *not* in
  RFC1918, so the RFC1918 entries alone would leave the dappmanager reachable) and the subnet
  this container is attached to, whatever DAppNode assigns it. Only `wggvpn -> <uplink>` is
  accepted, and only behind that jump; the return leg is `RELATED,ESTABLISHED` only, so the
  exit node can't originate inbound connections into WireGuard clients.
- Traffic from `wggvpn` reaches INPUT for one packet only: the ICMP echo the GnosisVPN client
  sends to the WireGuard server address to verify the tunnel (`connection.ping`, default
  `10.128.0.1`). Everything else from the tunnel is dropped, so a VPN client can't reach the
  control API on port 8000 or anything else this container listens on.
- `up` removes its own rules first, so restarting the interface never stacks duplicates, and
  `down` leaves FORWARD at DROP, so a hook that failed half way can't leave the namespace open.

Not covered, matching the appliance:

- IPv6. `gnosis_vpn-server` adds every peer as `allowed-ips <ipv4>/32` (its `add_peer` takes
  an `Ipv4Addr`) and `wggvpn` has only an IPv4 address, so WireGuard's own cryptokey routing
  drops an IPv6 packet from a client before this namespace sees it. The appliance also drops
  IPv6 in `ip6tables` as a second line of defence; here the guarantee is that upstream
  configuration, so it is worth re-checking when `gnosis_vpn-server` gains IPv6 support
  ([gnosis/gnosis_vpn-client#330](https://github.com/gnosis/gnosis_vpn-client/issues/330)).
- The host's own public IPv4 address (the router's WAN address). The appliance drops it from
  an ipset it fills with HTTPS-observed addresses, so a client can't reach the router, or a
  LAN host hairpinned through it, via that address. Porting that would mean the same external
  lookup from inside the container, so it isn't: a packet to the WAN address is a public
  destination, passes the ranges above, and is stopped only if the router refuses to hairpin
  it. The host's *private* addresses are covered above; its WAN address is not.
- The FireHOL blocklist and the per-peer traffic shaping the appliance adds. They aren't
  about reaching local resources, so they aren't ported.

`just test-firewall` checks the rules themselves, including that a client behind `wggvpn`
still reaches public destinations and the tunnel-verification ping (see
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
