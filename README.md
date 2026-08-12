# GnosisVPN Exit Node - DAppNode Package

Runs a [GnosisVPN](https://vpn.gnosis.eth.limo) exit node on DAppNode: a HOPR node that sends client traffic through the HOPR mixnet, paired with `gnosis_vpn-server`, which terminates that traffic on a local WireGuard interface and forwards it to the internet.

## Services

- **`node`** - Relays HOPR mixnet traffic and forwards GnosisVPN Session traffic to `gnosisvpn-server`.
- **`gnosisvpn-server`** - runs [`gnosis_vpn-server`](https://github.com/gnosis/gnosis_vpn-server), which manages a
  real WireGuard interface (`wggvpn`) and terminates/forwards client traffic to the internet. `gnosisvpn-server` runs as an ordinary container with just `cap_add: NET_ADMIN`. That's
  still enough to create a real kernel WireGuard interface and manage it via `wg-quick`
  (`--sync-wg-interface`) - verified directly. It shares `node`'s network namespace
  (`network_mode: "service:node"`) rather than getting its own: `hoprd`'s
  `session_ip_forwarding` needs a literal, stable `ip:port` for `gnosisvpn-server`, and a
  non-core DAppNode package can't pin it a static IP on a custom docker network (see below),
  so instead it's reached over loopback (`127.0.0.1` - see `hoprd.cfg.yaml`), which is stable
  by construction.

## Known limitations vs. production

A regular (non-core) DAppNode package can't get `network_mode: host` or a custom docker
network with a pinned subnet (DAppNode's SDK validates this: non-`dncore_network` names in a
compose file's `networks:` are rejected outright), so `gnosisvpn-server` never reaches the
DAppNode host's own network namespace, only `node`'s (see above). That rules out explicit
host firewall exceptions: a host-level deployment punches two rules through the host's
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

For the same reason, this exit node's internal `gnosisvpn-server` address (`127.0.0.1`) is
**not** the `172.30.0.1` a production, Ansible-managed exit node presents (a fixed docker
bridge gateway, identical across that whole fleet because every host pins the same subnet -
something this package structurally can't do). A `gnosis_vpn-client` connecting to *this*
exit node needs its `[connection.bridge]`/`[connection.wg]` `target` overridden to
`127.0.0.1:8000`/`127.0.0.1:51820` accordingly; since that's a single global client setting
(not per-destination), a client configured that way can no longer also reach a standard
`172.30.0.1`-convention exit node without changing it back.

## Local testing

See [`test/README.md`](test/README.md) - `just local-up`/`local-down` runs the real
docker-compose stack outside DAppNode, and `just validate-config` checks `hoprd.cfg.yaml`
against the real hoprd binary's config parser.

## Building the package

See [`DEVELOPING.md`](DEVELOPING.md).
