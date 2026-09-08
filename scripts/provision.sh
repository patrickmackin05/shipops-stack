#!/usr/bin/env bash
# ShipOps VPS provisioning - fresh Ubuntu 22.04/24.04 to hardened Docker host.
#
# Usage (as root on a brand new server):
#   curl -fsSL <raw-url>/provision.sh -o provision.sh
#   chmod +x provision.sh
#   ./provision.sh --ssh-key "ssh-ed25519 AAAA... shipops"
#
# Idempotent: safe to re-run. Takes about 3 minutes on a Hetzner CX22.
#
# SAFETY: this script disables SSH password authentication and root login. It
# refuses to do so unless a working public key is already installed, because
# the alternative is locking yourself out of a server you cannot console into.

set -Eeuo pipefail

DEPLOY_USER="${DEPLOY_USER:-shipops}"
SSH_PORT="${SSH_PORT:-22}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SSH_KEY=""
# An extra account to leave permitted in sshd's AllowUsers. Exists for one
# reason: on AWS EC2 you log in as `ubuntu`, and locking that account out is
# close to unrecoverable. Hetzner and DigitalOcean give you a browser console
# with a root password; EC2's Serial Console needs account-level enablement, a
# Nitro instance and an OS password the Ubuntu images do not set, and Instance
# Connect arrives over SSH so AllowUsers blocks it too. The fallback there is
# detaching the EBS volume and mounting it on another instance.
#   --keep-user ubuntu
# Remove it once you have confirmed the deploy user works, by deleting the name
# from /etc/ssh/sshd_config.d/99-shipops.conf and restarting ssh.
KEEP_USER="${KEEP_USER:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)  SSH_KEY="$2"; shift 2 ;;
    --user)     DEPLOY_USER="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --keep-user) KEEP_USER="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -n "$SSH_KEY" ]] || die "--ssh-key is required (the public key you will deploy with)"
[[ "$SSH_KEY" == ssh-* ]] || die "--ssh-key does not look like a public key"

export DEBIAN_FRONTEND=noninteractive

# --- 1. base packages -----------------------------------------------------
log "updating base system"
apt-get update -qq
apt-get upgrade -y -qq
# `cron` is explicit rather than assumed: Ubuntu's server images ship it, but
# minimal and cloud-optimised images do not, and without it /etc/cron.weekly
# does not exist - which used to abort provisioning at the last step. Worse, a
# bare mkdir would leave the prune job sitting in a directory nothing reads.
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release ufw fail2ban cron unzip \
  unattended-upgrades apt-listchanges htop ncdu jq rsync \
  postgresql-client age

# --- 2. deploy user -------------------------------------------------------
if ! id -u "$DEPLOY_USER" &>/dev/null; then
  log "creating user $DEPLOY_USER"
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
else
  log "user $DEPLOY_USER already exists"
fi
usermod -aG sudo "$DEPLOY_USER"

# Passwordless sudo: the deploy user has no password (--disabled-password), so
# without this it cannot use sudo at all and CI deploys break.
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEPLOY_USER"
chmod 440 "/etc/sudoers.d/90-$DEPLOY_USER"
visudo -cf "/etc/sudoers.d/90-$DEPLOY_USER" >/dev/null || die "sudoers file invalid"

log "installing SSH key"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
grep -qxF "$SSH_KEY" "/home/$DEPLOY_USER/.ssh/authorized_keys" \
  || echo "$SSH_KEY" >> "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"

# --- 3. SSH hardening -----------------------------------------------------
# Guard against lockout: only proceed if the key file is non-empty.
[[ -s "/home/$DEPLOY_USER/.ssh/authorized_keys" ]] \
  || die "authorized_keys is empty - refusing to disable password auth"

log "hardening sshd"
cat > /etc/ssh/sshd_config.d/99-shipops.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $DEPLOY_USER${KEEP_USER:+ $KEEP_USER}
EOF

# `sshd -t` needs the privilege separation directory to exist. On a running
# server it does, because sshd's own startup creates it - but not in a
# container, a rescue image, or a minimal cloud image where sshd has not
# started yet. Creating it here is exactly what sshd's init does, and it stops
# the lockout guard failing for a reason that has nothing to do with the config
# being valid. Found by sandbox/test-provision.sh.
install -d -m 0755 /run/sshd

