# shipops-stack

**A production stack for one VPS, with backups that are actually verified.**

Docker Compose, Caddy with automatic HTTPS, blue/green deploys that roll
themselves back, and a backup system that proves it can restore — by restoring.
Postgres, MySQL or MongoDB. Provisioning script included.

Built for the case where a managed platform has become expensive or limiting and
a single well-configured server would do: side projects, small SaaS, internal
tools, client work.

```
                Internet
                   │ 443 / 80
             ┌─────▼─────┐
             │   Caddy   │  automatic TLS, health-checked upstreams
             └─────┬─────┘
          ┌────────┴────────┐   internal network, nothing published
      ┌───▼───┐        ┌────▼────┐
      │ blue  │        │  green  │   one live, one idle — deploys swap them
      └───┬───┘        └────┬────┘
          └────────┬────────┘
            ┌──────▼──────┐   ┌───────┐
            │  Postgres   │   │ Redis │
            │ MySQL/Mongo │   └───────┘
            └──────┬──────┘
                   │ nightly, integrity-checked
              object storage
                   │ weekly
            restore + row-count check
```

---

## Why this exists

There are a lot of "deploy Docker to a VPS" repos. Two things here are unusual.

**Backups are verified by restoring them.** Every week the newest backup is
downloaded, checksummed, restored into a throwaway database container, and its
row counts compared against production. That catches the failure nobody catches:
a backup that is well-formed, restores with zero errors, contains every table,
and holds no data at all.

**Deploys cannot take the site down.** The new version starts alongside the
running one and must pass a health check that queries the database. Traffic
moves only after it does. A failed deploy is torn down and the current version
keeps serving — measured at 301 requests across the internet during a live
cutover with zero failures.

Both claims come with the harnesses that test them, in `test/`.

---

## Quick start

Runs the whole stack locally against the example app in about a minute.

```bash
git clone https://github.com/patrickmackin05/shipops-stack
cd shipops-stack/example
docker build --build-arg APP_VERSION=v1 -t linkjar:v1 .

cd ../compose
cp env.example .env          # edit STACK_NAME, POSTGRES_PASSWORD
# for local use, plain HTTP and no ACME:
echo 'CADDYFILE=./Caddyfile.local' >> .env
echo 'HTTP_PORT=8080'              >> .env

../scripts/deploy.sh linkjar:v1
curl localhost:8080/healthz
```

Then watch a zero-downtime cutover:

```bash
cd ../example && docker build --build-arg APP_VERSION=v2 -t linkjar:v2 .
cd ../compose && ../scripts/deploy.sh linkjar:v2
```

And prove the backups work:

```bash
BACKUP_DRY_RUN=1 BACKUP_STAGING=/tmp/bk ../scripts/backup.sh
../scripts/restore-test.sh --local "$(ls -t /tmp/bk/* | head -1)"
```

## On a real server

```bash
# fresh Ubuntu 22.04/24.04, as root
./provision.sh --ssh-key "$(cat ~/.ssh/id_ed25519.pub)"
```

Key-only SSH, UFW, fail2ban, unattended security updates, swap, Docker with
capped logs, AWS CLI, and a weekly image prune. Idempotent.

**Read [docs/first-server.md](docs/first-server.md) before you do this on a
server you care about.** It covers the traps that cost an evening: ARM images
failing with `exec format error`, Cloudflare's proxy breaking certificate
issuance, Docker bypassing UFW, and the fact that on EC2 locking out the
`ubuntu` user is close to unrecoverable.

---

## What's in it

| | |
|---|---|
| `docker/` | Multi-stage Dockerfiles for Node, Python and Go. Non-root, healthchecked, pinned |
| `compose/` | The stack: Caddy + blue/green app + database + Redis. MySQL and MongoDB variants |
| `scripts/provision.sh` | Fresh Ubuntu → hardened Docker host |
| `scripts/deploy.sh` | Blue/green deploy, health gate, smoke test, automatic rollback |
| `scripts/backup.sh` | Dump → integrity check → checksum → object storage |
| `scripts/restore-test.sh` | Restores the newest backup and compares row counts against live |
| `scripts/lib/engine-*.sh` | Per-database adapters — one code path for all three engines |
| `ci/deploy.yml` | GitHub Actions: build → push → SSH → blue/green → verify |
| `test/` | The harnesses that verify the above |
| `docs/` | First-server guide, runbook template, verification log |

