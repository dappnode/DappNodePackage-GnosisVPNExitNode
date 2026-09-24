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
