#!/usr/bin/env bash
# Called only after a validated private config has been installed.
set -Eeuo pipefail
fail() { printf '%s\n' "$*" >&2; exit 1; }
NODE_IP=${1:?Missing node IP}
HELPER=/usr/local/lib/easytier-bootstrap/profile.py
bash /usr/local/lib/easytier-bootstrap/services.sh mesh-start
# Limit newly added UFW rules to the mesh interface and existing sshd ports.
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
  while read -r PORT; do
    ufw allow in on etvpn0 to any port "$PORT" proto tcp
  done < <(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}')
fi
bash /usr/local/lib/easytier-bootstrap/services.sh status
python3 "$HELPER" health --ip "$NODE_IP" --timeout 60
ip -4 -o addr show dev etvpn0 | grep -qF " $NODE_IP/" || fail 'Expected VPN interface address is missing.'
SSH_PORT=$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2; exit}')
ss -H -ltn | awk -v ip="$NODE_IP" -v port="$SSH_PORT" '
  $4 == "0.0.0.0:"port || $4 == "*:"port || $4 == ip":"port {found=1}
  END {exit !found}' || fail 'SSH is not listening on the VPN IPv4 address; review ListenAddress/socket settings.'
printf '\nEasyTier mesh and SSH listener verified. Service health checks passed.\n'
printf 'Connect using an existing permitted account: ssh -p %s USER@%s\n' "$SSH_PORT" "$NODE_IP"
printf 'Password login enabled. Use an existing account with a password; account restrictions and firewall rules still apply.\n'
