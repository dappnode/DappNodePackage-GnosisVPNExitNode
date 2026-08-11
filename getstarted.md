## What is a GnosisVPN exit node?

This package runs a HOPR node (hoprd) alongside gnosis_vpn-server, so your DAppNode becomes an
exit node for [GnosisVPN](https://www.gnosisvpn.com/): client traffic is relayed through the
privacy-preserving HOPR mixnet and this node terminates it on a WireGuard interface, forwarding
it on to the internet.

## Who should install this

Operators willing to dedicate their DAppNode (and its public IP) to running a GnosisVPN exit
node. `gnosisvpn-server` needs host-level network access to do its job - see the README for
what that means before installing.

## More information

[https://hoprnet.org/](https://hoprnet.org/) · [https://www.gnosisvpn.com/](https://www.gnosisvpn.com/)
Telegram: [https://t.me/hoprnet](https://t.me/hoprnet)
