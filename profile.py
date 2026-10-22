#!/usr/bin/env python3
"""Export private network identity, render node config, and check mesh health."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import urlsplit


def load_profile(path):
    data = json.loads(Path(path).read_text())
    for field in ('network_name', 'network_secret'):
        if not isinstance(data.get(field), str) or not data[field].strip():
            raise ValueError('Missing network identity field: ' + field)
    network = ipaddress.IPv4Network(data['subnet'])
    private_ranges = ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')
    private = any(network.subnet_of(ipaddress.IPv4Network(r)) for r in private_ranges)
    if not private or network.prefixlen > 30:
        raise ValueError('Expected a private IPv4 subnet with prefix /8 to /30')
    peers = data['peers']
    if not isinstance(peers, list) or not peers:
        raise ValueError('At least one peer URI is required')
    for peer in peers:
        uri = urlsplit(peer)
        if uri.scheme not in ('tcp', 'udp', 'ws', 'wss', 'quic') or not uri.hostname:
            raise ValueError('Unsupported peer URI')
        if uri.username or uri.password or not uri.port:
            raise ValueError('Peer URI needs a port and must not contain credentials')
        if uri.hostname in ('localhost', '0.0.0.0', '::'):
            raise ValueError('Peer must be reachable from the new machine')
        try:
            address = ipaddress.ip_address(uri.hostname)
        except ValueError:
            address = None
        if address and (address.is_loopback or address.is_link_local or address.is_unspecified):
            raise ValueError('Peer must not be loopback or link-local')
    return data, network


def write_private(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        output.write(content)


def export_profile(args):
    # Imported only on the exporting machine; Linux installation supports Python 3.8+.
    import tomllib
    source = tomllib.loads(Path(args.source).read_text())
    identity = source['network_identity']
    ipv4 = source['ipv4']
    if args.subnet:
        network = ipaddress.IPv4Network(args.subnet)
    elif '/' in ipv4:
        network = ipaddress.IPv4Interface(ipv4).network
    else:
        raise ValueError('Source ipv4 has no prefix; provide --subnet explicitly')
    if ipaddress.IPv4Interface(ipv4).ip not in network:
        raise ValueError('Source address does not belong to the supplied subnet')
    peers = [peer['uri'] for peer in source.get('peer', [])]
    data = dict(network_name=identity['network_name'],
                network_secret=identity['network_secret'],
                subnet=str(network), peers=peers,
                reserved_ips=[str(ipaddress.IPv4Interface(ipv4).ip)])
    # Refuse silent changes to special security modes unsupported by this installer.
    flags = source.get('flags', {})
    if (flags.get('disable_encryption') or flags.get('private_mode')
            or source.get('secure_mode') or source.get('credential_file')):
        raise ValueError('Special network security flags require manual review')
    write_private(args.output, json.dumps(data, indent=2) + '\n')
    try:
        load_profile(args.output)
    except Exception:
        Path(args.output).unlink()
        raise
    if os.environ.get('SUDO_UID') and os.environ.get('SUDO_GID'):
        os.chown(args.output, int(os.environ['SUDO_UID']), int(os.environ['SUDO_GID']))
    print('Private profile exported (mode 0600). Keep it outside Git and transfer securely.')


def render_config(args):
    data, network = load_profile(args.profile)
    address = ipaddress.IPv4Address(args.ip)
    if address not in network or address in (network.network_address, network.broadcast_address):
        raise ValueError('Node IP must be a usable address in the profile subnet')
    if str(address) in data.get('reserved_ips', []):
        raise ValueError('Node IP is reserved by an existing machine')
    # JSON emits valid TOML basic string escapes except surrogate codepoints.
    q = lambda value: json.dumps(value, ensure_ascii=False)
    for value in [data['network_name'], data['network_secret'], *data['peers']]:
        value.encode('utf-8')
    lines = [f'ipv4 = {q(str(address) + "/" + str(network.prefixlen))}',
             'dhcp = false', 'listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]',
             '', '[network_identity]',
             'network_name = ' + q(data['network_name']),
             'network_secret = ' + q(data['network_secret'])]
    for peer in data['peers']:
        lines += ['', '[[peer]]', 'uri = ' + q(peer)]
    lines += ['', '[flags]', 'dev_name = "etvpn0"', 'mtu = 1360', '']
    write_private(args.output, '\n'.join(lines))
    print('Private node configuration validated and generated.')


def check_health(args):
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(['/usr/local/bin/easytier-cli', '-o', 'json', 'peer'],
                                    capture_output=True, text=True, timeout=5, check=True)
            peers = json.loads(result.stdout)
            local = any(p.get('cost') == 'Local' and p.get('ipv4') == args.ip for p in peers)
            remote = any(p.get('cost') != 'Local' and p.get('ipv4') for p in peers)
            if local and remote:
                print('Mesh verified: expected local IP and at least one remote member.')
                return
        except (subprocess.SubprocessError, ValueError, OSError, AttributeError):
            pass
        time.sleep(2)
    raise ValueError('No confirmed mesh connection within timeout; inspect local service logs privately')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export')
    export.add_argument('--source', required=True)
    export.add_argument('--output', required=True)
    export.add_argument('--subnet', help='Explicit subnet when source IPv4 has no prefix')
    render = commands.add_parser('render')
    render.add_argument('--profile', required=True)
    render.add_argument('--ip', required=True)
    render.add_argument('--output', required=True)
    health = commands.add_parser('health')
    health.add_argument('--ip', required=True)
    health.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    try:
        {'export': export_profile, 'render': render_config, 'health': check_health}[args.command](args)
    except Exception as error:
        # Parser errors can include entire secret-bearing input. Never echo exception text.
        print('Operation failed (' + type(error).__name__ + '). Check permissions, input fields, '
              'unused IP, peer reachability, and service status. Secret values are suppressed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
