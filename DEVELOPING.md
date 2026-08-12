# Development

Build a package with (requires Node.js)

```sh
npx @dappnode/dappnodesdk build
```

This should produce output similar to

```
  ✔ Verify connection
  ✔ Create release dir
  ✔ Validate files
  ✔ Copy files
  ✔ Build architecture linux/amd64
  ✔ Upload release to IPFS node
  ✔ Save upload results

  DNP (DAppNode Package) built and uploaded
  Release hash : /ipfs/Qm...
```

Before that, see [`test/README.md`](test/README.md) for exercising the actual
docker-compose stack locally - much faster to iterate on than a full DAppNode install/update
cycle, and catches most integration issues (env vars, config schema, `gnosisvpn-server`
networking) earlier.

### Bumping `gnosis_vpn-server`

Its version isn't tracked by the DAppNode SDK's auto-update mechanism (that's single-upstream,
already pointed at hoprd). To bump it: update the `FROM` line in
`gnosisvpn-server/Dockerfile` to the new tag/digest, then re-check
`gnosisvpn-server/config.toml.tpl`/`wggvpn.conf.tpl` still match what that version's image
ships (`docker run --rm --entrypoint sh <image> -c 'cat config.toml wggvpn.conf'`) in case the
upstream image's own defaults/shape changed.

### Bumping hoprd

Update `docker-compose.yml`'s `UPSTREAM_VERSION` build arg, then re-run
`just validate-config` - hoprd 4.0's config schema is strict (unknown top-level keys in
`hoprd.cfg.yaml` are a hard error), so a minor version bump can break it silently
otherwise.