## Databases

Postgres, MySQL/MariaDB and MongoDB, behind one interface. Backup and restore
verification work identically on all three; the engine is detected from the
running container.

Verifying a backup means something different for each, and the obvious method is
wrong for two of the three:

- **Postgres** — parse the archive table of contents, then require at least one
  `TABLE DATA` entry, because a schema-only dump parses perfectly.
- **MySQL** — valid gzip, mysqldump's own completion trailer (its absence is the
  signature of a truncated dump), and at least one `INSERT`.
- **MongoDB** — `mongorestore --dryRun` reads only the archive header. Measured:
  it exits 0 on an archive truncated to 400 bytes. So the archive is actually
  restored into a scratch namespace and the collections that arrive are compared
  against what the header claimed.

## Security posture

- Only the reverse proxy publishes ports. The database is on an internal network
  and is not reachable from the host, let alone the internet.
- Containers run non-root with `no-new-privileges`.
- Secrets live in one `chmod 600` file, never in the image or the repo.
- On AWS, backups use an **IAM instance role** — no long-lived credentials on
  the server at all — and the policy deliberately omits `s3:DeleteObject`, so a
  compromised server cannot destroy its own backups. Retention is a bucket
  lifecycle rule instead.

---

## Testing

```bash
./test/test-engines.sh      # 18 checks · all three databases, three failure modes
./test/test-provision.sh    # 20 checks · provisioning in a container, real sshd -t
```

Both clean up after themselves and both currently pass.

`test-engines.sh` runs an 18-case matrix — each engine against a healthy backup,
a truncated one, and one that restores cleanly but contains no data — and checks
that both the nightly and weekly verification stages reach the right verdict.
About a minute once the database images are cached; a few minutes the first
time, when it pulls MySQL and MongoDB.

`test-provision.sh` dry-runs provisioning in Ubuntu 24.04 with systemd and ufw
stubbed, then validates what it produced using the real `sshd -t`, `visudo -cf`
and `fail2ban-client -t`, and re-runs it to confirm it is idempotent. One to
three minutes depending on apt and your image cache. It found three genuine
bugs the first time it ran, including one where the SSH lockout guard failed for
a reason that had nothing to do with the config being valid.

[docs/verification.md](docs/verification.md) records what has been tested, what
each test proved, and — more usefully — the fifteen bugs found along the way,
including the ones that were silently wrong rather than loudly broken.

## What is not covered

Stated plainly, because a stack like this is easy to oversell:

- Multi-server, autoscaling, or high availability. This is one box.
- Zero-downtime **schema** migrations. Deploys are zero-downtime; a destructive
  migration is still destructive.
- Multi-arch images. Build amd64 and use an x86 server, or add buildx yourself.
- Compliance frameworks.

If you need those, you need more than a single VPS and this is the wrong tool.

## Further reading

Write-ups of things this stack exists because of — several found while testing it:

- [You built an app with AI. Now it has to run somewhere.](https://shipops.dev/writing/built-with-ai-now-deploy-it)
  — what deploying actually involves if your app currently only runs on your
  laptop, whether you need a server at all, and the seven assumptions in
  AI-written code that stop being true in production.
- [The backup that restores perfectly and contains nothing](https://shipops.dev/writing/backup-that-restores-perfectly-and-contains-nothing)
  — why `mongorestore --dryRun` exits 0 on a truncated archive, and the check
  that actually catches an empty backup.
- [Docker quietly bypasses UFW](https://shipops.dev/writing/docker-bypasses-ufw)
  — published container ports are reachable regardless of firewall rules,
  because they traverse FORWARD rather than INPUT.
- [pg_restore: unsupported version in file header](https://shipops.dev/writing/pg-restore-unsupported-version-in-file-header)
  — client/server version skew, not a corrupt backup.

## Licence

MIT. Use it, fork it, ship it.

---

Built by [Patrick](https://shipops.dev). I also do this as a fixed-price
service, if you would rather not — [shipops.dev](https://shipops.dev).
