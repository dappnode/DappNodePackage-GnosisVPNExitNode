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
to - see README); instead it shares `node`'s network namespace (`network_mode:
"service:node"` in `docker-compose.yml`), so `wggvpn` and its `iptables` rules live inside
that shared namespace, not on your real machine - `just local-down` (or `docker compose
down`) tears it down along with both containers, nothing to clean up on the host afterward.
This is also why `hoprd.cfg.yaml`'s `session_ip_forwarding.target_allow_list` can just say
`127.0.0.1` - from `node`'s point of view, `gnosisvpn-server`'s ports are on loopback.

## Validating hoprd.cfg.yaml on its own

```sh
just validate-config   # or: test/validate-hoprd-config.sh
```

Runs the real hoprd 4.0.3 binary's own config validator (`hoprd-cfg --validate-args`) against
`hoprd.cfg.yaml`, without starting anything. Useful after editing it - hoprd 4.0's config
schema is strict (unknown top-level keys are a hard error).


```bash
curl -H 'accept: application/json' -H "X-Auth-Token: $HOPRD_API_TOKEN" http://localhost:3001/healthyz

```