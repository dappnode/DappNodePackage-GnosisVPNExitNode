FROM europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis_vpn-server:0.4.2@sha256:ae7cc7b3a05a8d9f0ad3f3d52c7f53b74d441158d06907cee186ff1bb207a183

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
