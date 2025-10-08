FROM docker.io/library/alpine:3.22
ENV RUNNING_IN_DOCKER=true
ENTRYPOINT ["/bin/bash"]
CMD ["/app/cloudflare_exporter.sh"]
COPY cloudflare_exporter.sh /app/cloudflare_exporter.sh
RUN addgroup -g 10001 user \
    && adduser -H -D -u 10000 -G user user
RUN apk add --quiet --no-cache bash coreutils curl jq
USER user:user
