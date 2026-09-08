#!/usr/bin/env bash
# Dry-run provision.sh inside an Ubuntu container.
#
# This does NOT replace running it on a real VPS - a container has no init
# system, no kernel firewall and no sshd to restart, so roughly a third of the
# script cannot execute here. What it DOES catch is everything that would waste
# the first half of your throwaway-server evening:
#
#   * wrong or renamed apt package names
#   * a syntax error in the generated sshd_config (validated with `sshd -t`)
#   * a malformed sudoers drop-in (validated with `visudo -cf`)
#   * a fail2ban jail that will not parse (validated with `fail2ban-client -t`)
#   * a broken Docker apt repository or GPG key setup
#   * shell logic errors on a genuinely fresh Ubuntu
#
# systemctl and ufw are stubbed, because neither can work without an init system
# or NET_ADMIN. Every stubbed call is logged so you can read back what the script
# would have done.
#
# Usage:  ./test-provision.sh          # takes 3-6 minutes, mostly apt

set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="${HERE}/../scripts/provision.sh"
C=shipops-provision-test
IMAGE="${IMAGE:-ubuntu:24.04}"

PASS=0; FAIL=0
good() { PASS=$((PASS+1)); printf '  \033[1;32m OK \033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT

[[ -f "$PROVISION" ]] || { echo "provision.sh not found at $PROVISION" >&2; exit 1; }

say "Starting $IMAGE"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" "$IMAGE" sleep infinity >/dev/null

docker exec "$C" bash -c 'apt-get update -qq >/dev/null 2>&1' || true

say "Installing the validators the test needs (openssh-server, sudo, fail2ban)"
# These are installed FIRST so their real config-checking binaries exist to
# validate what provision.sh writes later.
docker exec -e DEBIAN_FRONTEND=noninteractive "$C" bash -c \
  'apt-get install -y -qq openssh-server sudo fail2ban curl ca-certificates gnupg >/dev/null 2>&1' \
  && good "validators installed" || bad "could not install validators"

say "Stubbing what a container cannot provide"
docker exec "$C" bash -c 'mkdir -p /stub /var/log/stub && cat > /stub/systemctl <<'\''EOF'\''
#!/bin/sh
echo "systemctl $*" >> /var/log/stub/calls.log
exit 0
EOF
cat > /stub/ufw <<'\''EOF'\''
#!/bin/sh
echo "ufw $*" >> /var/log/stub/calls.log
[ "$1" = "status" ] && echo "Status: active (stubbed)"
exit 0
EOF
cat > /stub/sysctl <<'\''EOF'\''
#!/bin/sh
echo "sysctl $*" >> /var/log/stub/calls.log
exit 0
EOF
cat > /stub/swapon <<'\''EOF'\''
#!/bin/sh
echo "swapon $*" >> /var/log/stub/calls.log
exit 0
EOF
cat > /stub/mkswap <<'\''EOF'\''
#!/bin/sh
echo "mkswap $*" >> /var/log/stub/calls.log
exit 0
EOF
chmod +x /stub/*' && good "stubs in place (systemctl, ufw, sysctl, swapon, mkswap)"

say "Running provision.sh"
docker cp "$PROVISION" "$C:/root/provision.sh" >/dev/null
docker exec "$C" chmod +x /root/provision.sh

KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYFORPROVISIONDRYRUNONLY000000 shipops-dryrun"
if docker exec -e PATH="/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
     "$C" /root/provision.sh --ssh-key "$KEY" > /tmp/provision-out.log 2>&1; then
  good "provision.sh ran to completion"
else
  bad "provision.sh exited non-zero - last 25 lines:"
  tail -25 /tmp/provision-out.log | sed 's/^/       /'
fi

say "Validating what it produced"

docker exec "$C" test -f /etc/ssh/sshd_config.d/99-shipops.conf \
  && good "sshd drop-in written" || bad "sshd drop-in missing"

# The real test: does OpenSSH accept the config we generated?
if docker exec "$C" sshd -t 2>/tmp/sshd-err; then
  good "sshd config is valid (sshd -t)"
else
  bad "sshd config REJECTED - this would lock you out of a real server:"
  sed 's/^/       /' /tmp/sshd-err
fi

# --keep-user is the EC2 lockout fallback. If it silently stopped working, the
# first sign would be an unreachable instance.
docker exec "$C" bash -c 'grep -q "^AllowUsers shipops$" /etc/ssh/sshd_config.d/99-shipops.conf' \
  && good "AllowUsers restricted to the deploy user by default" \
  || bad "default AllowUsers line is not what was expected"

docker exec -e PATH="/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$C" /root/provision.sh --ssh-key "$KEY" --keep-user ubuntu >/dev/null 2>&1 || true
if docker exec "$C" bash -c 'grep -q "^AllowUsers shipops ubuntu$" /etc/ssh/sshd_config.d/99-shipops.conf'; then
  if docker exec "$C" sshd -t 2>/dev/null; then
    good "--keep-user adds the fallback account and still validates"
  else
    bad "--keep-user produced an sshd config that OpenSSH rejects"
  fi
else
  bad "--keep-user did not add the fallback account to AllowUsers"
fi

if docker exec "$C" visudo -cf /etc/sudoers.d/90-shipops >/dev/null 2>&1; then
  good "sudoers drop-in is valid (visudo -cf)"
else
  bad "sudoers drop-in is INVALID - sudo would break for the deploy user"
fi

docker exec "$C" grep -q 'shipops' /home/shipops/.ssh/authorized_keys 2>/dev/null \
  && good "deploy key installed for the shipops user" || bad "authorized_keys missing or empty"

perms=$(docker exec "$C" stat -c '%a' /home/shipops/.ssh/authorized_keys 2>/dev/null || echo "")
[[ "$perms" == "600" ]] && good "authorized_keys is mode 600" || bad "authorized_keys mode is '${perms:-missing}', expected 600"

# Check OUR jail, not merely that fail2ban parses - a stock install parses
# fine and would have passed this test while provision.sh did nothing.
if docker exec "$C" grep -q 'bantime' /etc/fail2ban/jail.local 2>/dev/null; then
  if docker exec "$C" fail2ban-client -t >/dev/null 2>&1; then
    good "shipops fail2ban jail written and parses"
  else
    bad "jail.local written but fail2ban does NOT parse it"
  fi
else
  bad "jail.local not written by provision.sh"
fi

# Likewise: 20auto-upgrades ships with Ubuntu. Assert on the file we add.
docker exec "$C" test -f /etc/apt/apt.conf.d/51shipops-unattended \
  && good "shipops unattended-upgrades policy written" \
  || bad "51shipops-unattended missing - security updates not configured by us"

docker exec "$C" bash -c 'command -v docker >/dev/null' \
  && good "docker engine installed from the official repo" || bad "docker not installed"

docker exec "$C" bash -c 'docker --version >/dev/null 2>&1' \
  && good "docker binary runs" || bad "docker binary present but not runnable"

docker exec "$C" test -f /etc/docker/daemon.json \
  && good "docker log rotation configured" || bad "/etc/docker/daemon.json missing"

docker exec "$C" test -d /opt/shipops \
  && good "/opt/shipops created" || bad "/opt/shipops missing"

docker exec "$C" test -x /etc/cron.weekly/shipops-docker-prune \
  && good "weekly docker prune installed" || bad "docker prune cron missing"

# backup.sh shells out to `aws`. If provisioning does not install it, backups
# fail silently at 03:20 with nobody watching.
if docker exec "$C" bash -c 'command -v aws >/dev/null'; then
  good "aws cli installed ($(docker exec "$C" aws --version 2>&1 | head -1))"
else
  bad "aws cli MISSING - backup.sh could not upload anything"
fi

say "Idempotency - running it a second time"
if docker exec -e PATH="/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
     "$C" /root/provision.sh --ssh-key "$KEY" > /tmp/provision-out2.log 2>&1; then
  good "second run succeeded (safe to re-run)"
  dupes=$(docker exec "$C" grep -c 'shipops-dryrun' /home/shipops/.ssh/authorized_keys 2>/dev/null || echo 0)
  [[ "$dupes" == "1" ]] && good "deploy key not duplicated on re-run" || bad "key appears $dupes times after two runs"
else
  bad "second run failed - the script is not idempotent:"
  tail -20 /tmp/provision-out2.log | sed 's/^/       /'
fi

say "What was stubbed (would run for real on a VPS)"
docker exec "$C" sort -u /var/log/stub/calls.log 2>/dev/null | sed 's/^/  /' || echo "  (none logged)"

say "Result: ${PASS} passed, ${FAIL} failed"
cat <<'EOF'

Still requires a real server, and is NOT covered by this test:
  - sshd actually restarting, and key-only login working
  - ufw enforcing rules against real traffic
  - fail2ban banning a real IP
  - the swapfile being created and used
  - systemd timers firing (install-schedules.sh)
  - Let's Encrypt issuing a certificate

EOF
(( FAIL == 0 )) || exit 1
