#!/bin/sh
# Minimal HTTP handler for socat EXEC: POST /sync with Bearer SYNC_TOKEN runs
# one mirror cycle. Bound only on the Docker network; nginx exposes it publicly
# as POST /hooks/sync.
set -eu

auth=""
method=""
path=""

while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [ -z "$line" ] && break
    if [ -z "$method" ]; then
        # Request line: METHOD PATH HTTP/1.x
        method=$(printf '%s' "$line" | cut -d' ' -f1)
        path=$(printf '%s' "$line" | cut -d' ' -f2)
        continue
    fi
    case "$line" in
        [Aa]uthorization:*)
            auth=$(printf '%s' "$line" | sed 's/^[Aa]uthorization:[[:space:]]*//')
            ;;
    esac
done

respond() {
    code="$1"
    reason="$2"
    body="$3"
    # Content-Length via byte count (portable; body is short ASCII).
    len=$(printf '%s' "$body" | wc -c | tr -d ' ')
    printf 'HTTP/1.1 %s %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %s\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n%s' \
        "$code" "$reason" "$len" "$body"
}

if [ -z "${SYNC_TOKEN:-}" ]; then
    respond 503 "Service Unavailable" "sync trigger disabled (SYNC_TOKEN unset)
"
    exit 0
fi

if [ "$method" != "POST" ] || { [ "$path" != "/sync" ] && [ "$path" != "/sync/" ]; }; then
    respond 404 "Not Found" "not found
"
    exit 0
fi

if [ "$auth" != "Bearer ${SYNC_TOKEN}" ]; then
    respond 401 "Unauthorized" "unauthorized
"
    exit 0
fi

# Capture stdout+stderr; always answer (socat should not see a non-zero exit
# from a half-written HTTP response).
set +e
out=$(/usr/local/bin/sync.sh once 2>&1)
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    respond 500 "Internal Server Error" "${out}
"
    exit 0
fi

respond 200 "OK" "${out}
"
exit 0
