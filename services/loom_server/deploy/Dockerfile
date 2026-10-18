ARG LOOM_DOCKER_PREFIX=
FROM ${LOOM_DOCKER_PREFIX}node:22.16.0-bookworm-slim@sha256:048ed02c5fd52e86fda6fbd2f6a76cf0d4492fd6c6fee9e2c463ed5108da0e34
WORKDIR /app
COPY package.json package-lock.json ./
ARG LOOM_NPM_REGISTRY=https://registry.npmjs.org/
RUN npm ci --omit=dev --ignore-scripts --registry="$LOOM_NPM_REGISTRY"
COPY src ./src

# Production runs TypeScript directly through Node's strip-only loader. Validate
# executable server source during image build so ordinary syntax errors fail.
# Declaration files describe types and must not be parsed as runtime modules.
RUN find src -type f -name '*.ts' ! -name '*.d.ts' -print0 \
  | xargs -0 -n1 node --experimental-strip-types --check

# `--check` does not reject every TypeScript construct that the ESM strip-only
# loader rejects at runtime (notably parameter properties). Import the additive
# V2 delivery composition graph with the same loader used in production so
# unsupported strip-only syntax cannot ship as a crash-looping container.
RUN node --experimental-strip-types --input-type=module \
  -e "await import('./src/delivery/attach_v2_delivery.ts')"

RUN mkdir -p /app/data && chown -R node:node /app

# Container deployments are configured from environment variables. The generated
# JSON config is intentionally ephemeral, while Node identity/data persist in
# /app/data through the Compose volume.
ENV LOOM_CONFIG=/tmp/loom-node.json
VOLUME ["/app/data"]
EXPOSE 7483
ARG LOOM_BUILD_COMMIT=unknown
LABEL org.opencontainers.image.revision=$LOOM_BUILD_COMMIT
RUN printf '%s\n' "$LOOM_BUILD_COMMIT" > /app/.loom-build-commit
USER node
CMD ["node", "--experimental-strip-types", "src/index.ts"]
