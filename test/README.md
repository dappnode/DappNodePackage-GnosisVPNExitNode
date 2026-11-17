# Local testing

Exercises the package's `docker-compose.yml` directly with `docker compose`, before running
it through `npx @dappnode/dappnodesdk build`. Not part of the published package (the SDK only
reads `docker-compose.yml` + `dappnode_package.json`).

## Running it

```sh
just local-up      # or: test/run-local.sh up
just local-logs    # follow logs
just local-down    # or: test/run-local.sh down
```

First run copies `.env.local.example` to `.env.local` (gitignored) if it doesn't exist yet -
edit that file for different throwaway values.

`.env.local.example` defaults `HOPRD_IDENTITY_FILE` to `hopr.id` (repo root, gitignored) -
put a real identity file there before running `just local-up`, so hoprd always starts from a
known identity instead of generating a fresh one on every run. `run-local.sh up` copies it
into the `node` container (via `docker cp`, before hoprd starts) as
`/app/hoprd/conf/hopr.id`. `HOPRD_PASSWORD` in `.env.local` must match whatever password that
identity was created with, or hoprd will fail to decrypt it on startup. If
`HOPRD_IDENTITY_FILE` is unset/blank, hoprd generates a fresh identity as usual.

`run-local.sh up` waits for `node`'s `/healthyz` endpoint, then prints `gnosisvpn-server`'s
generated WireGuard public key and `wg show wggvpn`. "Working" looks like:

- `node: healthy.` (can take a while - hoprd needs to sync before this passes)
- A logged WireGuard public key from `gnosisvpn-server`
- `wg show wggvpn` reporting the interface up with the address from `WIREGUARD_CIDR`

`gnosisvpn-server` doesn't use `network_mode: host` (regular DAppNode packages aren't allowed
to - see README); it runs as an ordinary service with its own network namespace, so `wggvpn`
and its `iptables` rules live inside that container, not on your real machine - `just
local-down` (or `docker compose down`) tears it down along with both containers, nothing to
clean up on the host afterward.

The stack's network uses `dncore_network`'s subnet, `172.33.0.0/16`, because
`gnosisvpn-server`'s fixed address `172.33.255.254` is in it (see the README's "Fixed
address"). It can't run on a machine that already has a network on that subnet, such as a
DAppNode.

## Checking node's rendered config

```sh
just test-entrypoint   # or: test/entrypoint.sh
```

Checks that [`entrypoint.sh`](../entrypoint.sh) renders `gnosisvpn-server`'s fixed address
and the PIX pool's Blokli URL without any network, ignores a config an older version rendered
at the upload path, uses a real upload and warns when it doesn't forward to the fixed address,
and `exec`s into hoprd. It also checks that the identity and PIX state paths, their volumes and
the `HOPRD_PASSWORD` variable stay the same, since changing any of them loses existing
installs' identity or PIX funds on update. Only Docker is needed.

## Checking the fixed address

```sh
just test-fixed-address         # or: test/fixed-address.sh
just test-fixed-address-image   # or: FIXED_ADDRESS_TEST_IMAGE=<image> test/fixed-address.sh
```

Checks [`gvpn-fixed-address.sh`](../gnosisvpn-server/gvpn-fixed-address.sh) on networks laid
out like DAppNode's, with a stand-in `node` without extra capabilities: `node` reaches the
server at `172.33.255.254:8000`, also after the server is recreated at another Docker address
or reconnected to the network, and a second claimant backs off.

`test-fixed-address-image` runs the built image's own entrypoint, so `node` talks to the real
control API. Like the local stack, neither runs on a machine with a `172.33.0.0/16` network.

## Checking the firewall

```sh
just test-firewall         # or: test/firewall.sh
just test-firewall-image   # or: FIREWALL_TEST_IMAGE=<image> test/firewall.sh
```

Checks that a VPN client can't reach local resources, but can still reach public destinations
and ping the tunnel-check address (see the README's "Firewall" section). Both commands:

1. Grep `wggvpn.conf.tpl`, the `gnosisvpn-server` Dockerfile and `entrypoint.sh` for the
   `wg-hooks.sh` wiring and the early FORWARD DROP.
2. Run `test/firewall-check.sh` in a throwaway privileged container. A veth pair named `wggvpn`
   stands in for WireGuard, a dummy `eth1` for the uplink, and a separate network namespace for
   the client, so the probes really go through the rules. Only Docker is needed.

`test-firewall` uses `alpine` with the repo's `wg-hooks.sh` mounted in. `test-firewall-image`
uses the built `gnosisvpn-server` image with nothing mounted or installed, which proves the
image ships the hook and its tools (`bash`, `iproute2`, `iptables`). Building that image needs
access to GnosisVPN's registry: `gcloud auth configure-docker europe-west3-docker.pkg.dev`.

## Checking the blocklist and shaping

```sh
just test-traffic         # or: test/traffic.sh
just test-traffic-image   # or: TRAFFIC_TEST_IMAGE=<image> test/traffic.sh
```

Checks the two things the exit node does to forwarded traffic besides isolating it (see the
README's "Blocklist" and "Per-peer shaping" sections). Both commands:

1. Grep the `gnosisvpn-server` Dockerfile, `entrypoint.sh` and `wg-hooks.sh` for the wiring: the
   image ships both scripts, the entrypoint loads the cached list and starts the refresher, and
   the hook runs the shaping.
2. Run `test/traffic-check.sh` in a throwaway privileged container. On top of the firewall
   suite's veth and client namespace there is a third namespace standing in for a public host
   that answers pings, so "the client still reaches the internet" is a real reply rather than a
   rule counter. Feeds are `file://` URLs, so no network is needed.

It covers the blocklist parser and the fail-open paths (a feed below the minimum entry count, an
unreachable feed, reloading from the cache), that a blocklisted destination really is dropped
while a public one is not, and that every peer slot has an HTB class in both directions with
packets actually counted in it.

`test-traffic` uses `alpine` with the repo's scripts mounted in. `test-traffic-image` uses the
built image with nothing mounted or installed, which proves it ships `ipset` and `curl` as well
as the scripts.

## Validating hoprd.cfg.yaml.tpl on its own

```sh
just validate-config   # or: test/validate-hoprd-config.sh
```

Runs hoprd's own config validator (`hoprd-cfg --validate-args`) against `hoprd.cfg.yaml.tpl`
(with its placeholders filled in first), without starting anything. Pulls whatever
`UPSTREAM_VERSION` currently resolves to so this can start failing if an upstream release changes the schema, independently
of any change here.


```bash
curl -H 'accept: application/json' -H "X-Auth-Token: $HOPRD_API_TOKEN" http://localhost:3001/healthyz

```