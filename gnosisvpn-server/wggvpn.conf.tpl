# Rendered by entrypoint.sh from this template. PostUp/PreDown run wg-hooks.sh,
# which installs the exit node's forwarding policy in this container's own
# network namespace. A regular DAppNode package gets no network_mode: host, so
# it never reaches the host's namespace (see docker-compose.yml).
# VPN clients may only reach public destinations. MASQUERADE targets "eth0"
# (this container's DAppNode-managed interface), and Docker's host-level NAT
# carries the traffic the rest of the way out. There are no DOCKER-USER
# exceptions for the same reason - see README's "Known limitations vs.
# production" for why that's not a gap here.
[Interface]
Address = __WG_ADDRESS__/32
ListenPort = 51820
PrivateKey = <private key>
MTU = __WG_MTU__
PostUp = /app/wg-hooks.sh up __WG_CIDR__ __WG_ADDRESS__
PreDown = /app/wg-hooks.sh down __WG_CIDR__ __WG_ADDRESS__
