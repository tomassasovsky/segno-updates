# segno update mirror: curl + jq in a tiny alpine, running the poll loop.
FROM alpine:3.20
RUN apk add --no-cache curl jq
COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh
ENTRYPOINT ["/usr/local/bin/sync.sh"]