sshd -t || die "sshd config invalid - NOT restarting ssh, fix before disconnecting"
systemctl restart ssh 2>/dev/null || systemctl restart sshd
warn "SSH is now key-only on port $SSH_PORT as '$DEPLOY_USER'."
if [[ -n "$KEEP_USER" ]]; then
  warn "'$KEEP_USER' is also still permitted, as a deliberate fallback."
  warn "Remove it from /etc/ssh/sshd_config.d/99-shipops.conf once you are sure."
fi
warn "Open a SECOND terminal and confirm you can log in BEFORE closing this one."

# --- 4. firewall ----------------------------------------------------------
log "configuring ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'ssh'
ufw allow 80/tcp   comment 'http'
ufw allow 443/tcp  comment 'https'
ufw allow 443/udp  comment 'http3'
ufw --force enable

# --- 5. fail2ban ----------------------------------------------------------
log "configuring fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# --- 6. automatic security updates ---------------------------------------
log "enabling unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/51shipops-unattended <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Reboots are scheduled, not automatic - an unannounced 2am reboot during a
// deploy is its own outage. Check `/var/run/reboot-required` monthly instead.
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# --- 7. swap --------------------------------------------------------------
# A 4GB VPS running Postgres + Node + a Docker build will OOM without swap.
# The OOM killer usually picks Postgres, because it has the largest RSS.
if [[ ! -f /swapfile ]]; then
  log "creating ${SWAP_SIZE} swapfile"
  fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  log "swapfile already present"
fi
sysctl -qw vm.swappiness=10
grep -q 'vm.swappiness' /etc/sysctl.d/99-shipops.conf 2>/dev/null || \
  echo 'vm.swappiness=10' >> /etc/sysctl.d/99-shipops.conf

# --- 8. docker ------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log "installing docker engine"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
else
  log "docker already installed"
fi

usermod -aG docker "$DEPLOY_USER"
systemctl enable --now docker

# Docker's default logging has no cap. Set a global default so that even
# containers added later without a logging block cannot fill the disk.
log "configuring docker daemon defaults"
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl restart docker

# --- 8b. aws cli ----------------------------------------------------------
# backup.sh uploads with `aws s3`, so without this the whole backup story fails
# on the first nightly run - and it fails at 03:20 with nobody watching.
# Installed from the official v2 bundle rather than apt, because Ubuntu ships
# the long-deprecated v1, which handles S3-compatible endpoints (Cloudflare R2,
# Backblaze) badly.
if ! command -v aws &>/dev/null; then
  log "installing aws cli v2"
  AWS_ARCH="$(uname -m)"   # x86_64 or aarch64; the installer uses both names
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "$tmp/awscliv2.zip" \
    && unzip -q "$tmp/awscliv2.zip" -d "$tmp" \
    && "$tmp/aws/install" --update >/dev/null \
    && log "aws cli installed: $(aws --version 2>&1)" \
    || warn "aws cli install failed - backups will not upload until this is fixed"
  rm -rf "$tmp"
else
  log "aws cli already installed"
fi

# --- 9. journald cap ------------------------------------------------------
sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
systemctl restart systemd-journald

# --- 10. app directory ----------------------------------------------------
log "creating /opt/shipops"
install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/shipops
install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/shipops/scripts

# --- 11. weekly docker prune ---------------------------------------------
# Old images from every past deploy will silently consume the entire disk.
# Keep 7 days so rollback targets survive.
install -d -m 0755 /etc/cron.weekly
cat > /etc/cron.weekly/shipops-docker-prune <<'EOF'
#!/bin/sh
docker image prune -af --filter "until=168h" >/dev/null 2>&1
docker builder prune -af --filter "until=168h" >/dev/null 2>&1
EOF
chmod +x /etc/cron.weekly/shipops-docker-prune

log "provisioning complete"
cat <<EOF

  Host:        $(hostname -f 2>/dev/null || hostname)
  Deploy user: $DEPLOY_USER
  SSH:         ssh -p $SSH_PORT $DEPLOY_USER@<ip>
  Docker:      $(docker --version)
  Firewall:    $(ufw status | head -1)

  NEXT:
    1. Verify SSH login in a second terminal NOW.
    2. Point the domain's A record at this server (DNS-only, not proxied,
       until the first certificate has been issued).
    3. Copy .env and docker-compose.prod.yml into /opt/shipops/.
    4. If the image registry is private, authenticate this server to it:
         /opt/shipops/scripts/registry-login.sh ghcr.io <github-user>
    5. Run deploy.sh.

EOF
