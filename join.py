#!/usr/bin/env python3
"""Interactively join the installed EasyTier node without uploading credentials."""
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if os.geteuid() != 0:
        print("请运行 sudo easytier-join", file=sys.stderr)
        return 1
    config = Path('/etc/easytier-bootstrap/config.toml')
    helper = '/usr/local/lib/easytier-bootstrap/profile.py'
    activation = '/usr/local/lib/easytier-bootstrap/activate.sh'
    if config.exists():
        # Retry startup/health after an earlier failed connection without overwriting identity.
        print('已有入网配置，重新启动并检查连接。')
        for line in config.read_text().splitlines():
            if line.startswith('ipv4 = '):
                ip = json.loads(line.split('=', 1)[1].strip()).split('/')[0]
                return subprocess.call(['bash', activation, ip])
        raise ValueError('Existing configuration has no IPv4')
    if not sys.stdin.isatty():
        print('请在交互终端运行，组网密码不会显示。', file=sys.stderr)
        return 1
    name = input('组网名称：').strip()
    secret = getpass.getpass('组网密码（隐藏输入）：')
    subnet = input('组网网段（CIDR）：').strip()
    peers = input('引导节点 URI（多个用空格分隔）：').split()
    ip = input('本机未占用的组网 IPv4：').strip()
    profile = dict(network_name=name, network_secret=secret, subnet=subnet, peers=peers)
    with tempfile.TemporaryDirectory(prefix='easytier-join-') as temp:
        source = Path(temp) / 'network.private.json'
        source.write_text(json.dumps(profile))
        source.chmod(0o600)
        generated = Path(temp) / 'config.toml'
        subprocess.run([sys.executable, helper, 'render', '--profile', str(source),
                        '--ip', ip, '--output', str(generated)], check=True)
        config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Exclusive create prevents a concurrent join from overwriting another node identity.
        fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(generated.read_text())
    return subprocess.call(['bash', activation, ip])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt) as error:
        print('入网未完成（' + type(error).__name__ + '）；请检查输入或本机服务。私密信息不回显。',
              file=sys.stderr)
        sys.exit(1)
