#!/bin/sh
# Start the on-demand HTTP trigger, then the poll loop in the foreground.
set -eu

# Internal-only listener (compose network). nginx proxies POST /hooks/sync here.
socat TCP-LISTEN:8080,reuseaddr,fork EXEC:/usr/local/bin/trigger.sh &

exec /usr/local/bin/sync.sh loop
