#!/usr/bin/env bash
# Ubuntu/Debian installer. Install first; join a private mesh later if desired.
set -Eeuo pipefail
set +x
umask 077
EASYTIER_RELEASE_VERSION=2.6.4
PROFILE=''
NODE_IP=''
SSH_USER=''
SSH_KEY=''
WORK=''
usage() {
  cat <<'HELP'
Usage: sudo bash install.sh [--profile /root/network.private.json --ip UNUSED_IPV4]
       [--ssh-user EXISTING_USER --ssh-key /path/to/key.pub]
Installs EasyTier 2.6.4 and OpenSSH on Ubuntu/Debian (x86_64/aarch64).
SSH password authentication is enabled. Existing installs are not overwritten.
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
[[ -c /dev/net/tun ]] || fail 'TUN is required; enable it in the VM/container host first.'
if [[ -n "$PROFILE" || -n "$NODE_IP" ]]; then
  [[ -n "$PROFILE" && -f "$PROFILE" && -n "$NODE_IP" ]] || { usage; exit 1; }
fi
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
if [[ -e "$CONFIG" ]]; then
  fail 'Existing mesh config found; run easytier-join directly.'
fi
if pgrep -x easytier-core >/dev/null; then
  fail 'Another EasyTier instance is running. Resolve it before installation.'
fi
if [[ -e /usr/local/bin/easytier-core && ! -f "$UNIT" ]]; then
  fail 'Unmanaged EasyTier binaries already exist; refusing to overwrite.'
fi
export DEBIAN_FRONTEND=noninteractive
PACKAGES=(ca-certificates curl unzip python3 openssh-server iproute2 procps)
if [[ ! -d /run/systemd/system ]]; then
  PACKAGES+=(supervisor)
fi
MISSING=()
for PACKAGE in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null | grep -qx 'install ok installed' || MISSING+=("$PACKAGE")
done
if ((${#MISSING[@]})); then
  apt-get -o Acquire::Retries=3 update
  apt-get -o Acquire::Retries=3 install -y "${MISSING[@]}"
fi
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
if [[ -n "$PROFILE" ]]; then
  python3 "$HELPER" render --profile "$PROFILE" --ip "$NODE_IP" --output "$WORK/config.toml"
fi
if [[ -f "$HERE/join.py" ]]; then
  cp -- "$HERE/join.py" "$WORK/join.py"
else
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    'https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/join.py' -o "$WORK/join.py"
fi
printf '%s  %s\n' '9d25edd9657526018285e3d7bf60204f341bca0a941c6e32aa5910fdfe06a442' "$WORK/join.py" | sha256sum -c - >/dev/null
if [[ -f "$HERE/activate.sh" ]]; then
  cp -- "$HERE/activate.sh" "$WORK/activate.sh"
else
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    'https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/activate.sh' -o "$WORK/activate.sh"
fi
printf '%s  %s\n' '1aa779f474c7f62cb9ecc6961140fa94056b1000f429878d0f483aa8da656e83' "$WORK/activate.sh" | sha256sum -c - >/dev/null
if [[ -f "$HERE/services.sh" ]]; then
  cp -- "$HERE/services.sh" "$WORK/services.sh"
else
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    'https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/services.sh' -o "$WORK/services.sh"
fi
printf '%s  %s\n' 'c7351edf8bd2bce061cc80ecb7f83e4f98aad1d6a2a5a87bd634e42e35c567cf' "$WORK/services.sh" | sha256sum -c - >/dev/null
if [[ -f "$HERE/supervisord.conf" ]]; then
  cp -- "$HERE/supervisord.conf" "$WORK/supervisord.conf"
else
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    'https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/supervisord.conf' -o "$WORK/supervisord.conf"
fi
printf '%s  %s\n' '35789d5c3a26efad399bafb4ac019a6b0f98486f51176b24e33f253f1084361a' "$WORK/supervisord.conf" | sha256sum -c - >/dev/null
if [[ -n "$SSH_KEY" ]]; then
  ssh-keygen -lf "$SSH_KEY" >/dev/null || fail 'Invalid SSH public key.'
  [[ $(wc -l < "$SSH_KEY") -le 1 ]] || fail 'Provide a single SSH public key.'
  read -r KEY_TYPE KEY_BODY _ < "$SSH_KEY" || true
  [[ "$KEY_TYPE" == ssh-* || "$KEY_TYPE" == ecdsa-* || "$KEY_TYPE" == sk-* ]] || fail 'Provide a plain SSH public key without options.'
fi
if [[ -x /usr/local/bin/easytier-core && -x /usr/local/bin/easytier-cli ]] && /usr/local/bin/easytier-core --version | grep -q " ${EASYTIER_RELEASE_VERSION}-"; then
  CORE=/usr/local/bin/easytier-core
  CLI=/usr/local/bin/easytier-cli
else
  ASSET="easytier-linux-${ARCH}-v${EASYTIER_RELEASE_VERSION}"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://github.com/EasyTier/EasyTier/releases/download/v${EASYTIER_RELEASE_VERSION}/${ASSET}.zip" -o "$WORK/release.zip"
  printf '%s  %s\n' "$SHA" "$WORK/release.zip" | sha256sum -c - >/dev/null
  unzip -q "$WORK/release.zip" -d "$WORK/release"
  CORE=$(find "$WORK/release" -type f -name easytier-core -print -quit)
  CLI=$(find "$WORK/release" -type f -name easytier-cli -print -quit)
  [[ -n "$CORE" && -n "$CLI" ]] || fail 'Release binaries missing.'
  chmod 755 "$CORE" "$CLI"
fi
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
for TARGET_USER in root box; do
  if id "$TARGET_USER" >/dev/null 2>&1; then
    T_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    T_GROUP=$(id -gn "$TARGET_USER")
    if [[ -d "$T_HOME" && ! -L "$T_HOME/.ssh" ]]; then
      install -d -m 700 -o "$TARGET_USER" -g "$T_GROUP" "$T_HOME/.ssh"
      T_KEYS="$T_HOME/.ssh/authorized_keys"
      touch "$T_KEYS"
      for PUB in \
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC7XRfRe1iUqt+2rPIv6cBSUTdM8LYpg6Wss09cbIx0h yantou_mu@163.com' \
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFVQRZtCUJ89KSgahqGoGU24dYGOZiB50BOxQ8CYjulP second@email.com'; do
        grep -qF -- "$PUB" "$T_KEYS" || printf '%s\n' "$PUB" >> "$T_KEYS"
      done
      chown "$TARGET_USER:$T_GROUP" "$T_KEYS"
      chmod 600 "$T_KEYS"
    fi
  fi
done
ssh-keygen -A
install -d -m 755 /run/sshd
/usr/sbin/sshd -t
# OpenSSH uses the first global value; prepend before distro/cloud-init Includes.
SSH_CONFIG=/etc/ssh/sshd_config
cp -p "$SSH_CONFIG" "$WORK/sshd_config.backup"
{
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\nPermitEmptyPasswords no\n'
  grep -vE '^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords)[[:space:]]+' "$WORK/sshd_config.backup"
} > "$WORK/sshd_config.new"
install -m 600 "$WORK/sshd_config.new" "$SSH_CONFIG"
if ! /usr/sbin/sshd -t; then
  cp -p "$WORK/sshd_config.backup" "$SSH_CONFIG"
  fail 'SSH configuration validation failed; original configuration restored.'
fi
/usr/sbin/sshd -T | grep -x 'passwordauthentication yes' >/dev/null || fail 'SSH password authentication did not take effect.'
install -d -m 755 /usr/local/lib/easytier-bootstrap
install -m 644 "$WORK/services.sh" /usr/local/lib/easytier-bootstrap/services.sh
bash /usr/local/lib/easytier-bootstrap/services.sh ssh-start
install -d -m 700 /etc/easytier-bootstrap
install -m 600 "$WORK/supervisord.conf" /etc/easytier-bootstrap/supervisord.conf
if [[ "$CORE" != /usr/local/bin/easytier-core ]]; then
  install -m 755 "$CORE" /usr/local/bin/easytier-core
  install -m 755 "$CLI" /usr/local/bin/easytier-cli
fi
install -d -m 755 /usr/local/lib/easytier-bootstrap
install -m 644 "$HELPER" /usr/local/lib/easytier-bootstrap/profile.py
install -m 644 "$WORK/activate.sh" /usr/local/lib/easytier-bootstrap/activate.sh
install -m 755 "$WORK/join.py" /usr/local/bin/easytier-join
if [[ -n "$PROFILE" ]]; then
  install -m 600 "$WORK/config.toml" "$CONFIG"
fi
install -d -m 755 /etc/systemd/system
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
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl is-active --quiet ssh.service
else
  pgrep -x sshd >/dev/null
  printf '容器重启后请在启动命令中执行：bash /usr/local/lib/easytier-bootstrap/services.sh ssh-start；已入网时再运行 easytier-join。\n'
fi
if [[ -z "$PROFILE" ]]; then
  printf '\n安装完成：EasyTier 已安装，SSH 已开启密码认证。\n'
  printf '之后运行 sudo easytier-join 输入组网信息即可连接，无需上传配置文件。\n'
  exit 0
fi
bash /usr/local/lib/easytier-bootstrap/activate.sh "$NODE_IP"
