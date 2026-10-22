#!/usr/bin/env python3
"""Join the EasyTier mesh by pasting the network secret once."""
import base64
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ENCRYPTED_PRESET = "GX/fGG8oIVihEFTVuOf0BEKBjlznsCmd7pMRKvL0EfaFDnBM0tQQW4FkeBqiM4BgPUPBic4PxwCKQDbLHEVi4ds8sStRXq0jLYjotnvHi3HtTa0gFiEKUsiSRZ7ZMVTte3uQI0Eax11/6UQLUW6+P8JDGxa+aXk6i6Kr5waQPDhubL1pY3GWWoicZ8jkRHFqT+Krv807glyYyUVh2WEJvqRo8P/8q580wFKfpKuLPfBn1lu394xD7yqzV6seNXum5JaXvXs="
DEFAULT_NODE_IP = "10.88.88.20"


def unlock_preset(secret_text):
    raw = base64.b64decode(ENCRYPTED_PRESET)
    salt, tag, cipher = raw[:16], raw[16:48], raw[48:]
    dk = hashlib.pbkdf2_hmac('sha256', secret_text.encode('utf-8'), salt, 200000, dklen=64)
    enc_key, mac_key = dk[:32], dk[32:]
    expected = hmac.new(mac_key, salt + cipher, hashlib.sha256).digest()
    if not hmac.compare_digest(tag, expected):
        raise ValueError('Invalid network secret')
    stream = b''.join(
        hashlib.sha256(enc_key + salt + i.to_bytes(4, 'big')).digest()
        for i in range((len(cipher) + 31) // 32)
    )[:len(cipher)]
    data = json.loads(bytes(a ^ b for a, b in zip(cipher, stream)).decode('utf-8'))
    data['network_secret'] = secret_text
    return data


def main():
    if os.geteuid() != 0:
        print("请运行 sudo easytier-join", file=sys.stderr)
        return 1
    config = Path('/etc/easytier-bootstrap/config.toml')
    helper = '/usr/local/lib/easytier-bootstrap/profile.py'
    activation = '/usr/local/lib/easytier-bootstrap/activate.sh'
    if config.exists():
        print('已有入网配置，正在启动并检查组网连接...')
        for line in config.read_text().splitlines():
            if line.startswith('ipv4 = '):
                ip = json.loads(line.split('=', 1)[1].strip()).split('/')[0]
                return subprocess.call(['bash', activation, ip])
        raise ValueError('Existing configuration has no IPv4')
    args = [a.strip() for a in sys.argv[1:] if a.strip()]
    ip = DEFAULT_NODE_IP
    secret = os.environ.get('ET_JOIN_KEY', '').strip()
    for a in args:
        if a.count('.') == 3 and all(part.isdigit() for part in a.split('.')):
            ip = a
        else:
            secret = a
    if not secret:
        secret = getpass.getpass(f'请直接粘贴组网密码并回车（本机将使用 IP {ip}）：').strip()
    profile = unlock_preset(secret)
    with tempfile.TemporaryDirectory(prefix='easytier-join-') as temp:
        source = Path(temp) / 'network.private.json'
        source.write_text(json.dumps(profile))
        source.chmod(0o600)
        generated = Path(temp) / 'config.toml'
        subprocess.run([sys.executable, helper, 'render', '--profile', str(source),
                        '--ip', ip, '--output', str(generated)], check=True)
        config.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(generated.read_text())
    return subprocess.call(['bash', activation, ip])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt) as error:
        print('入网未完成（' + type(error).__name__ + '）：请确认粘贴的是正确的组网密码。',
              file=sys.stderr)
        sys.exit(1)
