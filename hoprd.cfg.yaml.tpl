---
blokli_url: https://blokli-piz-palu.dev.hoprnet.link
session_ip_forwarding:
  target_allow_list:
    # session_ip_forwarding requires a literal ip:port (hostnames are rejected by hoprd's own
    # config parser). This package can't pin gnosisvpn-server a static IP on dncore_network
    # (not allowed for non-core DAppNode packages - see README), so entrypoint.sh resolves
    # gnosisvpn-server's DAppNode DNS alias to its current IP at boot and renders this
    # template (see GNOSISVPN_SERVER_HOST in docker-compose.yml) - this file is not used
    # directly, only the rendered output at HOPRD_CONFIGURATION_FILE_PATH.
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
        # capacity to wxHOPR every tick using live ticket economics. Since
        # hopr-strategy 0.25 the hop count is fixed at ASSUMED_HOPS = 3 and the
        # assumed_hops key is rejected outright (deny_unknown_fields):
        #   N     = ceil(capacity_bytes / 1038)   # HoprPacket::PAYLOAD_SIZE
        #   F     = ticket_price * 3 / winning_prob   # one winning ticket
        #   E     = N * 3 * ticket_price              # mean drain
        #   stake = whole_tickets(max(F, E))          # sizing_mode: deterministic
        #
        # Every capacity is floored at one winning ticket and then rounded up to
        # a whole number of them, so the tiers below only stay distinct while
        # they sit above that floor. Note deterministic changed meaning in 0.23:
        # it is the mean drain floored at one ticket, no longer a worst case.
        # rotsee: ticket_price = 1e-16 wxHOPR, winning_prob = 1.25e-4
        #   => F = 2.4e-12 wxHOPR (2400000 wei); the floor binds below ~8.3 MB.
        #   stake (initial_capacity)           = 1 GiB   -> 130 tickets -> 312000000 wei
        #   topup (topup_capacity)             = 1 GiB   -> 130 tickets -> 312000000 wei
        #   floor (lower_capacity_threshold)   = 256 MiB ->  33 tickets ->  79200000 wei   topup trigger
        #   safe  (min_safe_capacity_required) = 1 GiB   -> 130 tickets -> 312000000 wei   open/fund gate
        # The safe gate is a single-channel floor, not working capital: holding
        # target_open_channels(8) at stake needs 8 * 312000000 wei.
        funding:
          initial_capacity: "1 GiB"
          topup_capacity: "1 GiB"
          lower_capacity_threshold: "256 MiB"
          #min_safe_capacity_required: "1 GiB"
          stop_when_unfunded: true
          sizing_mode: deterministic
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
        minimum_redeem_ticket_value: "1 wei wxHOPR"
