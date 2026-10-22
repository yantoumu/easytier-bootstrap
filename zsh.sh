#!/bin/sh
# Install software and SSH first; run sudo easytier-join later.
set -eu
set +x
umask 077
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' '请在 Ubuntu / Debian 服务器上运行。' >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  printf '%s\n' '请先安装 curl：sudo apt-get update && sudo apt-get install -y curl ca-certificates' >&2
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/main/install.sh \
  -o "$WORK/install.sh"
if [ "$(id -u)" -eq 0 ]; then
  bash "$WORK/install.sh"
else
  sudo bash "$WORK/install.sh"
fi
if [ ! -f /etc/easytier-bootstrap/config.toml ] && [ -t 0 ]; then
  if [ "$(id -u)" -eq 0 ]; then
    easytier-join
  else
    sudo easytier-join
  fi
fi
