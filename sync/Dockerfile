# segno update mirror: curl + jq + socat (on-demand sync trigger).
FROM alpine:3.20
RUN apk add --no-cache curl jq socat
COPY sync.sh trigger.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/sync.sh /usr/local/bin/trigger.sh /usr/local/bin/entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
