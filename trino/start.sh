#!/bin/sh
set -e

mkdir -p /etc/trino
cp -r /etc/trino-source/. /etc/trino/

# Build the ES Basic-auth header at runtime so the password stays out of config files
ES_AUTH=$(printf 'elastic:%s' "$ELASTICSEARCH_PASSWORD" | base64 | tr -d '\n')
cat > /etc/trino/event-listener.properties << EOF
event-listener.name=http
http-event-listener.connect-ingest-uri=http://elasticsearch:9200/trino-query-audit/_doc?pipeline=add-timestamp
http-event-listener.connect-http-headers=Authorization: Basic ${ES_AUTH}
http-event-listener.log-completed=true
http-event-listener.log-created=false
http-event-listener.log-split=false
EOF

exec /usr/lib/trino/bin/run-trino
