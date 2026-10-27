FROM europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis_vpn-server:0.7.0@sha256:443c4264bb41a82526ea7d227676f5060633e489569b4fb7fe6299f6a28ff78d

# The base image (Alpine) already installs wireguard-tools - wg-quick, and through it bash and
# iproute2 - and iptables, which is everything wg-hooks.sh and the PostUp/PreDown rules in
# wggvpn.conf.tpl use. Nothing to add here.
WORKDIR /app

# Replace the image's own config.toml/wggvpn.conf with our templated versions. entrypoint.sh
# renders these and execs gnosis_vpn-server directly (not via the image's own wrapper.sh,
# which would leave it as a child process instead of PID 1 - see entrypoint.sh for why that
# matters for shutdown). wg-hooks.sh is the forwarding policy the rendered wggvpn.conf's
# PostUp/PreDown install and remove - see README's "Firewall" section.
COPY config.toml.tpl wggvpn.conf.tpl ./
COPY entrypoint.sh wg-hooks.sh ./
RUN chmod +x ./entrypoint.sh ./wg-hooks.sh

ENTRYPOINT ["/app/entrypoint.sh"]
