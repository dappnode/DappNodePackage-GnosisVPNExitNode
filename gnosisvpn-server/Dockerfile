FROM europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis_vpn-server:0.7.0sha256:443c4264bb41a82526ea7d227676f5060633e489569b4fb7fe6299f6a28ff78d

# The base image (Alpine) ships wg/wg-quick/ip but not iptables/ipset, which the PostUp/PreDown
# rules in wggvpn.conf.tpl need (ported from the gnosisvpn-server Ansible role).
RUN apk add --no-cache iptables ip6tables ipset bash

WORKDIR /app

# Replace the image's own config.toml/wggvpn.conf with our templated versions. entrypoint.sh
# renders these and execs gnosis_vpn-server directly (not via the image's own wrapper.sh,
# which would leave it as a child process instead of PID 1 - see entrypoint.sh for why that
# matters for shutdown).
COPY config.toml.tpl wggvpn.conf.tpl ./
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
