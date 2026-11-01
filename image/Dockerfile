ARG LANGFUSE_VERSION=4.72.0

# Redis is not in the upstream image, and Langfuse 4.72's base image cannot
# install it: upstream rebased onto ubi9-micro, which ships no package manager
# (no apk, no dnf), so the old `apk add bash redis` fails with exit 127. Copy
# the binaries from Debian bookworm instead. ubi9 already provides every shared
# library redis-server links (libssl.so.3, libcrypto.so.3, libstdc++, libgcc_s),
# and bookworm's glibc 2.36 binary only uses symbols ubi9's glibc 2.34 exports.
# Pinned to bookworm rather than latest on purpose: a future Debian release
# bumps glibc past what ubi9 ships, and that would break the binary silently at
# runtime instead of at build time.
FROM redis:8.2-bookworm AS redis

FROM langfuse/langfuse-worker:${LANGFUSE_VERSION} AS worker

FROM langfuse/langfuse:${LANGFUSE_VERSION}
USER root
COPY --from=redis /usr/local/bin/redis-server /usr/local/bin/redis-server
COPY --from=redis /usr/local/bin/redis-cli /usr/local/bin/redis-cli
# launcher.sh is a bash script. ubi9-micro happens to ship bash, but nothing
# upstream promises that, so fail the build here rather than in a crash loop.
RUN command -v bash >/dev/null \
      || { echo "upstream image dropped bash; image/launcher.sh requires it" >&2; exit 1; } \
    && mkdir -p /var/lib/redis-eph \
    && chown 1001:1001 /var/lib/redis-eph
COPY --from=worker --chown=1001:1001 /app/worker /app/worker
COPY --chown=1001:1001 launcher.sh /launcher.sh
RUN chmod +x /launcher.sh
USER nextjs
ENV PORT=3000
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--", "/launcher.sh"]
CMD []
