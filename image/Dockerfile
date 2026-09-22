ARG LANGFUSE_VERSION=4.41.0
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
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--", "/launcher.sh"]
CMD []
