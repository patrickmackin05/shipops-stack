# The first real server

What actually happens the first time you run this on a VPS, in the order it
happens, with the things that will genuinely bite you.

Everything here is either verified in the local harnesses or is a known
property of the platforms involved. Where I'm uncertain I've said so — those
are the parts to check rather than trust.

**Budget:** about £0.20 for the server (Hetzner bills hourly), plus a domain at
roughly £10/year. **Time:** 2–4 hours the first time. Not one.

---

## Do these days before, not that evening

Three things have lead times you cannot compress, and all three have ended
people's "quick evening" before it started.

### 1. Hetzner account verification

Hetzner manually reviews new accounts and often asks for photo ID before
releasing any server. This can take hours, sometimes into the next day. If you
sign up the evening you plan to build, there is a real chance you get nothing.

Sign up now. Create and destroy one server immediately, just to prove the
account works.

If you're blocked and impatient, DigitalOcean and Vultr provision instantly and
cost roughly twice as much — about £5–6/mo for an equivalent box. Fine for a
rehearsal; move clients to Hetzner later.

### 2. The domain and its nameservers

Buy the domain and point its nameservers at Cloudflare **now**. Registrar
nameserver changes propagate on their own schedule — usually under an hour,
occasionally up to 24. Once Cloudflare is authoritative, individual DNS record
changes take seconds, which is what you want on the night.

### 3. Two SSH keys, not one

```bash
# Your admin key. Passphrase-protected, lives only on your laptop.
ssh-keygen -t ed25519 -f ~/.ssh/shipops_admin -C "shipops-admin"

# The CI key. NO passphrase, because GitHub Actions cannot type one.
ssh-keygen -t ed25519 -f ~/.ssh/shipops_ci -N "" -C "shipops-ci"
```

The temptation is one key for both. Don't. The CI key sits unencrypted in
GitHub secrets, and one day you will want to rotate it without locking yourself
out of every server you manage. `provision.sh --ssh-key` installs one; append
the second to `authorized_keys` afterwards.

---

## Pick the right server, or nothing will run

Applies to every provider: **take an x86 instance, not ARM.** On Hetzner that
means CX22 rather than CAX11; on AWS, t3 rather than t4g.

Hetzner's ARM boxes are cheaper and genuinely good, but GitHub Actions' default
runners build **amd64** images. Push an amd64 image to an arm64 server and every
container dies instantly with `exec format error`. It is a baffling failure if
you don't know the cause, because the image pulled fine and the compose file is
correct.

You can fix it properly with `docker/build-push-action` and
`platforms: linux/amd64,linux/arm64`, but multi-arch builds are several times
slower and need QEMU set up in CI. Not a thing to discover at 11pm. Use x86
until this stack has a multi-arch story.

Also note Hetzner now bills the IPv4 address separately, about €0.50/month on
top of the server. The "€3.79" headline is IPv6-only — budget about £5/month
all-in.

Image: **Ubuntu 24.04**. Add your admin SSH key in the Hetzner console at
creation time — then root login is key-only from the first boot and there is no
emailed password sitting in your inbox.

---

## Doing the rehearsal on AWS instead

Perfectly reasonable, and for a first run arguably better: debugging in a
console you already know is worth more than saving £2 on a box you'll destroy
the same night. This stack is provider-agnostic by design, so it has to work on
more than one.

Three things genuinely differ.

### The lockout risk is much worse on EC2

`provision.sh` writes `AllowUsers shipops`, which locks out the `ubuntu` account
you logged in with. On Hetzner or DigitalOcean that's recoverable: a browser
console plus the root password you set. **EC2 has no comparable escape.** Serial
Console needs account-level enablement, a Nitro instance, and an OS password the
Ubuntu AMIs never set. EC2 Instance Connect arrives over SSH, so `AllowUsers`
blocks it too. The real fallback is stopping the instance, detaching the root
EBS volume, attaching it to a second instance, editing sshd_config, and
reattaching — perhaps twenty minutes if you've done it before.

So on AWS, use the fallback flag:

```bash
sudo ./provision.sh --ssh-key "$(cat ~/.ssh/shipops_admin.pub)" --keep-user ubuntu
```

That keeps `ubuntu` permitted alongside `shipops`. Once you've confirmed
`shipops` works, remove the name from
`/etc/ssh/sshd_config.d/99-shipops.conf` and `sudo systemctl restart ssh`.

### Instance and volume settings that actually matter

