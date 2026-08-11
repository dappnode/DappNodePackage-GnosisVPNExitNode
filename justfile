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
