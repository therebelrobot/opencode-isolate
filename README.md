# opencode / OpenRouter — hardened, network-isolated test rig

Runs `opencode` (from the `opencode-ai` npm package) against OpenRouter inside
a container with no direct route to the internet. The only egress path is a
`gateway` container that does Squid domain-allowlisting (openrouter.ai only)
plus an iptables default-deny OUTPUT policy, so containment holds even if
opencode's HTTP client bypasses the proxy env vars (see openrouter/opencode
issue #6953 — proxy support is best-effort, not the security boundary).

## Setup

1. `cp .env.example .env` and fill in `OPENROUTER_API_KEY`.
   - Create it via OpenRouter's Provisioning/Management API with a hard
     `limit` (e.g. `limit: 5`, `limit_reset: "daily"`) so a runaway loop
     can't spend past your cap. Keep the separate Management key off this
     box entirely — it's never needed by opencode itself.
2. `docker compose build`
3. `docker compose run --rm opencode opencode run "say hi" -m openrouter/deepseek/deepseek-v4-flash --format json`

For an interactive TUI session: `docker compose run --rm opencode opencode`.

For a headless server (only reachable from other containers on the
`isolated` network, since it's never published to the host):
`docker compose run --rm opencode opencode serve --hostname 0.0.0.0`.

## Verifying the isolation actually holds

Don't trust the proxy env vars alone. Confirm no direct connections escape.

`strace` can't be installed at container runtime the obvious way
(`apt-get install` from inside a running container) - the isolated network
only allows `openrouter.ai`, so apt has nowhere to fetch from, and the
`opencode` service also runs a read-only rootfs (Task 9) that blocks the
write anyway. Bake it in at build time instead, run the check, then rebuild
without it - don't ship strace in the default image:

```sh
docker compose build --build-arg INSTALL_STRACE=1 opencode
docker compose run --rm --cap-add SYS_PTRACE opencode sh -c \
  'strace -f -e trace=connect opencode run "hello" -m openrouter/deepseek/deepseek-v4-flash 2>&1 | grep connect'
docker compose build opencode   # rebuild without strace afterwards
```

Every `connect()` to a public IP on port 443 should go to the `gateway`
container's IP on the `isolated` network (port 3128), never directly to an
OpenRouter/CDN IP. If you see a direct connect to :443, the isolation has a
hole — file it and don't rely on env-proxy for that opencode build.

Also worth checking from the `gateway` side: `docker compose exec gateway
tail -f /var/log/squid/access.log` while opencode runs, to confirm only
`openrouter.ai` traffic is passing and nothing else (or the deny) is logged.

## Where logs live

| Log | Path | Persisted? | Contains |
| --- | --- | --- | --- |
| Squid access log | `logs/squid/access.log` (host bind mount; also `docker compose logs gateway`) | Yes | Every CONNECT/HTTP request Squid saw - domain, port, allow/deny verdict, timestamp. **Never cost** - CONNECT tunnels are encrypted, so Squid only ever sees the destination host:port, not the request/response bodies OpenRouter bills on. |
| OpenRouter usage log | `logs/openrouter-usage.log` (host bind mount, written by the `poller` service) | Yes | One JSON line per poll of `GET /api/v1/key`: `{ts, usage, limit, limit_remaining, is_free_tier}`. This is **account/key-level cumulative usage**, not a per-request cost breakdown - good for a spend meter and trend line, not for attributing cost to a specific run. |
| opencode session/token data | inside the container's writable layer | No - destroyed by `docker compose run --rm` | Per-session token/cost history opencode itself tracks. Not persisted by default (see the `poller` alternatives below for why). |

Alternatives considered for cost observability, beyond the `poller` service above:

- **Persist opencode's session data** by mounting a named volume at
  `/home/agent/.local/share/opencode`. This would keep per-session cost
  history across `--rm`, but that same directory can hold `auth.json` (the
  API key) if anyone ever runs `/connect` instead of using the env var -
  persisting it would write the secret to a host volume, conflicting with
  this repo's "don't persist secrets" posture. Not done by default; only
  worth doing if auth stays strictly env-only, and even then prefer
  mounting a narrower subpath than the whole data dir.
- **Do nothing locally** and rely on OpenRouter's Activity dashboard plus
  ad hoc `GET /api/v1/key` calls. That's a valid choice too - the `poller`
  service here is just a convenience for a local trend line without
  needing to leave the box.

## Layers, in order of what actually stops an escape

1. **`isolated` network is `internal: true`** — opencode has no default
   route to the internet at all, regardless of what its HTTP client does.
   This is the real boundary.
2. **Squid `dstdomain` allowlist** (`squid/squid.conf`) — only CONNECTs to
   `openrouter.ai` succeed; everything else gets `http_access deny all`.
3. **iptables on the gateway** (`gateway/entrypoint.sh`) — default-DROP
   OUTPUT, only DNS + 80/443 pass. Defense-in-depth in case Squid itself is
   ever misconfigured; it does not do domain-level filtering itself (that's
   Squid's job), just stops other ports/protocols from becoming an exfil
   path.
4. **`opencode.json` permissions** — `webfetch`/`websearch` denied,
   `external_directory` denied, `bash` gated behind `ask` with explicit
   `curl`/`wget`/`nc` denies, `share: "disabled"`, `autoupdate: false`. This
   is opencode's own last line of defense, not network isolation.
5. **OpenRouter per-key spend cap** — fail-safe if everything above is
   bypassed somehow; the key just stops working past its `limit`.

## Container hardening on the `opencode` service

`docker-compose.yml` runs the `opencode` service with `cap_drop: [ALL]`,
`no-new-privileges`, a `pids_limit`, a `mem_limit`, and a read-only rootfs
(`read_only: true`). The only writable paths are `tmpfs` mounts for the
directories opencode actually needs at runtime (`/tmp`,
`~/.local/share/opencode`, `~/.local/state`, `~/.cache`,
`~/.config/opencode`) plus the `workspace` bind mount, which stays the only
place that persists across a run. `opencode.json` is still bind-mounted
read-only into `~/.config/opencode/opencode.json` on top of that tmpfs, so
even though the directory is now writable in principle, the permission file
itself remains immutable to the agent - confirmed by testing that `touch`
against it fails with `Read-only file system` even under the tmpfs. A
compromised agent process can't persist anything to the image layer; only
`workspace/` survives a run.

## Headless / non-interactive runs

`opencode.json`'s default `bash` permission is `{"*": "ask"}`, which needs a
human to answer the prompt. The `docker compose run --rm ... opencode run
"..."` examples above work because `docker compose run` allocates a TTY, but
any truly non-interactive invocation (CI, a cron job, `docker compose run -T`)
has no TTY to answer an `ask` prompt and will stall or fail.

For those cases, use the `headless` agent profile defined in
`opencode.json`, which denies bash outright except the same read-only `git
status`/`git diff`/`git log` allowlist already used interactively:

```sh
docker compose run --rm opencode opencode run "say hi" \
  -m openrouter/deepseek/deepseek-v4-flash --agent headless --format json
```

The interactive default (`bash: "ask"`) is unchanged for normal TUI/`opencode
run` use from a terminal.

## Releasing

A git tag `vX.Y.Z` versions all three images — `gateway`, `agent` (the
`opencode` service's image), and `poller` — in lockstep and is the only
thing that triggers a release:

```sh
make release VERSION=1.2.3
# equivalent to:
#   git tag -a v1.2.3 && git push origin v1.2.3
```

Pushing the tag runs `.github/workflows/release.yml`, which builds and
publishes all three images, multi-arch (`linux/amd64` + `linux/arm64`), to
GHCR at `1.2.3`, `1.2`, and `sha-<commit>`, each with a signed
[SLSA build provenance attestation](https://slsa.dev/) and a signed SBOM
attestation. Independent per-image versioning is out of scope by design —
if you ever need `gateway` and `poller` to version separately from `agent`,
that'd be a deliberate follow-up, not the current behavior.

**Reproducibility gap:** `.env.example` (and this repo's own `.env`) still
default `OPENCODE_VERSION=latest`, so `release.yml` currently builds the
`agent` image with `--build-arg OPENCODE_VERSION=latest` too — meaning two
releases built on different days can silently ship different `opencode-ai`
versions under the same image tag. Pin `OPENCODE_VERSION` to a specific
`opencode-ai` release (see the strace check above to verify a build first)
and update the `build-args` line in `.github/workflows/release.yml` to
match before relying on published `agent` images being reproducible.

**One-time setup after the first release of each image:** GitHub publishes
new GHCR packages as **private** by default, even in a public repo. To pull
them from elsewhere (e.g. the Pi), make each package public — or grant it
access — once, per package:

1. github.com/therebelrobot?tab=packages → open the package
   (`isolate-opencode-gateway`, `-agent`, `-poller`)
2. **Package settings** (bottom of the right sidebar)
3. **Change visibility** → **Public** (or, to keep it private, **Manage
   Actions access** / add the consuming account under
   **Invite teams or people** for pull access)

This repo is public, so [artifact
attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
work as-is — that feature requires a public repo (or GitHub Enterprise) on
Free/Pro plans. If this repo ever goes private, provenance attestation will
stop working on Free/Pro until it's public again or you're on a plan that
supports it.

## Consuming these images elsewhere

Pull by minor tag for convenience, or pin to a digest for immutability —
GHCR's multi-arch index digest resolves correctly on both `arm64` (Pi) and
`amd64`:

```sh
docker pull ghcr.io/therebelrobot/isolate-opencode-gateway:1.2
# or, immutable:
docker pull ghcr.io/therebelrobot/isolate-opencode-gateway@sha256:<digest>
```

If a package is private, log in first with a PAT scoped to `read:packages`:

```sh
echo "$GHCR_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
```

Verify provenance before trusting an image, especially on a device like the
Pi that's pulling a prebuilt binary instead of building from source:

```sh
gh attestation verify oci://ghcr.io/therebelrobot/isolate-opencode-gateway:1.2.3 --owner therebelrobot
```

`make inspect IMAGE=gateway TAG=1.2.3` confirms both arches are present in
the manifest list; `make verify IMAGE=gateway TAG=1.2.3` runs the
`gh attestation verify` check above.

**Using the images in another workspace:** [`examples/`](examples/) has a
ready-to-copy `docker-compose.yml` plus the `squid.conf` and
`opencode.json` it bind-mounts, and an `.env.example`. It mirrors this
repo's own `docker-compose.yml` exactly — same networks, same
`cap_drop`/`read_only`/`tmpfs` hardening on `opencode`, same `NET_ADMIN` +
iptables lockdown on `gateway` — just `image:` instead of `build:`, so
dropping it into a new project doesn't weaken any of the isolation
described above. Copy the four files in, `mkdir -p workspace logs/squid`,
fill in `.env`, then `docker compose pull && docker compose run --rm
opencode opencode`.

## Notes

- No official opencode Docker image exists; this builds one from
  `node:22-bookworm-slim` + `npm i -g opencode-ai`. Pin `OPENCODE_VERSION`
  in `.env` once you've verified a build with the strace check above —
  don't track `latest` long-term.
- `workspace/` is bind-mounted read-write into the container at
  `/workspace` — that's opencode's project root and the only place it can
  edit files (`external_directory: deny` blocks anything outside it).
  `opencode.json` is mounted read-only at opencode's *global* config path
  (`/home/agent/.config/opencode/opencode.json`), not the project path
  inside `/workspace` — it needs to live somewhere the agent's own `edit`
  permission can't reach, and somewhere `external_directory: deny` actually
  covers. Mounting it inside `/workspace` would put the load-bearing
  permission block in the one directory the agent is allowed to write to,
  letting it edit its own restrictions. (This also happens to dodge a
  Docker Desktop virtiofs bug where a file-mount nested inside an
  already-bind-mounted directory fails to attach — but that's incidental;
  the real reason is keeping the config out of the agent's writable scope.)
- Model defaults to `openrouter/deepseek/deepseek-v4-flash` in
  `opencode.json` — cheap and not free-tier rate-limited. Swap for an
  `:free` model for zero-cost smoke tests if you can live with 20 req/min.
- The Munder Difflin Electron GUI is intentionally not part of this stack —
  isolate the opencode agent layer, not the GUI shell. See the original
  research notes for why.
- `OPENROUTER_API_KEY` is passed as a plain env var, which means it's
  visible via `docker inspect opencode` and `/proc/1/environ` to anyone with
  access to the Docker host. That's an acceptable tradeoff for a
  single-user local test rig; on a shared host, prefer Docker secrets or an
  env-file injected by the orchestrator instead of `environment:` in
  `docker-compose.yml`.