| Setting | Value | Why |
|---|---|---|
| AMI | Ubuntu Server 24.04 LTS | What `provision.sh` targets |
| Type | **t3.small** | t3.micro's 1GB is tight for Postgres + app + Caddy. **Not t4g** — Graviton is ARM, and GitHub Actions builds amd64 |
| Root volume | **30GB gp3** | The 8GB default fills fast with Docker images and a database. 30GB is also the EBS free-tier ceiling |
| Security group | 22, 80, 443 tcp + 443 udp | Nothing reaches the box otherwise, whatever UFW says |
| Key pair | Import `~/.ssh/shipops_admin.pub` | — |

You log in as `ubuntu`, not `root`, so provisioning runs under `sudo`.

**One genuine AWS advantage:** security groups sit outside the OS, so unlike
UFW they cannot be bypassed by Docker's iptables rules. The trap described below
doesn't apply — a port you haven't opened in the security group is genuinely
shut, even if a container publishes it.

### The cost is 3–4× Hetzner, and that changes what you quote

Rough monthly, London or Ireland region:

| | Hetzner CX22 | AWS t3.small |
|---|---|---|
| Compute | ~£3.50 | ~£12 |
| Storage | included | ~£2 (30GB gp3) |
| Public IPv4 | ~£0.45 | ~£3 (charged since Feb 2024) |
| **Total** | **~£4** | **~£17** |

For one evening it's pennies either way — the instance is billed hourly and
you'll destroy it. It matters when you are budgeting a real deployment though:
"about £5/month" is true of a Hetzner CX22 and nowhere near true of AWS. Price
from the provider you are actually going to use.

If your AWS account is new, check what free tier you actually have before
assuming — AWS moved new accounts to a credit-based model, and the old "750
hours of t3.micro for 12 months" is not universal any more.

### On Hetzner specifically

Hetzner has been operating since 1997 and is one of the larger
European hosts — it isn't a fly-by-night. The real caveats are that its
anti-abuse enforcement is unusually aggressive (accounts get suspended for
crypto mining and spam, sometimes with little warning), support is email-only
with no phone line, and it's EU-only, which matters if a client needs US data
residency.

None of that is a reason to avoid it, but "I haven't used it" is a perfectly
good reason not to put something important on it first time. Rehearse wherever
you are already comfortable, then try Hetzner with a throwaway app.

---

## The lockout moment

`provision.sh` disables password authentication and root login, then restarts
sshd. This is the only genuinely dangerous step, and it is worth understanding
why it is survivable.

**You are not bricked if it goes wrong.** Hetzner's console gives you a
browser-based session straight to the machine, independent of SSH — as do
DigitalOcean and Vultr. But that console needs a root password, and if you built
the server key-only you don't have one. **Set a root password from the Hetzner
panel before you start**, so the escape hatch is actually usable.

Then the rule that costs nothing:

1. Terminal 1: run `provision.sh`.
2. **Do not close it.**
3. Terminal 2: `ssh -i ~/.ssh/shipops_admin shipops@<ip>` and confirm it works.
4. Only then close terminal 1.

The script itself validates the sshd config with `sshd -t` before restarting,
and aborts without applying anything if it fails. The container harness proved
that guard works, and found a bug where it misfired for an environmental
reason. It is a good guard. Use the second terminal anyway.

---

## DNS and the certificate — where the evening actually goes

This is the step that eats time, and almost always for the same two reasons.

### Leave Cloudflare's proxy OFF until the first certificate is issued

In the Cloudflare DNS panel, the A record has an orange cloud (proxied) or a
grey one (DNS only). **Grey it out for the first issuance.**

With the proxy on, Cloudflare terminates TLS itself and connects to your origin
separately. If Cloudflare's SSL mode is *Full (strict)* and Caddy hasn't got a
certificate yet, that connection fails and visitors get a 5xx — while Caddy is
still trying to complete a challenge through a proxy that is answering on its
behalf. It resolves eventually, or it doesn't, and either way you cannot tell
what is happening from the outside.

Grey cloud, let Caddy get a real certificate, confirm HTTPS works directly
against the origin. Then, if you want Cloudflare's proxy, turn it on and set SSL
mode to *Full (strict)* — which is now correct, because the origin genuinely has
a valid certificate.

### Use the staging endpoint first

Let's Encrypt rate-limits failed validations to **5 per hostname per hour**.
Three fumbled attempts and you are locked out for an hour, in the middle of the
evening you set aside for this.

`compose/Caddyfile` already has the staging line, commented:

```
acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
```

