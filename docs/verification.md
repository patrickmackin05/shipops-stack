# Verification log

Everything in this directory was executed against a real application
(`example/` — Express + Postgres + Redis, with migrations, a
database-touching health endpoint and graceful shutdown) on Docker 29.6.1.
The backup and restore scripts were additionally verified against live MySQL 8
and MongoDB 7 instances with seeded data.

This file exists so the claims in the README are checkable, and so the checks
can be re-run after changing anything. Every harness referenced here is in
`test/`.

**`provision.sh` has now run on a real server** — AWS EC2 t3.micro, Ubuntu
24.04, eu-west-1, on 8 September 2026. See *On real infrastructure* below. It is
also dry-run in a container on every change.

**The container harness predicted the real thing exactly**: nothing failed on
the live server that the container had not already caught. That is the strongest
evidence that the local harnesses are worth running before each client.

**The container dry-run, for reference:** `test/test-provision.sh` runs it end to end with systemd, ufw and swap
stubbed, then validates what it produced using the real `sshd -t`, `visudo -cf`
and `fail2ban-client -t`. That covers configuration correctness and package
setup; it cannot cover sshd actually restarting, the firewall enforcing rules,
or a certificate being issued. See *Outstanding*.

---

## Results

| # | What was tested | Method | Result |
|---|---|---|---|
| 1 | Compose stack is valid | `docker compose config` | Pass |
| 2 | Both CI workflows are valid YAML | parsed | Pass |
| 3 | All five shell scripts parse | `bash -n` | Pass |
| 4 | Multi-stage build excludes dev dependencies | added a devDependency, checked the runtime image | Pass |
| 5 | Container runs unprivileged | `id` inside the image | `uid=1000(node)` |
| 6 | Signal handling present | `tini` at PID 1 | Pass |
| 7 | Stack cold-starts on empty volumes | `down -v` then deploy | Pass |
| 8 | Migrations run automatically at boot | container logs | Both applied |
| 9 | Postgres wired correctly | inserted rows, read back | Pass |
| 10 | Redis wired correctly | `x-cache: miss` then `hit` | Pass |
| 11 | Caddy proxies to the app | `curl` through :8080 | HTTP 200 in 3ms |
| 12 | **Blue/green deploy is genuinely zero-downtime** | 552 requests during a live cutover | **0 failures** |
| 13 | **Failed deploy rolls back with no downtime** | 1466 requests across 2 failed deploys | **0 failures** |
| 14 | Rollback restores state cleanly | `.env` reverted, temp files gone, old container untouched | Pass |
| 15 | Deploy refuses `:latest` | attempted | Refused |
| 16 | Backup produces a valid archive | `pg_dump` + `pg_restore --list` | 11 objects |
| 17 | Backup records a checksum | sha256 written | Pass |
| 18 | **Restore into a clean database works** | disposable container, row counts compared | 5/5 checks pass |
| 19 | **A truncated backup is detected** | truncated to 2KB | 3 checks failed, exit 1 |
| 20 | **A schema-only backup is detected** | valid archive, zero rows | 2 checks failed, exit 1 |
| 21 | Postgres, MySQL and MongoDB all back up and restore | seeded live instances of each | 3/3 pass |
| 22 | Every engine catches every failure mode | 18-case matrix, both stages | 18/18 |
| 23 | `provision.sh` runs to completion on fresh Ubuntu 24.04 | container dry-run | Pass |
| 24 | The sshd config it writes is valid | real `sshd -t` | Pass |
| 25 | The sudoers drop-in is valid | real `visudo -cf` | Pass |
| 26 | The fail2ban jail parses | real `fail2ban-client -t` | Pass |
| 27 | Docker installs from the official repo | container dry-run | Pass |
| 28 | Re-running it is safe | second run, key not duplicated | Pass |
| 29 | AWS CLI present for backups | container dry-run | v2 installed |
| 30 | `AllowUsers` restricted to the deploy user by default | container dry-run | Pass |
| 31 | `--keep-user` adds an EC2 fallback and still validates | real `sshd -t` | Pass |

`test/test-provision.sh` · 20 checks, 20 pass.

Tests 12, 13, 19 and 20 are the ones that matter. They are the difference
between claiming zero-downtime deploys and verified backups, and showing it.

---

## The measurements behind the headline claims

### Zero-downtime deploy (test 12)

A request was sent to the public endpoint every 100ms while `deploy.sh` cut
over from `v1` to `v2`:

```
552 requests · 552 × HTTP 200 · 0 failures
version sequence: v1 … v1, v2, v1, v2, v1 … v2 … v2
```

The alternation in the middle is both colours healthy and serving at once
during the drain window — Caddy round-robins across them — before the old
colour is retired. That interleaving is the mechanism working, not a fault.

