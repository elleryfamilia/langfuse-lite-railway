ARG LANGFUSE_VERSION=4.6.0
FROM langfuse/langfuse-worker:${LANGFUSE_VERSION} AS worker

FROM langfuse/langfuse:${LANGFUSE_VERSION}
USER root
RUN apk add --no-cache bash redis \
    && mkdir -p /var/lib/redis-eph \
    && chown 1001:1001 /var/lib/redis-eph
COPY --from=worker --chown=1001:1001 /app/worker /app/worker
COPY --chown=1001:1001 launcher.sh /launcher.sh
RUN chmod +x /launcher.sh
USER nextjs
ENV PORT=3000
# Upstream 4.6.0 defaults to events_only, which rejects legacy trace-create/observation-create
# ingestion (pre-4.7.0 Python / pre-5.4.0 JS SDKs get 400s). "legacy" restores full v3 ingestion
# and read behavior, matching standard self-hosted Langfuse and what older SDKs still send.
# The worker refuses to boot if NATIVE_OTEL_BEHAVIOUR stays at its "direct" default alongside
# WRITE_MODE=legacy (direct requires write mode in {dual, events_only}), so pair it with
# dual_write.
ENV LANGFUSE_MIGRATION_V4_WRITE_MODE=legacy
ENV LANGFUSE_MIGRATION_V4_NATIVE_OTEL_BEHAVIOUR=dual_write
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--", "/launcher.sh"]
CMD []