Uncomment it for the first run. Staging certificates are untrusted, so your
browser will warn — **that is the expected result**, not a failure. You are
testing issuance, not trust. When a staging cert appears, comment the line out,
`docker compose restart caddy`, and take the real one.

### Check DNS has actually landed before starting Caddy

```bash
dig +short app.yourdomain.com     # must print the server's IP
```

Caddy retries with exponential backoff. If you start it before DNS resolves, you
may wait several minutes for a retry that would have succeeded immediately.

---

## The Docker and UFW trap

This one catches nearly everyone, and it matters because it silently undoes a
security control you think you have.

**Docker writes its own iptables rules and bypasses UFW.** A published port —
anything in a compose `ports:` block — is reachable from the internet *whether
or not* UFW has a rule denying it. `ufw status` will cheerfully show the port as
denied while the whole internet can reach it.

The stack is built so this doesn't hurt you: **Caddy is the only service that
publishes ports**, and 80/443 are meant to be open. Postgres, Redis and the app
are on the internal Docker network with nothing published.

Where it bites is debugging. The obvious move when a client's database is
misbehaving is to add `ports: ["5432:5432"]` and connect from your laptop. That
exposes their production database to the entire internet, and UFW will not stop
it. Scanners find open Postgres in hours.

If you need remote access to a database, do it over SSH instead:

```bash
ssh -L 5432:localhost:5432 shipops@<ip>
```

Or, if you must publish, bind it to loopback only — `127.0.0.1:5432:5432` — so
Docker's rule cannot expose it externally.

---

## Registry authentication

The CI runner logs in to *push* the image. **The server has to log in separately
to pull it.** Nothing in the pipeline does that for you.

This was a real gap until recently, and it surfaces exactly
here: first deploy, `docker pull`, `denied`.

```bash
# On the server, as the shipops user:
/opt/shipops/scripts/registry-login.sh ghcr.io <your-github-username>
```

It reads the token from stdin so it never reaches your shell history. Create the
token at **github.com/settings/tokens** as a classic token with **`read:packages`
and nothing else**. This credential lives on a client's server; it must not be
able to reach your source, issues or actions.

Alternatively make the package public and skip this entirely — reasonable for
an open-source client app, not for a private product.

---

## Backups on AWS — use an instance role, not keys

Verified on a real instance. This is the better pattern whenever the server is
on EC2, and it is what you should quote for AWS clients.

1. **S3 bucket**, same region as the instance (no cross-region transfer costs).
   Block public access on, versioning off.
2. **Lifecycle rule** on the bucket: expire objects after your retention period.
   This is what replaces the script's delete permission.
3. **IAM policy** — note what is missing:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::YOUR-BUCKET" },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET/*" }
  ]
}
```

4. **IAM role** trusting the EC2 service, with that policy, attached to the
   instance via *Actions → Security → Modify IAM role*.
5. In `.env`: `BACKUP_BUCKET`, `AWS_DEFAULT_REGION`, and `BACKUP_PRUNE=off`.
   **No `AWS_ACCESS_KEY_ID`, no `AWS_SECRET_ACCESS_KEY`, no `AWS_ENDPOINT_URL`.**

Two things this buys you, both worth saying to a client:

**There is no long-lived credential on the server.** The CLI takes short-lived
tokens from instance metadata. Nothing to leak in a `.env` file, nothing to
rotate, and nothing useful to an attacker who reads the disk.

**The server cannot delete its own backups.** Omitting `s3:DeleteObject` means
a compromised machine can write and read backups but never destroy them — the
ransomware case. Retention becomes the bucket's job. Measured on the live
instance: `PutObject` allowed, `GetObject` allowed, `DeleteObject` refused with
`AccessDenied`, all objects intact.

The trade-off is real and worth knowing: you cannot tidy the bucket from the
server either. Mistakes are cleaned up from the console or another identity.

---

## Backups to Cloudflare R2

R2's free tier — 10GB storage and generous operation limits — covers essentially
every app at this scale, and unlike S3 there are no egress charges, which
matters when you restore.

1. Cloudflare dashboard → R2 → create a bucket.
2. Create an **R2 API token** with Object Read & Write, scoped to that bucket.
3. It gives you an access key ID, a secret, and an endpoint that looks like
   `https://<account-id>.r2.cloudflarestorage.com`.
4. In `/opt/shipops/.env`:

```
BACKUP_BUCKET=s3://your-bucket-name
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com
AWS_DEFAULT_REGION=auto
```

`AWS_DEFAULT_REGION=auto` is not a placeholder — it is the literal value R2
expects.

