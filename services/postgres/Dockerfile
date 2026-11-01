# Deliberately on 17, not 18. Railway keeps the volume across image bumps, and
# PostgreSQL refuses to start on a data directory from an older major version,
# so bumping this silently breaks every existing deploy rather than upgrading
# it. A major bump needs a pg_upgrade step, not a tag change.
FROM ghcr.io/railwayapp-templates/postgres-ssl:17
