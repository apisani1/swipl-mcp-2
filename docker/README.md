# MCP help server -- Docker build

Production-deployment recipe for hosting the MCP help server (the
read-only introspection suite) on `www.swi-prolog.org` (or any other
reachable host).

The container builds SWI-Prolog from `swipl-devel` and the MCP pack
from `JanWielemaker/MCP`, then runs `examples/swipl_help_public.pl`
under `library(http/http_unix_daemon)`.  That loader registers the
four read-only server modules only:

  - `library(mcp/servers/prolog_help)`  -- manual, xref, pldoc
  - `library(mcp/servers/swipl_kernel)` -- C source grep
  - `library(mcp/servers/source)`       -- file listing / reading / grep
  - `library(mcp/servers/git)`          -- log / blame / show / diff / grep

It deliberately omits `target_toplevel` (spawns child processes) and
`dev_reload` (calls `make/0` in-process) -- those are appropriate
only in a trusted developer loop.

## Build & run

```
make image    # build the mcp-help image
make run      # detached container on port 3410 (host)
make logs     # follow the swipl stdout
make restart  # stop + rm + run, picking up any image rebuild
make stop     # stop + rm
```

The container listens on TCP 3410 inside; the published port defaults
to 3410 on the host and is overridable with `make run PORT=...`.
Endpoints (per the MCP 2026-07-28 Streamable HTTP transport):

  - `POST /mcp`        -- one JSON-RPC request per POST; JSON reply, or a
                          long-lived SSE stream for `subscriptions/listen`
  - `GET  /mcp/health` -- server health (used by `health.sh`)

## Rebuilding individual layers

Bump the corresponding `ENV` line in `Dockerfile` so Docker rebuilds
just that layer (and everything after it):

```
make update-swipl   # rebuild swipl + MCP layers
make update-mcp     # rebuild MCP layer only
```

Both targets `sed` today's date into the matching `_VERSION` line and
then `docker build`.

## Health check

`HEALTHCHECK` runs `health.sh`, which fetches `/mcp/health`; the
container is unhealthy when the server can't respond within 5 s.  Health-check output
goes to `/tmp/health.log` inside the container.

## Behind a reverse proxy

For deployment on `www.swi-prolog.org`, terminate TLS in nginx and
proxy `/mcp` to `http://localhost:3410`.  The response to a
`subscriptions/listen` request is an SSE stream that stays open
indefinitely with a 15 s heartbeat; configure the proxy with a
matching or larger read timeout (`proxy_read_timeout 1d;` is typical)
and disable response buffering (the server also sends
`X-Accel-Buffering: no`).  The proxy must forward the `MCP-*`/`Mcp-*`
request headers unchanged:

```
location /mcp {
    proxy_pass             http://localhost:3410;
    proxy_buffering        off;
    proxy_read_timeout     1d;
    proxy_http_version     1.1;
    proxy_set_header       Connection "";
}
```