**If uploads fail with a checksum or unsupported-header error:** recent AWS CLI
v2 releases send integrity checksums that some S3-compatible providers reject.
The documented escape is
`AWS_REQUEST_CHECKSUM_CALCULATION=when_required` in the environment. I have not
hit this against R2 with CLI 2.36, so treat it as a remedy if you see the
symptom rather than something to set pre-emptively.

---

## Order of operations

Deviating from this order is what turns two hours into five.

| # | Step | Why here |
|---|---|---|
| 1 | `sandbox/test-provision.sh` and `sandbox/test-engines.sh` locally | Free, catches anything broken since last time |
| 2 | Create the server, set a root password in the panel | The escape hatch has to exist before you need it |
| 3 | `provision.sh`, verify in a second terminal | The dangerous step, done while you're fresh |
| 4 | Add the CI public key to `authorized_keys` | Before CI needs it |
| 5 | Point DNS, confirm with `dig` | Certificates cannot work before this |
| 6 | Copy the stack to `/opt/shipops`, fill in `.env`, `chmod 600` | — |
| 7 | `registry-login.sh` if the package is private | Before the first pull, not after it fails |
| 8 | Start with **staging** ACME, confirm a cert appears | Protects the rate limit |
| 9 | Switch to production ACME, restart Caddy | — |
| 10 | `deploy.sh <tag>` | — |
| 11 | Create the R2 bucket, run `backup.sh` for real | — |
| 12 | `restore-test.sh` | The proof you sell |
| 13 | `install-schedules.sh`, then `systemctl list-timers` | — |
| 14 | Push a trivial commit, watch the pipeline deploy it | The end-to-end test |

---

## What "it worked" actually looks like

Do not accept "the site loads" as done. Every one of these should pass:

```bash
# Certificate is real, and issued by Let's Encrypt rather than staging
curl -vI https://app.yourdomain.com 2>&1 | grep -E 'issuer|HTTP/'

# The app is genuinely talking to its database
curl -s https://app.yourdomain.com/healthz

# Database is NOT reachable from outside — this must fail
nc -zv <server-ip> 5432

# Password auth is genuinely off — this must be rejected
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shipops@<ip>

# fail2ban is actually running, not merely installed
sudo fail2ban-client status sshd

# A backup exists in the bucket, and restores
aws s3 ls s3://your-bucket/ --recursive --endpoint-url https://<id>.r2.cloudflarestorage.com
/opt/shipops/scripts/restore-test.sh

# Timers are scheduled
systemctl list-timers 'shipops-*'

# Swap exists and the disk is not already filling
free -h && df -h
```

Then the one that matters most: **push a commit and watch it deploy.** Nothing
else proves the whole chain — build, push, SSH, blue/green, health gate — is
actually wired together.

---

## When it goes wrong

| Symptom | Almost always |
|---|---|
| `exec format error` on every container | ARM instance (CAX / t4g), amd64 image. Rebuild as x86 |
| Nothing reachable on 80/443, UFW looks fine | AWS security group not opened. It sits in front of the OS |
| Locked out of an EC2 instance | `AllowUsers` dropped `ubuntu`. Use `--keep-user ubuntu` next time; recover by detaching the root EBS volume onto another instance |
| Caddy loops, no certificate | DNS not resolving yet, or Cloudflare proxy on. Grey-cloud it, `dig` it |
| `too many failed authorizations` | Let's Encrypt rate limit. Wait the hour, use staging |
| `denied` on `docker pull` | Server not logged in to the registry — `registry-login.sh` |
| Deploy passes but the site 502s | App is up but unhealthy. `docker logs`, check `/healthz` hits the DB |
| `backup.sh: aws: command not found` | Old provisioning run — re-run `provision.sh`, it's idempotent |
| Upload succeeds, `head-object` size mismatch | Wrong endpoint or region. `AWS_DEFAULT_REGION=auto` for R2 |
| Locked out of SSH | Hetzner console + the root password you set in step 2 |
| Everything slow, OOM in `dmesg` | Swap missing or too small. `free -h`, check `/swapfile` |

---

## Afterwards

**Destroy the server the same night** unless you're keeping it. Hetzner bills
hourly; a forgotten box is £4/month of nothing. Snapshot it first if you want a
starting point (snapshots are billed too, but pennies).

Better: keep it a week and let the nightly backup and Sunday restore test run
unattended. If both fire on schedule with no intervention, that is the strongest
evidence you can get that the whole thing works — and it is the one thing none
of the local harnesses can prove.

Then write down what actually went wrong and fold it into `docs/verification.md`.
The second server should take forty minutes.
