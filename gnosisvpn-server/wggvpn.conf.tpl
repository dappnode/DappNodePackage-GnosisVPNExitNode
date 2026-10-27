# Rendered by entrypoint.sh from this template. PostUp/PreDown install the
# forwarding policy a WireGuard exit node needs, scoped down to what's possible
# for a regular (non-core) DAppNode package: no network_mode: host, so this
# container's own network namespace (on dncore_network, like any other DAppNode
# package service - see docker-compose.yml) never reaches the DAppNode host's.
# All of it therefore lives in this namespace, in wg-hooks.sh: VPN clients may
# only reach publicly addressed destinations, MASQUERADE targets "eth0" (this
# container's own interface on its DAppNode-managed network) rather than a real
# public NIC, and Docker's own host-level NAT then carries that traffic the
# rest of the way out, same as it does for any other container's egress
# traffic. Explicit DOCKER-USER firewall exceptions aren't included for the same
# reason (no host namespace access) - see README's "Known limitations vs.
# production" section for why that's not actually a gap here.
[Interface]
Address = __WG_ADDRESS__/32
ListenPort = 51820
PrivateKey = <private key>
MTU = __WG_MTU__
PostUp = /app/wg-hooks.sh up __WG_CIDR__ __WG_ADDRESS__
PreDown = /app/wg-hooks.sh down __WG_CIDR__ __WG_ADDRESS__
