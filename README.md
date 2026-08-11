# GnosisVPN Exit Node - DAppNode Package

Runs a [GnosisVPN](https://www.gnosisvpn.com/) exit node on DAppNode: a HOPR node (`hoprd`
4.0.3) that relays client traffic through the HOPR mixnet, paired with `gnosis_vpn-server`,
which terminates that traffic on a local WireGuard interface and forwards it to the internet.

This is derived from [DAppNodePackage-Hopr](https://github.com/dappnode/DAppNodePackage-Hopr)
(hoprd 3.0 + hopr-admin) and the
[gnosis_vpn-infrastructure](https://github.com/gnosis/gnosis_vpn-infrastructure) Ansible
roles (`gnosisvpn-hoprd`, `gnosisvpn-server`) that provision HOPR Association's own
GnosisVPN exit-node fleet - see below for what's the same, what's different, and why.

## Services

- **`node`** - hoprd 4.0.3. Same role as in the upstream Hopr package: relays HOPR mixnet
  traffic and forwards GnosisVPN Session traffic to `gnosisvpn-server`.
- **`gnosisvpn-server`** - runs
  [`gnosis_vpn-server`](https://github.com/gnosis/gnosis_vpn-server) 0.4.2, which manages a
  real WireGuard interface (`wggvpn`) and terminates/forwards client traffic to the internet.

There's no admin UI service in this first iteration - just the two services that do the
actual work.

## Why `gnosisvpn-server` doesn't run like the Ansible role does

The `gnosisvpn-server` Ansible role runs on bare metal with `network_mode: host`-equivalent
access: it manages the real host's WireGuard interface, `iptables -I DOCKER-USER ...` rules
against the host's own Docker-managed chain, and `tc` shaping on the host's public NIC. The
first draft of this package tried to mirror that as closely as possible by actually using
`network_mode: host` plus a custom docker network with a pinned IP for `gnosisvpn-server`, so
`hoprd.cfg.yaml`'s `session_ip_forwarding` (which requires a literal `ip:port` - hostnames are
rejected by hoprd's own config parser) could point at a known address.

Running that through the actual DAppNode SDK validator (`npx @dappnode/dappnodesdk build`)
disproved that plan: **`network_mode: host`, custom docker networks, and bind-mounted volumes
are all restricted to DAppNode core/system packages** (`validateDappnodeCompose` in
`@dappnode/schemas` - checked directly in `node_modules` while building this). None of that is
available to a regular package like this one, no matter how it's structured. So:

- `gnosisvpn-server` runs as an ordinary container with just `cap_add: NET_ADMIN`. That's
  still enough to create a real kernel WireGuard interface and manage it via `wg-quick`
  (`--sync-wg-interface`) **inside its own network namespace** - verified directly. What's
  not available inside that namespace is the host's `DOCKER-USER` chain (it doesn't exist
  there at all) or the host's actual public NIC, so `wggvpn.conf`'s `PostUp`/`PreDown` only
  keep the `MASQUERADE` rule (targeting the container's own `eth0`) and drop the
  `DOCKER-USER`-chain ACCEPT/blocklist rules entirely - they'd either error or be no-ops.
  Docker's own host-level NAT then carries WireGuard client traffic the rest of the way to
  the internet, the same way it already does for any container's ordinary egress traffic.
- No custom network means no way to pin `gnosisvpn-server` to a known IP for
  `hoprd.cfg.yaml` to reference statically. Instead, `node`'s `entrypoint.sh` resolves
  `gnosisvpn-server`'s container IP via DNS **at every startup** and renders the real
  `hoprd.cfg.yaml` from a template (`hoprd.cfg.yaml.tpl`) with that address substituted in -
  self-healing across container recreation, which would otherwise change the IP.
- Neither `51820/udp` (WireGuard) nor `8000/tcp` (gnosis_vpn-server's control endpoint) are
  exposed to the internet - by design, independent of the above. GnosisVPN's whole point is
  that client traffic reaches this node's WireGuard interface *through* the HOPR mixnet
  (`hoprd`'s Session forwarding), not by dialing the WireGuard port directly. Only `hoprd`'s
  own p2p port (9091, same as today) needs to be internet-reachable.
- The host's kernel needs to already support WireGuard (built-in, standard on any kernel
  ≥5.6, or the module already loaded system-wide) - this package can't load it itself
  (`SYS_MODULE` would be meaningless without a bind-mounted `/lib/modules`, which isn't
  available either).

## What's different from hoprd 4.0.3 vs. 3.0

Verified directly against the real `hoprd:4.0.3` image (not assumed from docs, which still
describe the 3.0 CLI in places): identity/data-dir/API/announce/safe-module concerns all
moved out of the YAML config file and into CLI flags/env vars (`HOPRD_IDENTITY`, `HOPRD_DATA`,
`HOPRD_API`, `HOPRD_ANNOUNCE`, etc. - see `docker-compose.yml`). `hoprd.cfg.yaml` now only
carries `blokli_url`, `session_ip_forwarding`, and `strategy` - re-adding the old
`identity:`/`api:`/`hopr.chain:` keys is a hard schema error. `HOPRD_PROVIDER` was replaced by
`HOPRD_BLOKLI_URL`.

`hoprd.cfg.yaml.tpl` ships with HOPR Association's own jura-prod GnosisVPN exit-node fleet
defaults (`blokli_url`, channel-funding strategy) - the same ones the Ansible role deploys,
not a stripped-down placeholder. Override `HOPRD_BLOKLI_URL` via the setup wizard if needed;
upload a custom config via the wizard's "Custom HOPR node configuration file" field for
anything deeper - that takes priority over the auto-rendered one on every start.

## Known gaps vs. the production fleet (out of scope for this first iteration)

- **No `tc`/peer-bandwidth-shaping.** The Ansible role's HTB+fq_codel peer rate limiting
  isn't ported.
- **No IP blocklist.** The Ansible role's `DOCKER-USER`-chain ipset blocklist
  (`gnosisvpn-blocklist` role) has no equivalent here at all - it's a host-level mechanism
  this package fundamentally can't reach (see above), not just an unported feature.
- **`gnosis_vpn-server`'s version isn't SDK-tracked.** `dappnode_package.json`'s
  `upstreamVersion`/`upstreamRepo` track hoprd (the SDK's auto-update mechanism is
  single-upstream); bumping `gnosis_vpn-server` means editing
  `gnosisvpn-server/Dockerfile`'s `FROM` line by hand.
- **No `hopr-admin` UI.**

## Local testing

See [`test/README.md`](test/README.md) - `just local-up`/`local-down` runs the real
docker-compose stack outside DAppNode, and `just validate-config` checks `hoprd.cfg.yaml`
against the real hoprd binary's config parser.

## Building the package

See [`DEVELOPING.md`](DEVELOPING.md).
