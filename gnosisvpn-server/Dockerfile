FROM europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis_vpn-server:0.7.0@sha256:443c4264bb41a82526ea7d227676f5060633e489569b4fb7fe6299f6a28ff78d

# The scripts need bash, iproute2 (ip, tc), iptables and ipset, and the blocklist
# refresher needs curl. Install them explicitly instead of relying on the base image
# (Alpine); apk skips any that are already installed.
RUN apk add --no-cache bash iproute2 iptables ipset curl

WORKDIR /app

# Replace the image's own config.toml/wggvpn.conf with our templated versions. entrypoint.sh
# renders these and execs gnosis_vpn-server directly (not via the image's own wrapper.sh,
# which would leave it as a child process instead of PID 1 - see entrypoint.sh for why that
# matters for shutdown). PostUp/PreDown in wggvpn.conf run wg-hooks.sh, the forwarding
# policy - see README's "Firewall" section. wg-hooks.sh runs gvpn-peer-shaping.sh, and
# entrypoint.sh runs gvpn-blocklist-update.sh.
COPY config.toml.tpl wggvpn.conf.tpl ./
COPY entrypoint.sh wg-hooks.sh gvpn-blocklist-update.sh gvpn-peer-shaping.sh ./
RUN chmod +x ./entrypoint.sh ./wg-hooks.sh ./gvpn-blocklist-update.sh ./gvpn-peer-shaping.sh

ENTRYPOINT ["/app/entrypoint.sh"]
