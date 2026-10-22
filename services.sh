#!/usr/bin/env bash
# Service adapter for systemd hosts and Debian/Ubuntu containers using tini.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
ACTION=${1:?Expected ssh-start, mesh-start or status}
if [[ -d /run/systemd/system ]]; then
  case "$ACTION" in
    ssh-start) systemctl enable --now ssh.service; systemctl reload ssh.service; systemctl is-active --quiet ssh.service ;;
    mesh-start) systemctl daemon-reload; systemctl enable --now easytier-bootstrap.service ;;
    status) systemctl is-active --quiet ssh.service; systemctl is-active --quiet easytier-bootstrap.service ;;
    *) exit 2 ;;
  esac
  exit 0
fi
SUPERVISOR=/etc/easytier-bootstrap/supervisord.conf
case "$ACTION" in
  ssh-start)
    # Debian's SysV OpenSSH script works without an init daemon.
    [[ -x /etc/init.d/ssh ]] || { echo 'OpenSSH init script missing.' >&2; exit 1; }
    /etc/init.d/ssh start
    /etc/init.d/ssh reload
    /etc/init.d/ssh status
    ;;
  mesh-start)
    [[ -f /etc/easytier-bootstrap/config.toml ]] || { echo 'Run easytier-join first.' >&2; exit 1; }
    install -d -m 700 /var/log/easytier-bootstrap /run/easytier-bootstrap
    if ! supervisorctl -c "$SUPERVISOR" pid >/dev/null 2>&1; then
      supervisord -c "$SUPERVISOR"
    fi
    # startsecs=0 acknowledges startup immediately; health checks verify real connectivity.
    if ! supervisorctl -c "$SUPERVISOR" status easytier 2>/dev/null | grep 'RUNNING' >/dev/null; then
      supervisorctl -c "$SUPERVISOR" start easytier
    fi
    ;;
  status)
    /etc/init.d/ssh status
    supervisorctl -c "$SUPERVISOR" status easytier | grep 'RUNNING' >/dev/null
    ;;
  *) exit 2 ;;
esac