### Rollback under load (test 13)

Two deliberately broken images (containers that start, listen, and return HTTP
500 on `/healthz`) were deployed while traffic ran:

```
1466 requests · 1466 × HTTP 200 · 0 failures
deploy.sh exit code: 1 (both times)
```

After each failure: `.env` restored to the previous tag, the failed container
removed, `.env.deploy-backup` cleaned up, and the previously running container
still up with unbroken uptime. A failed deploy is a non-event.

### Backup verification (tests 18–20)

| Backup given to `restore-test.sh` | Outcome |
|---|---|
| Healthy dump | 5 passed, 0 failed, exit 0 |
| Truncated to 2KB | checksum mismatch + `pg_restore` error + no tables → exit 1 |
| Schema-only (valid archive, no rows) | restore succeeds, tables exist, **row counts catch it** → exit 1 |

The schema-only case is the one worth understanding. It passes every check most
backup systems perform — the archive is well-formed and `pg_restore` exits 0 —
and it is completely worthless. Only comparing row counts against production
catches it.

---

## Multi-engine backup matrix

`backup.sh` and `restore-test.sh` support Postgres, MySQL/MariaDB and MongoDB
through adapters in `scripts/lib/engine-*.sh`. Each was run against a live
seeded instance, and then against a deliberately broken backup of each kind.

Two stages are tested independently, because they protect against different
things. **BACKUP verify** runs nightly before upload and stops a bad dump ever
reaching the bucket. **RESTORE test** runs weekly and proves the stored backup
still restores.

| Engine | Case | Backup verify | Restore test |
|---|---|---|---|
| Postgres | healthy dump | pass | pass |
| Postgres | truncated | caught | caught |
| Postgres | schema-only | caught | caught |
| MySQL 8 | healthy dump | pass | pass |
| MySQL 8 | truncated | caught | caught |
| MySQL 8 | schema-only | caught | caught |
| MongoDB 7 | healthy dump | pass | pass |
| MongoDB 7 | truncated | caught | caught |
| MongoDB 7 | schema-only | caught | caught |

18 of 18. Healthy backups pass at both stages on all three engines; no failure
mode slips through either stage on any engine.

### How each engine proves a dump is real

The interesting part is that "verify the backup" means something different per
engine, and the obvious method is wrong for two of the three.

**Postgres** — `pg_restore --list` parses the archive's table of contents, which
fails outright on a truncated file. A schema-only dump parses fine, so the check
also counts `TABLE DATA` entries; zero means it would restore an empty database.

**MySQL** — there is no table of contents, so integrity is established three
ways: the gzip stream must be valid, the dump must end with mysqldump's own
`Dump completed` trailer (its absence is the signature of a killed or truncated
dump), and it must contain at least one `INSERT INTO`. `mysqldump --no-data`
produces a dump that is valid, complete and useless; the INSERT count is what
catches it.

**MongoDB** — see bug 4 below. This one is genuinely treacherous.

---

## On real infrastructure

AWS EC2 `t3.micro` (2 vCPU, 911Mi RAM), Ubuntu 24.04, eu-west-1, 8 Sep 2026.
A t3.micro is below the recommended spec — chosen deliberately, to see whether
the stack holds on the smallest plausible box.

| Check | Result |
|---|---|
| `provision.sh` completes on a fresh cloud image | Pass |
| `shipops` can log in with the deploy key | Pass |
| `--keep-user ubuntu` fallback works | Pass |
| **Root login refused** | Correctly refused |
| **Password authentication refused** | Correctly refused |
| Docker usable by the deploy user without sudo | Pass |
| fail2ban running, sshd jail active | Pass |
| UFW active on 22/80/443 | Pass |
| 2GB swapfile live | Pass |
| AWS CLI v2 installed | Pass |
| Image builds on the server | 25s, 42Mi swap touched |
| Cold-start deploy, stack up | Pass |
| App reachable over the public internet | HTTP 200, 56ms |
| Redis cache path (`x-cache` miss then hit) | Pass |
| **Postgres NOT reachable from the internet** | Correctly refused |
| **Blue/green deploy under live internet traffic** | **301 requests, 0 failures** |
| Backup dump + integrity verification | Pass, 11 objects |
| Restore into a disposable database | 5/5 checks |
| systemd timers install and schedule | Pass, jitter applied |
| Backup unit runs as `shipops` and fails cleanly when misconfigured | Pass |
| **Backup uploaded to S3, with size verification** | Pass |
| **Restore test downloading from the bucket** | 6/6 checks |
| Backup freshness check against a real object | Pass, 0h old |
| systemd unit completes a real backup | `Result=success` |
| IAM instance role supplies credentials (no keys on disk) | Pass |
| **Server denied `s3:DeleteObject` on its own backups** | Correctly refused |

