FROM clickhouse/clickhouse-server:25.12
# Destination filename is prefixed "00-" so it sorts alphabetically before the
# entrypoint-generated users.d/default-user.xml. That file does
# `<default remove="remove">` whenever CLICKHOUSE_USER is set, then defines a
# fresh default user; merging our override afterward would leave that fresh
# user without a password directive and ClickHouse refuses to start. Applying
# ours first means the entrypoint's later removal simply deletes whatever
# default node exists, which always succeeds.
COPY lockdown.xml /etc/clickhouse-server/users.d/00-lockdown.xml
