# {{APP_NAME}} — Production Runbook

**Prepared for {{OWNER}}** · Deployed {{DEPLOY_DATE}} · Runbook v1

This document explains how the production system is put together, how to operate
it, and how to recover it. Keep it in the repository so it stays with the code.

---

## 1. At a glance

| | |
|---|---|
| Live URL | https://{{APP_DOMAIN}} |
| Server | {{PROVIDER}} · {{PLAN}} · {{REGION}} · IP `{{SERVER_IP}}` |
| SSH | `ssh {{DEPLOY_USER}}@{{SERVER_IP}}` (key-only, passwords disabled) |
| Stack location | `/opt/shipops` |
| Repository | {{REPO_URL}} |
| Registry | {{REGISTRY_URL}} |
| Backups | `{{BACKUP_BUCKET}}` · nightly 03:20 UTC · {{RETENTION}} day retention |
| Restore test | Automatic, Sundays 04:40 UTC |
| Monitoring | {{MONITORING}} |

### Who pays for what

**You own and pay for every piece of infrastructure listed above, directly.**
It is billed to you directly by each provider, at cost. Current expected
monthly cost:

| Item | Provider | Approx. cost |
|---|---|---|
| Server | {{PROVIDER}} | {{SERVER_COST}} |
| Backup storage | {{BACKUP_PROVIDER}} | {{BACKUP_COST}} |
| Domain | {{DNS_PROVIDER}} | {{DOMAIN_COST}} |
| **Total** | | **{{TOTAL_COST}}** |

These are your accounts. If ShipOps disappeared tomorrow, nothing here would
switch off, and you would not need our permission to change anything.

---

## 2. Architecture

```
        Internet
           │  443 / 80
           ▼
   ┌───────────────┐
   │     Caddy     │  TLS termination, automatic Let's Encrypt renewal,
   │ reverse proxy │  health-checked routing between the two app colours
   └───────┬───────┘
           │  (internal Docker network — nothing below is exposed publicly)
     ┌─────┴─────┐
     ▼           ▼
┌─────────┐ ┌──────────┐
│app_blue │ │app_green │  Only one runs at a time. Deploys start the idle
└────┬────┘ └────┬─────┘  colour, verify it, then retire the old one.
     └─────┬─────┘
           ├──────────────┐
           ▼              ▼
     ┌──────────┐   ┌──────────┐
     │ Postgres │   │  Redis   │
     │ (volume) │   │ (volume) │
     └────┬─────┘   └──────────┘
          │  nightly pg_dump
          ▼
   {{BACKUP_BUCKET}}
```

**Only Caddy has published ports.** Postgres and Redis are reachable only from
inside the Docker network — they are not on the internet, and there is no
firewall rule that would let them be.

---

## 3. Deploying

Push to `main`. GitHub Actions builds the image, pushes it to the registry, and
runs the blue/green deploy. You do not need to SSH anywhere.

**What happens on each deploy:**

1. The new image starts on the *idle* colour, alongside the running one.
2. It must pass its health check within 120 seconds.
3. It is smoke-tested over the internal network.
4. Caddy is given 10 seconds to route to it.
5. Only then is the old colour stopped.

**If any step fails, the deploy aborts and the previous version keeps serving.**
A failed deploy is a non-event, not an outage.

### Deploying by hand

```bash
ssh {{DEPLOY_USER}}@{{SERVER_IP}}
/opt/shipops/scripts/deploy.sh {{REGISTRY_URL}}:sha-abc1234
```

### Rolling back

Roll back by deploying the previous tag. There is no separate rollback command
because there does not need to be one.

```bash
cat /opt/shipops/deploy-history.tsv        # every deploy, newest last
/opt/shipops/scripts/deploy.sh {{REGISTRY_URL}}:sha-PREVIOUS
```

Typical rollback time: **under 60 seconds**.

> **Database caveat, worth reading once.** Migrations run when the app boots. A
> rollback reverts *code*, not *schema*. If a release added a column, rolling
> back is safe. If it dropped or renamed one, rolling back the code alone will
> break against the changed schema — restore from backup instead, or ship a
> forward fix. This is why migrations should only ever add, and why removals
> should ship one release after the code that stopped using them.

---

## 4. Backups

| | |
|---|---|
| What | Full `pg_dump` of `{{POSTGRES_DB}}`, custom format |
| When | Nightly, 03:20 UTC (+ up to 15 min jitter) |
| Where | `{{BACKUP_BUCKET}}` — your bucket, your account |
| Retention | {{RETENTION}} days, pruned automatically |
| Integrity | SHA-256 recorded, archive parsed before upload, upload size verified |
| Verified | Restored into a throwaway database every Sunday |

Every backup is checked *before* upload — a truncated or unreadable dump is
never allowed to overwrite your history, and the prune step only runs after a
successful upload, so a broken backup can never delete good ones.

### Take a backup right now

```bash
sudo systemctl start shipops-backup.service
journalctl -u shipops-backup -n 50
```

Before a risky migration, take one that stays on disk:

```bash
BACKUP_DRY_RUN=1 /opt/shipops/scripts/backup.sh
```

### Prove the backups work

```bash
/opt/shipops/scripts/restore-test.sh
```

This downloads the newest backup, verifies its checksum, restores it into a
disposable Postgres container, and compares row counts against production. It
touches nothing live. Exit code 0 means the backup is provably restorable.

