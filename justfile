# Build the DAppNode package
build:
    npx @dappnode/dappnodesdk build

# Bring up the local test stack (see test/README.md)
local-up:
    ./test/run-local.sh up

# Tear down the local test stack
local-down:
    ./test/run-local.sh down

# Follow logs from the local test stack
local-logs:
    docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env.local logs -f

# Re-validate hoprd.cfg.yaml against the real hoprd 4.0.3 config parser
validate-config:
    ./test/validate-hoprd-config.sh

# Check that VPN clients can't reach local resources through the exit node
test-firewall:
    ./test/firewall.sh

# Run the same firewall checks inside the built gnosisvpn-server image
test-firewall-image:
    docker build -t gnosisvpn-server:firewall-test gnosisvpn-server
    FIREWALL_TEST_IMAGE=gnosisvpn-server:firewall-test ./test/firewall.sh

# Check the blocklist and per-peer shaping the exit node applies
test-traffic:
    ./test/traffic.sh

# Run the same blocklist and shaping checks inside the built image
test-traffic-image:
    docker build -t gnosisvpn-server:traffic-test gnosisvpn-server
    TRAFFIC_TEST_IMAGE=gnosisvpn-server:traffic-test ./test/traffic.sh
