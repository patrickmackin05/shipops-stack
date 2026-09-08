#!/usr/bin/env bash
# Install the ShipOps maintenance schedule as systemd timers.
#
# Run once, as root, after the stack is up and running:
#   sudo /opt/shipops/scripts/install-schedules.sh
#
# systemd timers rather than cron, for three reasons that matter in practice:
#   * `systemctl list-timers` shows the next and last run at a glance. Cron
#     tells you nothing until something has already gone wrong.
#   * Output goes to the journal automatically, so a failed backup leaves a
#     trail you can actually read: `journalctl -u shipops-backup`.
#   * Persistent=true catches up a missed run after a reboot. A cron job that
#     was due while the box was down simply never happens.
#
# Schedule:
#   03:20 daily  - backup.sh        (nightly dump to the client's bucket)
#   04:40 Sunday - restore-test.sh  (weekly proof the backups are restorable)

set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/shipops}"
DEPLOY_USER="${DEPLOY_USER:-shipops}"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ -x "$STACK_DIR/scripts/backup.sh" ]] || { echo "backup.sh not found in $STACK_DIR/scripts" >&2; exit 1; }

write_unit() {
  cat > "/etc/systemd/system/$1"
  echo "  wrote /etc/systemd/system/$1"
}

write_unit shipops-backup.service <<EOF
[Unit]
Description=ShipOps nightly database backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=$DEPLOY_USER
WorkingDirectory=$STACK_DIR
ExecStart=$STACK_DIR/scripts/backup.sh
# A backup that hangs must not block the next night's run.
TimeoutStartSec=3600
EOF

write_unit shipops-backup.timer <<'EOF'
[Unit]
Description=Run the ShipOps backup nightly

[Timer]
OnCalendar=*-*-* 03:20:00
# Spread load so every ShipOps client does not hit object storage at once.
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

write_unit shipops-restore-test.service <<EOF
[Unit]
Description=ShipOps weekly backup restore verification
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=$DEPLOY_USER
WorkingDirectory=$STACK_DIR
ExecStart=$STACK_DIR/scripts/restore-test.sh
TimeoutStartSec=3600
EOF

write_unit shipops-restore-test.timer <<'EOF'
[Unit]
Description=Verify weekly that the backups actually restore

[Timer]
OnCalendar=Sun *-*-* 04:40:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now shipops-backup.timer shipops-restore-test.timer

echo
echo "Installed. Next scheduled runs:"
systemctl list-timers 'shipops-*' --no-pager

cat <<EOF

Useful commands:
  Run a backup right now:      sudo systemctl start shipops-backup.service
  Watch it:                    journalctl -u shipops-backup -f
  Verify restores right now:   sudo systemctl start shipops-restore-test.service
  See the schedule:            systemctl list-timers 'shipops-*'

EOF
