---
blokli_url: https://blokli-jura.prod.hoprnet.link
session_ip_forwarding:
  target_allow_list:
    # session_ip_forwarding requires a literal ip:port (hostnames are rejected by hoprd's own
    # config parser). This package can't pin gnosisvpn-server a static IP on dncore_network
    # (not allowed for non-core DAppNode packages - see README), so entrypoint.sh resolves
    # gnosisvpn-server's DAppNode DNS alias to its current IP at boot and renders this
    # template (see GNOSISVPN_SERVER_HOST in docker-compose.yml) - this file is not used
    # directly, only /app/hoprd/conf/hoprd.generated.cfg.yaml, its rendered output.
    - "__GNOSISVPN_SERVER_IP__:51820"    # gnosisvpn-server's WireGuard interface
    - "__GNOSISVPN_SERVER_IP__:8000"     # gnosisvpn-server's control endpoint
strategy:
  allow_recursive: false
  execution_interval: 15s
  strategies:
    - ChannelLifecycle:
        population:
          min_open_channels: 5
          target_open_channels: 8
        eligibility:
          require_currently_connected: true
          min_peer_quality_score: 0.5
          peer_quality_weight: 0.6
          ticket_activity_weight: 0.4
          require_observed_since_start: true
          allowlist: ~
          blocklist: []
        # Channel funding is expressed as data capacity; the node resolves each
        # capacity to wxHOPR every tick using live ticket economics:
        #   packets = ceil(capacity_bytes / HoprPacket::PAYLOAD_SIZE)   # PAYLOAD_SIZE = 1038 B
        #   funding = ticket_price * packets * assumed_hops / winning_probability
        #
        # Funding is matched to winning (redeemable) ticket values. One winning
        # ticket = ticket_price / winning_probability = 0.00001 / 0.000004 =
        # 2.5 wxHOPR. Each packet is backed by one full ticket face value, so a
        # stake of N winning tickets carries N packets = N * 1038 B of capacity.
        # Anchored to a 10 wxHOPR (4 winning ticket) channel, assumed_hops=1.
        # Each capacity is a round value chosen inside its packet bucket
        # (between N and N+1 times PAYLOAD_SIZE) so it resolves to the
        # intended packet count.
        #   stake (initial_capacity)           =  4 winning tickets =  10 wxHOPR ->  5 KB
        #   floor (lower_capacity_threshold)   =  2 winning tickets =   5 wxHOPR ->  3 KB   topup trigger
        #   topup (topup_capacity)             =  2 winning tickets =   5 wxHOPR ->  3 KB   restore floor -> stake
        #   safe  (min_safe_capacity_required) = 32 winning tickets =  80 wxHOPR -> 34 KB   target_open_channels(8) * stake
        funding:
          initial_capacity: "1 GiB"
          topup_capacity: "1 GiB"
          lower_capacity_threshold: "256 MiB"
          min_safe_capacity_required: "1 GiB"
          stop_when_unfunded: true
          assumed_hops: 3
        proactive_funding:
          enabled: true
          safety_margin: 1.5
          balance_drain_weight: 1.0
          ticket_index_drain_weight: 1.0
        closure:
          close_below_quality_score: 0.3
          close_when_drained_below: "0 wxHOPR"
          close_max_concurrent: 2
        finalizer:
          enabled: true
          finalize_max_concurrent: 4
        restart: {}
        concurrency:
          max_concurrent_actions: 4
        selector: default
    - AutoRedeeming:
        minimum_redeem_ticket_value: "1 wxHOPR"