> Most providers "have backups". Very few have ever restored one. This runs
> every week so that the first restore is never the one you do in an emergency.

---

## 5. Restoring for real

**Stop and read this fully before running any of it.** Restoring overwrites the
live database.

```bash
# 1. Take a backup of the CURRENT state first, however broken it looks.
#    You may need to get back to it.
BACKUP_DRY_RUN=1 /opt/shipops/scripts/backup.sh

# 2. Stop the app so nothing writes mid-restore. Leave Postgres running.
cd /opt/shipops
docker compose -f docker-compose.prod.yml --profile green stop app_blue app_green

# 3. Fetch the backup you want.
aws s3 ls s3://{{BACKUP_BUCKET}}/{{STACK_NAME}}/ --recursive | tail -20
aws s3 cp s3://{{BACKUP_BUCKET}}/{{STACK_NAME}}/2026/<file>.dump /tmp/restore.dump

# 4. Restore it.
docker cp /tmp/restore.dump {{STACK_NAME}}-postgres-1:/tmp/restore.dump
docker exec {{STACK_NAME}}-postgres-1 pg_restore \
  -U {{POSTGRES_USER}} -d {{POSTGRES_DB}} \
  --clean --if-exists --no-owner --no-privileges /tmp/restore.dump

# 5. Bring the app back.
docker compose -f docker-compose.prod.yml up -d app_blue

# 6. Confirm.
curl -fsS https://{{APP_DOMAIN}}/healthz
```

Realistic recovery time for a database of this size: **10–20 minutes**.

---

## 6. Day-to-day operations

```bash
# What is running?
cd /opt/shipops && docker compose -f docker-compose.prod.yml --profile green ps

# Application logs (live)
docker logs -f {{STACK_NAME}}_app_blue

# Everything, last hour
docker compose -f docker-compose.prod.yml logs --since 1h

# Which build is live?
curl -s https://{{APP_DOMAIN}}/healthz

# Database shell
docker exec -it {{STACK_NAME}}-postgres-1 psql -U {{POSTGRES_USER}} -d {{POSTGRES_DB}}

# Disk usage — the number one cause of sudden death on a small VPS
df -h && docker system df

# Scheduled jobs
systemctl list-timers 'shipops-*'
```

### Changing an environment variable

```bash
sudo nano /opt/shipops/.env          # this file is chmod 600 for a reason
cd /opt/shipops
docker compose -f docker-compose.prod.yml up -d --force-recreate app_blue
```

Note this causes a brief restart. To change a variable with no downtime, deploy
the current image tag again after editing — that goes through blue/green.

---

## 7. When something is wrong

### The site is down

```bash
curl -sI https://{{APP_DOMAIN}}                                    # is anything answering?
docker compose -f docker-compose.prod.yml --profile green ps       # what is up?
docker logs --tail 100 {{STACK_NAME}}_app_blue                     # why did it stop?
df -h                                                              # full disk?
free -m                                                            # out of memory?
```

Most common causes, in the order they actually occur:

1. **Disk full.** Usually old Docker images. `docker system prune -af --filter "until=168h"`.
2. **The app crashed on boot** after a bad deploy — roll back (§3).
3. **Out of memory.** Check `dmesg -T | grep -i oom`. The swapfile normally
   absorbs this; if it is recurring, the server needs a bigger plan.
4. **Postgres did not start.** `docker logs {{STACK_NAME}}-postgres-1`.

### HTTPS is broken / certificate expired

Caddy renews automatically, so this almost always means it *could not*:

```bash
docker logs {{STACK_NAME}}-caddy-1 | grep -i -E 'acme|certificate|error'
dig +short {{APP_DOMAIN}}     # does DNS still point at {{SERVER_IP}}?
sudo ufw status               # are 80 and 443 still open?
```

Port 80 must stay open — Let's Encrypt validates over it. Closing it breaks
renewal roughly 60 days later, long after anyone connects the two events.

### A deploy will not go green

`deploy.sh` prints the failing container's last 40 log lines and rolls back on
its own. The old version is still serving. Read those lines, fix, push again.

---

## 8. Security

- SSH is key-only. Password authentication and root login are disabled.
- `ufw` allows 22, 80 and 443 inbound. Nothing else.
- `fail2ban` bans an IP for an hour after 5 failed SSH attempts.
- Unattended security updates are on; reboots are **not** automatic. Check
  `/var/run/reboot-required` monthly and reboot at a time you choose.
- Containers run as non-root with `no-new-privileges`.
- Secrets live only in `/opt/shipops/.env`, mode 600, never in the repository.

### Revoking maintainer access

This can be done at any time, without notice, and nothing will stop working:

```bash
sudo nano /home/{{DEPLOY_USER}}/.ssh/authorized_keys   # delete the key
```

Then remove the collaborator from the GitHub repository and rotate
`SSH_PRIVATE_KEY` in the repository secrets. That is the whole process.

---

## 9. Monthly checklist

Worth running once a month.

- [ ] `systemctl list-timers 'shipops-*'` — backups ran, restore test passed
- [ ] `df -h` — disk under 70%
- [ ] `cat /var/run/reboot-required` — reboot if pending kernel updates
- [ ] `docker compose pull && deploy.sh <current-tag>` — pick up base image patches
- [ ] Confirm the newest object in `{{BACKUP_BUCKET}}` is from last night
- [ ] Check the cloud bill has not changed shape

---

## 10. Contact

{{MAINTAINER}} — {{CONTACT_EMAIL}}