### What running it for real taught us

**The zero-downtime claim survives real network conditions.** The earlier 552
requests were over localhost, where a dropped connection is much less likely.
301 requests across the internet to eu-west-1 during a live cutover, still zero
failures.

**A t3.micro is enough for a small app, but only just.** With the full stack up:
341Mi of 911Mi available, 57Mi of swap in use. The default memory limits
(512M app + 512M Postgres) oversubscribe a box this size and would invite the
OOM killer — which picks Postgres, because it has the largest RSS. Lowered to
256M/256M/64mb for this deployment. **Quote t3.small or larger for real clients.**

**The systemd unit failing was a useful test.** Triggering the backup service
without a bucket configured produced exactly the right behaviour: the unit ran
as `shipops`, executed the right script, exited non-zero, and left a legible
reason in the journal. A silent success would have been far worse.

---

## Bugs found and fixed during verification

Recorded because each one is a live outage or a false sense of security, and
each is easy to reintroduce.

1. **`mongorestore --dryRun` silently passes a truncated archive.** This was the
   most dangerous finding of the whole build. `--dryRun` is the documented way
   to check a Mongo archive without writing, and it reads only the archive
   *prelude* — the header listing which collections are inside. Measured: an
   archive truncated to 400 bytes exits 0. Verification built on it would have
   uploaded corrupt backups nightly and reported them healthy, which is the
   exact failure this service is sold on preventing. It only fails on a
   completely empty file.

   Fixed with a two-stage check: parse the prelude for the declared collection
   count, then actually restore into a scratch namespace on the live server,
   which forces every byte to be read, and compare what arrived against what was
   claimed. Measured behaviour of the deep stage — healthy: exit 0, 2 of 2
   collections; truncated: exit 1, 1 of 2; empty: exit 1, 0 of 2. The scratch
   database is dropped immediately, and the deep stage is skipped with a loud
   warning above `MONGO_DEEP_VERIFY_MAX_BYTES` (default 500MB), because copying
   a large production database nightly is not a reasonable thing to do.

2. **A 1KB minimum-size check failed a healthy backup.** A seeded MongoDB
   archive is 802 bytes, and the driver rejected it as "suspiciously small". A
   size threshold that fires on good backups is worse than no threshold, because
   it teaches you to ignore the alert. Lowered to 256 bytes and rescoped to what
   it can honestly detect — an empty or zero-byte dump — with the engine's own
   archive parse doing the real work.

3. **Dev dependencies shipped to production.** `COPY --from=build /app ./` after
   copying the production-only `node_modules` overwrote it with the build
   stage's full tree. Fixed by deleting `node_modules` after the app copy, then
   copying the production tree last.

4. **Caddy `depends_on: [app_blue]` caused a real outage.** It meant the deploy
   script's "ensure dependencies are up" step recreated the container *currently
   serving traffic*. Measured: **5 failed requests** (1×502, 4×503) over ~3
   seconds. Fixed by removing `depends_on` entirely — Caddy starts fine with no
   healthy upstream and finds one within `health_interval`.

5. **`compose up` without `--no-recreate` mid-deploy.** `.env` has just been
   rewritten with the new image, so compose recreates the running app. Same
   outage as (2) by a different route.

6. **Postgres version skew reported healthy backups as corrupt.** The host had
   `pg_restore` 14; the database container runs 16. An older `pg_restore`
   cannot read a newer archive — `unsupported version (1.15) in file header` —
   so every good backup failed verification. Fixed by always using the binary
   inside the database container, and by defaulting the restore-test container
   to the live database's own image rather than a hardcoded version. This one is
   nasty: it produces alerts that look like corruption, and the natural
   "fix" of ignoring them destroys the value of the whole service.

7. **A scalar query helper used for a list.** `tr -d '[:space:]'` stripped the
   separators between table names, producing one nonsense identifier and
   aborting the row-count comparison under `set -e`. Split into `q` (scalars)
   and `qlines` (lists).

8. **Custom-format dumps need seekable input.** `pg_restore --list /dev/stdin`
   fails on a pipe. The archive is now copied into the container as a file.

9. **GNU-only tooling.** `date -Is` and `sha256sum` do not exist on macOS, so
   the scripts could not be rehearsed locally. Both now detect and adapt.

10. **`sshd -t` failed for a reason unrelated to the config.** The lockout guard
    aborts provisioning if OpenSSH rejects the generated config — correct, and
    it failed safe. But it also fails with `Missing privilege separation
    directory: /run/sshd` on any host where sshd has not started yet: a
    container, a rescue image, a minimal cloud image. A safety check that
    misfires on the environment stops the whole provision for no good reason.
    Now creates `/run/sshd` first, which is what sshd's own startup does.

