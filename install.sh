#!/usr/bin/env bash
# Ubuntu/Debian installer. Network credentials are read only from a private JSON file.
set -Eeuo pipefail
set +x
umask 077
VERSION=2.6.4
PROFILE=''
NODE_IP=''
SSH_USER=''
SSH_KEY=''
WORK=''
usage() {
  cat <<'HELP'
Usage: sudo bash install.sh --profile /root/network.private.json --ip UNUSED_IPV4
       [--ssh-user EXISTING_USER --ssh-key /path/to/key.pub]
Installs EasyTier 2.6.4 and OpenSSH on Ubuntu/Debian (x86_64/aarch64).
Existing SSH authentication settings are preserved. Existing installs are not overwritten.
HELP
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$WORK" ]]; then rm -rf -- "$WORK"; fi; }
trap cleanup EXIT
trap 'printf "Installation stopped at line %s. No success claimed; inspect local services.\n" "$LINENO" >&2' ERR
while (($#)); do
  case "$1" in
    --profile|--ip|--ssh-user|--ssh-key)
      (($# >= 2)) || fail "Missing value for $1"
      case "$1" in
        --profile) PROFILE=$2 ;; --ip) NODE_IP=$2 ;;
        --ssh-user) SSH_USER=$2 ;; --ssh-key) SSH_KEY=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option; use --help" ;;
  esac
done
[[ $EUID == 0 ]] || fail 'Run with sudo or as root.'
[[ $(uname -s) == Linux ]] || fail 'Only Linux is supported.'
[[ -f /etc/os-release ]] || fail 'Missing OS identification.'
. /etc/os-release
[[ $ID == ubuntu || $ID == debian ]] || fail 'Only Ubuntu and Debian are supported.'
[[ -d /run/systemd/system ]] || fail 'A running systemd instance is required.'
[[ -c /dev/net/tun ]] || fail 'TUN is required; enable it in the VM/container host first.'
[[ -n "$PROFILE" && -f "$PROFILE" && -n "$NODE_IP" ]] || { usage; exit 1; }
[[ -z "$SSH_USER" && -z "$SSH_KEY" || -n "$SSH_USER" && -f "$SSH_KEY" ]] || fail 'Specify SSH user and public key together.'
if [[ -n "$SSH_USER" ]]; then
  [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || fail 'Unsupported SSH username.'
  id "$SSH_USER" >/dev/null || fail 'SSH user must already exist.'
fi
case $(uname -m) in
  x86_64) ARCH=x86_64; SHA=61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6 ;;
  aarch64|arm64) ARCH=aarch64; SHA=f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f ;;
  *) fail 'Only x86_64 and ARM64 are supported.' ;;
esac
CONFIG=/etc/easytier-bootstrap/config.toml
UNIT=/etc/systemd/system/easytier-bootstrap.service
if [[ -e "$CONFIG" || -e "$UNIT" ]]; then
  fail 'Existing setup found; inspect or remove it manually before installing.'
fi
if pgrep -x easytier-core >/dev/null; then
  fail 'Another EasyTier instance is running. Resolve it before installation.'
fi
if [[ -e /usr/local/bin/easytier-core && ! -f "$UNIT" ]]; then
  fail 'Unmanaged EasyTier binaries already exist; refusing to overwrite.'
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl unzip python3 openssh-server iproute2 procps
WORK=$(mktemp -d)
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HELPER="$WORK/profile.py"
if [[ -f "$HERE/profile.py" ]]; then
  cp -- "$HERE/profile.py" "$HELPER"
else
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    'https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/profile.py' -o "$HELPER"
fi
printf '%s  %s\n' '834f296968bf03fcede7b19518e47c1778d3f76d9a42b5170117bd435964af22' "$HELPER" | sha256sum -c - >/dev/null
python3 "$HELPER" render --profile "$PROFILE" --ip "$NODE_IP" --output "$WORK/config.toml"
if [[ -n "$SSH_KEY" ]]; then
  ssh-keygen -lf "$SSH_KEY" >/dev/null || fail 'Invalid SSH public key.'
  [[ $(wc -l < "$SSH_KEY") -le 1 ]] || fail 'Provide a single SSH public key.'
  read -r KEY_TYPE KEY_BODY _ < "$SSH_KEY" || true
  [[ "$KEY_TYPE" == ssh-* || "$KEY_TYPE" == ecdsa-* || "$KEY_TYPE" == sk-* ]] || fail 'Provide a plain SSH public key without options.'
