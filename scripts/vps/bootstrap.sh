#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE step 1: harden a fresh Ubuntu 24.04 LTS VPS.
#
#   sudo scripts/vps/bootstrap.sh --ssh-pubkey-file ~/deploy.pub [options] [--dry-run]
#
# Options:
#   --deploy-user NAME        unprivileged deploy account (default: deploy)
#   --ssh-pubkey-file FILE    public key for the deploy user (REQUIRED - password login is
#                             disabled, so without a key you would lock yourself out)
#   --ssh-pubkey 'ssh-ed25519 AAAA...'   same, inline
#   --ssh-port N              SSH port (default 22)
#   --ssh-allow-from CIDR     restrict SSH in ufw to this source (repeatable; default: anywhere)
#   --timezone TZ             system timezone (default: UTC - the platform stores UTC)
#   --dry-run                 print what would change, change nothing
#
# Idempotent: safe to re-run. Does: apt upgrade, ufw (22/80/443 only), fail2ban,
# unattended-upgrades, key-only SSH (root login off), deploy user + a narrow sudoers
# rule (only reload php-fpm/nginx and control the r007 supervisor group).
# Docs: architecture/25-vps-production-deployment.md, runbooks/server-installation.md
set -euo pipefail
SCRIPT_TAG="bootstrap"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"

DEPLOY_USER="deploy"; PUBKEY=""; SSH_PORT=22; TZ_NAME="UTC"; ALLOW_FROM=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-user) DEPLOY_USER="${2:?}"; shift 2 ;;
    --ssh-pubkey-file) [[ -f "${2:?}" ]] || die "no such file: $2"; PUBKEY="$(cat "$2")"; shift 2 ;;
    --ssh-pubkey) PUBKEY="${2:?}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
    --ssh-allow-from) ALLOW_FROM+=("${2:?}"); shift 2 ;;
    --timezone) TZ_NAME="${2:?}"; shift 2 ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$PUBKEY" ]] || die "an SSH public key is required (--ssh-pubkey-file / --ssh-pubkey)"
[[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com)[[:space:]] ]] \
  || die "that does not look like an SSH PUBLIC key"
[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid deploy user name"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "invalid ssh port"
need_root
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "tested on Ubuntu 24.04 LTS; detected ${PRETTY_NAME:-unknown}"
fi

export DEBIAN_FRONTEND=noninteractive
log "1/7 packages"
run apt-get update -y
run apt-get -y -o Dpkg::Options::=--force-confold upgrade
run apt-get install -y ufw fail2ban unattended-upgrades apt-listchanges ca-certificates curl gnupg sudo chrony

log "2/7 timezone + time sync"
run timedatectl set-timezone "$TZ_NAME"
run systemctl enable --now chrony

log "3/7 deploy user ($DEPLOY_USER)"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  run adduser --disabled-password --gecos "007 Resort deploy" "$DEPLOY_USER"
fi
run install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
AK="/home/$DEPLOY_USER/.ssh/authorized_keys"
if is_dry; then
  echo "[dry-run] ensure public key present in $AK" >&2
else
  touch "$AK"; chmod 600 "$AK"; chown "$DEPLOY_USER:$DEPLOY_USER" "$AK"
  grep -qxF "$PUBKEY" "$AK" || { printf '%s\n' "$PUBKEY" >>"$AK"; log "added key to $AK"; }
fi

log "4/7 sudoers (narrow, for deploy.sh only)"
SUDOERS_TMP="$(mktemp)"
cat >"$SUDOERS_TMP" <<SUDO
# Managed by 007resort-infrastructure/scripts/vps/bootstrap.sh
$DEPLOY_USER ALL=(root) NOPASSWD: /usr/bin/supervisorctl reread, /usr/bin/supervisorctl update, /usr/bin/supervisorctl status, /usr/bin/supervisorctl status r007\\:*, /usr/bin/supervisorctl restart r007\\:*, /usr/bin/supervisorctl stop r007\\:*, /usr/bin/supervisorctl start r007\\:*, /usr/bin/systemctl reload php8.4-fpm, /usr/bin/systemctl reload nginx
SUDO
if is_dry; then echo "[dry-run] install /etc/sudoers.d/r007-deploy" >&2
else
  visudo -cf "$SUDOERS_TMP" >/dev/null || die "generated sudoers file is invalid"
  install -m 440 "$SUDOERS_TMP" /etc/sudoers.d/r007-deploy
fi
rm -f "$SUDOERS_TMP"

log "5/7 SSH: key-only, no root login"
write_file /etc/ssh/sshd_config.d/99-r007-hardening.conf 644 <<SSHD
# Managed by 007resort-infrastructure/scripts/vps/bootstrap.sh
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AllowUsers $DEPLOY_USER
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD
if ! is_dry; then
  sshd -t || die "sshd config test failed; the new file was written but NOT applied - fix /etc/ssh/sshd_config.d/99-r007-hardening.conf"
  warn "applying SSH hardening: keep this session open and test a NEW login as $DEPLOY_USER before closing it"
fi
if [[ "$SSH_PORT" != "22" ]]; then
  # Ubuntu 24.04 uses socket activation: the listening port lives in ssh.socket, not sshd_config.
  run install -d /etc/systemd/system/ssh.socket.d
  write_file /etc/systemd/system/ssh.socket.d/r007-port.conf 644 <<SOCK
[Socket]
ListenStream=
ListenStream=$SSH_PORT
SOCK
  run systemctl daemon-reload
  run systemctl restart ssh.socket
fi
run systemctl reload ssh

log "6/7 firewall (ufw): deny in, allow SSH/80/443"
run ufw default deny incoming
run ufw default allow outgoing
if [[ ${#ALLOW_FROM[@]} -gt 0 ]]; then
  for cidr in "${ALLOW_FROM[@]}"; do run ufw allow from "$cidr" to any port "$SSH_PORT" proto tcp; done
else
  run ufw allow "$SSH_PORT/tcp"
fi
run ufw allow 80/tcp
run ufw allow 443/tcp
run ufw --force enable

log "7/7 fail2ban + unattended-upgrades"
write_file /etc/fail2ban/jail.d/r007.local 644 <<F2B
# Managed by 007resort-infrastructure/scripts/vps/bootstrap.sh
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = $SSH_PORT
F2B
run systemctl enable --now fail2ban
run systemctl restart fail2ban
write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'AU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AU
write_file /etc/apt/apt.conf.d/52r007-unattended 644 <<'UU'
// Security updates only; reboot only in the quiet window (server time is UTC).
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
UU
run systemctl enable --now unattended-upgrades

log "done. Next: sudo scripts/vps/provision-stack.sh --domain <api.example.com> --email <ops@example.com>"
