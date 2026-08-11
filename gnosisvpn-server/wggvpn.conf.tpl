# Rendered by entrypoint.sh from this template. PostUp/PreDown are adapted from the
# gnosisvpn-server Ansible role's wireguard_postup/wireguard_predown (see
# gnosis_vpn-infrastructure inventory/jura-prod/group_vars/gnosisvpn_exit_nodes/vars.yaml),
# scoped down to what's possible for a regular (non-core) DAppNode package: no
# network_mode: host, so no access to the real host's DOCKER-USER iptables chain or its
# public interface - only this container's own network namespace. MASQUERADE targets "eth0"
# (this container's own interface on its DAppNode-managed network) rather than the host's
# NIC; Docker's own host-level NAT then carries that traffic the rest of the way out, same
# as it does for any other container's egress traffic. tc/peer-bandwidth-shaping and the
# DOCKER-USER-chain blocklist rules aren't included - see README for the full list of gaps
# vs. the production fleet.
[Interface]
Address = __WG_ADDRESS__/32
ListenPort = 51820
PrivateKey = <private key>
MTU = __WG_MTU__
PostUp = iptables -t nat -A POSTROUTING -s __WG_CIDR__ -o eth0 -j MASQUERADE
PreDown = iptables -t nat -D POSTROUTING -s __WG_CIDR__ -o eth0 -j MASQUERADE
