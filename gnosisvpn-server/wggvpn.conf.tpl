# Rendered by entrypoint.sh from this template. PostUp/PreDown do the NAT a WireGuard exit
# node needs, scoped down to what's possible for a regular (non-core) DAppNode package: no
# network_mode: host, so this container's network namespace (shared with the node service -
# see docker-compose.yml's `network_mode: "service:node"` on this service) never reaches the
# DAppNode host's. MASQUERADE targets "eth0" (that shared network namespace's interface on
# its DAppNode-managed network) rather than a real public NIC; Docker's own host-level NAT
# then carries that traffic the rest of the way out, same as it does for any other
# container's egress traffic. Explicit DOCKER-USER firewall exceptions aren't included for
# the same reason (no host namespace access) - see README's "Known limitations vs.
# production" section for why that's not actually a gap here.
[Interface]
Address = __WG_ADDRESS__/32
ListenPort = 51820
PrivateKey = <private key>
MTU = __WG_MTU__
PostUp = iptables -t nat -A POSTROUTING -s __WG_CIDR__ -o eth0 -j MASQUERADE
PreDown = iptables -t nat -D POSTROUTING -s __WG_CIDR__ -o eth0 -j MASQUERADE
