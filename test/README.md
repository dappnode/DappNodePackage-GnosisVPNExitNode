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

`node`'s `entrypoint.sh` resolves `gnosisvpn-server`'s address at boot (hoprd's
`session_ip_forwarding.target_allow_list` requires a literal ip:port, hostnames are rejected)
and renders it into `hoprd.cfg.yaml.tpl` - see that file and `docker-compose.yml`'s
`GNOSISVPN_SERVER_HOST`. Outside a real DAppNode install there's no DAppNode DNS alias to
resolve, so `docker-compose.local.yml` overrides `GNOSISVPN_SERVER_HOST` to plain
`gnosisvpn-server`, which plain `docker compose` resolves via the project's default network.

## Validating hoprd.cfg.yaml.tpl on its own

```sh
just validate-config   # or: test/validate-hoprd-config.sh
```

Runs hoprd's own config validator (`hoprd-cfg --validate-args`) against `hoprd.cfg.yaml.tpl`
(rendered with a dummy IP first), without starting anything. Pulls whatever
`UPSTREAM_VERSION` currently resolves to so this can start failing if an upstream release changes the schema, independently
of any change here.


```bash
curl -H 'accept: application/json' -H "X-Auth-Token: $HOPRD_API_TOKEN" http://localhost:3001/healthyz

```