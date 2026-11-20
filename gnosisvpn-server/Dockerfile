FROM europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis_vpn-server:0.7.0@sha256:443c4264bb41a82526ea7d227676f5060633e489569b4fb7fe6299f6a28ff78d

# What the scripts need; apk skips any the base image (Alpine) already has.
RUN apk add --no-cache bash iproute2 iptables ipset curl iputils-arping

WORKDIR /app

# Replace the image's own config.toml/wggvpn.conf with our templated versions. entrypoint.sh
# renders these and execs gnosis_vpn-server directly (not via the image's own wrapper.sh,
# which would leave it as a child process instead of PID 1 - see entrypoint.sh for why that
# matters for shutdown). PostUp/PreDown in wggvpn.conf run wg-hooks.sh, the forwarding
# policy - see README's "Firewall" section. wg-hooks.sh runs gvpn-peer-shaping.sh, and
# entrypoint.sh runs gvpn-blocklist-update.sh and gvpn-fixed-address.sh.
COPY config.toml.tpl wggvpn.conf.tpl ./
COPY entrypoint.sh wg-hooks.sh gvpn-blocklist-update.sh gvpn-peer-shaping.sh gvpn-fixed-address.sh ./
RUN chmod +x ./entrypoint.sh ./wg-hooks.sh ./gvpn-blocklist-update.sh ./gvpn-peer-shaping.sh ./gvpn-fixed-address.sh

ENTRYPOINT ["/app/entrypoint.sh"]