11. **`provision.sh` assumed `cron` was installed.** Ubuntu's server images ship
    it; minimal and cloud-optimised images do not, and `/etc/cron.weekly` then
    does not exist — so the script aborted at its final step with a bare "No
    such file or directory". Adding `cron` to the package list was the fix; a
    plain `mkdir` would have been worse, leaving the weekly Docker prune in a
    directory nothing ever reads, so disk usage would creep up invisibly.

12. **Two of the dry-run's own assertions were false positives.** It checked
    that `fail2ban-client -t` passed and that `/etc/apt/apt.conf.d/20auto-upgrades`
    existed — both true on a stock Ubuntu with `provision.sh` never run. A test
    that passes when the thing under test did nothing is worse than no test.
    Now asserts on the ShipOps-specific jail and policy files.

13. **`backup.sh` used a tool provisioning never installed.** The script uploads
    with `aws s3`, and `provision.sh` did not install the AWS CLI. Nothing local
    caught it, because every backup test ran with `BACKUP_DRY_RUN=1`, which
    exits before the upload. On a real server the first failure would have been
    at 03:20, unattended, with `aws: command not found`. Found by reasoning
    through the first-server sequence rather than by any test. Now installs AWS
    CLI v2 from the official bundle (Ubuntu's apt ships the deprecated v1, which
    handles S3-compatible endpoints poorly), and the dry-run asserts it.

14. **Nothing authenticated the server to a private registry.** The CI workflow
    logs in to push; the *server* has to log in separately to pull, and no step
    did that. The first real deploy would have failed on `docker pull` with
    `denied`. Added `scripts/registry-login.sh` (token read from stdin, scoped
    to `read:packages`), a hint in `provision.sh`'s closing output, and a
    pointer in `deploy.sh`'s pull-failure message.

15. **`deploy.sh` hard-failed on an unpullable image.** Now falls back to an
   image already on the host, loudly, so local rehearsal works and a registry
   blip during a cutover is survivable.

---

## Re-running these tests

```bash
cd example

# Cold start from nothing
docker compose -f docker-compose.prod.yml --env-file .env --profile green down -v
./scripts/deploy.sh linkjar:v1
curl -s localhost:8080/healthz

# Zero-downtime check: run this in one terminal, deploy in another
while true; do curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/healthz; sleep 0.1; done

# Backup and verify
BACKUP_DRY_RUN=1 BACKUP_STAGING=/tmp/bk ./scripts/backup.sh
./scripts/restore-test.sh --local "$(ls -t /tmp/bk/*.dump | head -1)"
```

---

## Outstanding

Honest list of what has not been proven yet.

- **Cloudflare R2 specifically.** The full upload and restore path is proven
  against real AWS S3 with an instance role. R2 uses the same S3 API via
  `AWS_ENDPOINT_URL`, but has not been exercised.
- **The script's own retention prune.** The live run used `BACKUP_PRUNE=off`
  with an S3 lifecycle rule, so the `aws s3 rm` path and the date-cutoff logic
  are still untested.
- **Let's Encrypt.** Only `Caddyfile.local` (plain HTTP, ACME disabled) has run.
  Needs a domain.
- **The GitHub Actions workflows.** Valid YAML, never executed. Needs a repo and
  a registry, which also exercises `registry-login.sh`.
- **fail2ban actually banning an IP.** The jail is active; nothing has tripped it.
- **Production Caddyfile against real Let's Encrypt.** Only `Caddyfile.local`
  (ACME disabled) has been exercised. Use the staging ACME endpoint first; the
  live one locks you out for an hour after 5 failures per domain.
- **The GitHub Actions workflows end-to-end.** Valid YAML, never run. Test on a
  throwaway repository against the same throwaway server.
- **`backup.sh` against real object storage.** The dump, integrity check and
  checksum are verified; the S3/R2 upload, size confirmation and retention prune
  have not run against a live bucket.
- **`install-schedules.sh`.** systemd timers cannot be tested on macOS.
- **The Python and Go Dockerfiles.** Written to the same pattern as the Node one
  and reviewed, but only the Node template has actually been built and run.
- **MariaDB specifically.** The MySQL adapter resolves `mariadb-dump`/`mariadb`
  when the mysql-prefixed tools are absent, and skips `--set-gtid-purged` when
  the dumper does not advertise it, but it was tested against MySQL 8 only.
- **The MySQL and MongoDB compose services** in `compose/db-alternatives.yml`.
  Valid YAML and modelled on the tested containers, but the scripts were
  verified against standalone containers rather than a full stack.

Do the first four on one throwaway server in a single sitting. That is
the last thing standing between "verified locally" and "verified in production".
