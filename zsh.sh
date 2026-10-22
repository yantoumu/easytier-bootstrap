#!/bin/sh
# Interactive launcher. Compatible with sh, bash and zsh on Ubuntu/Debian.
set -eu
set +x
umask 077
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' '请在要安装的 Ubuntu / Debian 服务器上运行此文件。' >&2
  exit 1
fi
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE="$SCRIPT_DIR/network.private.json"
if [ ! -f "$PROFILE" ]; then
  PROFILE="$HOME/network.private.json"
fi
if [ ! -f "$PROFILE" ]; then
  printf '%s' '请输入私有入网配置文件的完整路径：'
  IFS= read -r PROFILE
fi
if [ ! -f "$PROFILE" ]; then
  printf '%s\n' '找不到配置文件。请把 network.private.json 放在本脚本旁边后重试。' >&2
  exit 1
fi
# Resolve before sudo so a relative path remains unambiguous.
PROFILE_DIR=$(CDPATH= cd -- "$(dirname -- "$PROFILE")" && pwd)
PROFILE="$PROFILE_DIR/$(basename -- "$PROFILE")"
printf '%s' '请输入新机器未占用的组网 IPv4 地址：'
IFS= read -r NODE_IP
if [ -z "$NODE_IP" ]; then
  printf '%s\n' '组网 IP 不能为空。' >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  printf '%s\n' '缺少 curl，请先运行：sudo apt-get update && sudo apt-get install -y curl ca-certificates' >&2
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Pin the reviewed installer revision; it also verifies the helper and release hashes.
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/yantoumu/easytier-bootstrap/be04a4fb37080cc91e063789f0d4150920856e66/install.sh \
  -o "$WORK/install.sh"
if [ "$(id -u)" -eq 0 ]; then
  bash "$WORK/install.sh" --profile "$PROFILE" --ip "$NODE_IP"
else
  sudo bash "$WORK/install.sh" --profile "$PROFILE" --ip "$NODE_IP"
fi