fi
ASSET="easytier-linux-${ARCH}-v${VERSION}"
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
  "https://github.com/EasyTier/EasyTier/releases/download/v${VERSION}/${ASSET}.zip" -o "$WORK/release.zip"
printf '%s  %s\n' "$SHA" "$WORK/release.zip" | sha256sum -c - >/dev/null
unzip -q "$WORK/release.zip" -d "$WORK/release"
CORE=$(find "$WORK/release" -type f -name easytier-core -print -quit)
CLI=$(find "$WORK/release" -type f -name easytier-cli -print -quit)
[[ -n "$CORE" && -n "$CLI" ]] || fail 'Release binaries missing.'
chmod 755 "$CORE" "$CLI"
"$CORE" --version
if [[ -n "$SSH_USER" ]]; then
  USER_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
  USER_GROUP=$(id -gn "$SSH_USER")
  [[ -d "$USER_HOME" && "$USER_HOME" != / ]] || fail 'SSH user needs a valid home directory.'
  [[ ! -L "$USER_HOME/.ssh" && ! -L "$USER_HOME/.ssh/authorized_keys" ]] || fail 'Refusing symlinked SSH paths.'
  install -d -m 700 -o "$SSH_USER" -g "$USER_GROUP" "$USER_HOME/.ssh"
  AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
  touch "$AUTH_KEYS"
  if ! grep -qF -- "$KEY_BODY" "$AUTH_KEYS"; then
    printf '\n%s %s\n' "$KEY_TYPE" "$KEY_BODY" >> "$AUTH_KEYS"
  fi
  chown "$SSH_USER:$USER_GROUP" "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
fi
ssh-keygen -A
install -d -m 755 /run/sshd
/usr/sbin/sshd -t
systemctl enable --now ssh.service
systemctl reload ssh.service
install -d -m 700 /etc/easytier-bootstrap
install -m 755 "$CORE" /usr/local/bin/easytier-core
install -m 755 "$CLI" /usr/local/bin/easytier-cli
install -m 600 "$WORK/config.toml" "$CONFIG"
cat > "$UNIT" <<'UNIT'
[Unit]
Description=EasyTier private mesh (bootstrap)
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/easytier-core -c /etc/easytier-bootstrap/config.toml --rpc-portal 127.0.0.1:15888
Restart=on-failure
RestartSec=5
UMask=0077
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable --now easytier-bootstrap.service
# Limit newly added UFW rules to the mesh interface and existing sshd ports.
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
  while read -r PORT; do
    ufw allow in on etvpn0 to any port "$PORT" proto tcp
  done < <(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}')
fi
systemctl is-active --quiet ssh.service
systemctl is-active --quiet easytier-bootstrap.service
python3 "$HELPER" health --ip "$NODE_IP" --timeout 60
ip -4 -o addr show dev etvpn0 | grep -qF " $NODE_IP/" || fail 'Expected VPN interface address is missing.'
SSH_PORT=$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2; exit}')
ss -H -ltn | awk -v ip="$NODE_IP" -v port="$SSH_PORT" '
  $4 == "0.0.0.0:"port || $4 == "*:"port || $4 == ip":"port {found=1}
  END {exit !found}' || fail 'SSH is not listening on the VPN IPv4 address; review ListenAddress/socket settings.'
printf '\nEasyTier mesh and SSH listener verified. Both services enabled at boot.\n'
printf 'Connect using an existing permitted account: ssh -p %s USER@%s\n' "$SSH_PORT" "$NODE_IP"
printf 'Existing SSH authentication, firewall policies and cloud security groups still apply.\n'
