FROM oven/bun:1
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile || bun install
COPY . .
RUN bunx vite build
# Read-only API: keepers need a key and are disabled by default. Postgres runs in-process (PGlite) unless DATABASE_URL is set.
ENV PORT=7860 KEEPERS=off
EXPOSE 7860
USER bun
CMD ["bun", "run", "start"]
