#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Install a verified liuqin bundle from a Linux host over USB networking."""
import argparse
import base64
import functools
import hashlib
import http.server
import json
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import threading
import time
import uuid


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


# One telnet input line reaches the RAM shell through a terminal whose input
# buffer is about a kilobyte; measured on the device, 1027 bytes arrive whole
# and 1067 bytes do not.  Overflow is silent and it drops the tail, so a cut
# inside a quote leaves that shell waiting for a continuation that never
# arrives -- the install then hangs with nothing running on the device and no
# error to read.  Longer commands therefore carry their data in exported
# variables (which the line has room for) and keep the quoted script short.
RAM_COMMAND_LIMIT = 960


def command(address, text, timeout=60, variables=None):
    """Use exact line markers, not command echo, to delimit one shell result."""
    token = 'LIUQIN_' + uuid.uuid4().hex[:12]
    start, end = token + '_S', token + '_E'
    exports = ''.join(f'{name}={shlex.quote(value)} ' for name, value in (variables or {}).items())
    line = ("stty -echo; " + ('export ' + exports + '; ' if exports else '') +
            "printf '\\n%s\\n' " + shlex.quote(start) +
            '; sh -c ' + shlex.quote(text) +
            "; result=$?; printf '\\n%s %s\\n' " + shlex.quote(end) + ' "$result"\n')
    if len(line) > RAM_COMMAND_LIMIT:
        raise RuntimeError(f'RAM command is {len(line)} bytes, over the installer shell limit of '
                           f'{RAM_COMMAND_LIMIT}; it would be truncated and hang silently')
    with socket.create_connection((address, 2323), timeout=10) as connection:
        connection.settimeout(1)
        # BusyBox telnetd announces WILL ECHO / WILL SGA / DO NAWS.
        connection.sendall(b'\xff\xfd\x01\xff\xfd\x03\xff\xfc\x1f')
        connection.sendall(line.encode())
        buffer = bytearray()
        deadline = time.monotonic() + timeout
        pattern = re.compile(rb'(?:^|\n)' + end.encode() + rb' ([0-9]+)\r?\n')
        while time.monotonic() < deadline:
            try:
                chunk = connection.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            buffer.extend(chunk)
            # Backup output can be large; the terminator is always at the tail.
            match = pattern.search(buffer, max(0, len(buffer) - 512))
            if match:
                first = re.search(rb'(?:^|\n)' + start.encode() + rb'\r?\n', buffer)
                if not first or int(match[1]) != 0:
                    raise RuntimeError(bytes(buffer[-4096:]).decode(errors='replace'))
                return bytes(buffer[first.end():match.start()]).replace(b'\r\n', b'\n').removesuffix(b'\r')
        raise RuntimeError('RAM command timed out or connection closed; installation stopped')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--check', action='store_true', help='Verify local files without accessing any device')
    parser.add_argument('--serial')
    parser.add_argument('--host-address', help='Host IPv4 address on the tablet USB network')
    parser.add_argument('--device-address', default='192.168.7.2')
    parser.add_argument('--backup', type=Path)
    parser.add_argument('--erase-userdata', action='store_true')
    parser.add_argument('--yes', action='store_true', help='Skip the interactive data-erasure confirmation')
    parser.add_argument('--allow-unverified', action='store_true', help='Explicitly test an offline-only bundle')
    parser.add_argument('--enable-rescue', action='store_true',
                        help='Enable unauthenticated root rescue access after installation (trusted USB only)')
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    manifest = json.loads((bundle / 'bundle.json').read_text())
    if manifest['device'] != 'liuqin':
        parser.error('wrong device bundle')
    for name in ('boot.img', 'installer.img', 'rootfs.tar.gz'):
        if sha(bundle / name) != manifest['files'][name]:
            parser.error('bundle checksum mismatch: ' + name + ' —— 包文件损坏或不完整，请重新下载')
    if args.check:
        print('Local bundle checksums verified; no device access')
        return
    if manifest['status'] != 'DEVICE_TESTED' and not args.allow_unverified:
        parser.error('bundle has not passed device testing; use --allow-unverified only for attended tests'
                     ' —— 该包未通过真机验证，请勿用于正式安装')
    if not all((args.serial, args.backup, args.erase_userdata)):
        parser.error('--serial, --backup and --erase-userdata are required')
    if args.backup.exists():
        parser.error('--backup must be a new directory')
    args.backup = args.backup.resolve()
    if args.backup == bundle or bundle in args.backup.parents:
        parser.error('private backups must be outside the served bundle directory')
    if args.host_address:
        socket.inet_pton(socket.AF_INET, args.host_address)
    socket.inet_pton(socket.AF_INET, args.device_address)

    def fastboot(*arguments):
        result = subprocess.run(['fastboot', '-s', args.serial, *arguments], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        return result.stdout

    for name, value in (('product', 'liuqin'), ('unlocked', 'yes')):
        if not re.search(r'\b' + name + r':\s*' + value + r'\b', fastboot('getvar', name)):
            parser.error('Fastboot device check failed: ' + name +
                         ' —— 请确认设备是小米平板 6 Pro（liuqin）且已解锁 Bootloader')
    # The current boot contract supports slot A only; never switch slots implicitly.
    if not re.search(r'current-slot:\s*a\b', fastboot('getvar', 'current-slot')):
        parser.error('slot A must be active before this installation'
                     ' —— 请先执行: fastboot --set-active=a')
    def partition_size(name):
        match = re.search(r'partition-size:' + re.escape(name) + r':\s*(0x[0-9a-fA-F]+)',
                          fastboot('getvar', 'partition-size:' + name))
        if not match:
            raise RuntimeError('Cannot determine partition size: ' + name)
        return int(match[1], 16)

    if partition_size('userdata') < 16 * 1024**3:
        parser.error('userdata is smaller than 16 GiB; only Xiaomi Pad 6 Pro (liuqin) is supported'
                     ' —— 请确认设备为小米平板 6 Pro（liuqin），不要用于其他机型')
    if max((bundle / name).stat().st_size for name in ('boot.img', 'installer.img')) > partition_size('boot_a'):
        parser.error('boot image exceeds the reported boot partition size'
                     ' —— boot 镜像大于 boot 分区，包与设备不匹配')
    if not args.yes:
        if not sys.stdin.isatty():
            parser.error('data erasure needs an interactive confirmation; pass --yes to skip it'
                         ' —— 非交互环境请显式加 --yes 确认清空 userdata')
        print(f'About to ERASE userdata on tablet {args.serial} and install Ubuntu.')
        print(f'即将清空平板 {args.serial} 的全部用户数据（Android 将被移除）并安装 Ubuntu。')
        if input('Type YES to continue / 输入 YES 继续: ') != 'YES':
            parser.error('data erasure was not confirmed —— 未确认，已取消')
    server = None
    try:
        print('Booting the RAM installer...', flush=True)
        fastboot('boot', str(bundle / 'installer.img'))
        deadline = time.monotonic() + 120
        while True:
            try:
                boot_id = command(args.device_address,
                                  'test "$(cat /etc/liuqin-installer)" = liuqin && cat /proc/sys/kernel/random/boot_id').decode().strip()
                uuid.UUID(boot_id)
                break
            except (OSError, RuntimeError, ValueError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Installer USB channel did not become ready; no formatting performed')
                time.sleep(2)
        def remote(text, timeout=60, variables=None):
            guard = 'test "$(cat /proc/sys/kernel/random/boot_id)" = ' + shlex.quote(boot_id)
            return command(args.device_address, guard + ' && ' + text, timeout, variables)

        cmdline = shlex.split(remote('cat /proc/cmdline').decode())
        serial = next((item.split('=', 1)[1] for item in cmdline if item.startswith('androidboot.serialno=')), '')
        if serial != args.serial:
            raise RuntimeError('RAM device serial does not match the selected Fastboot device'
                               ' —— 序列号不一致，请检查 --serial 参数')
        release = remote('uname -r').decode().strip()
        if release != manifest['kernel_release']:
            raise RuntimeError('Installer kernel does not match this bundle'
                               ' —— 安装器内核与包不匹配，请使用同一发布包内的全部文件')
        if not args.host_address:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
                route.connect((args.device_address, 2323))
                args.host_address = route.getsockname()[0]
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(bundle))
        server = http.server.ThreadingHTTPServer((args.host_address, 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        args.backup.mkdir(mode=0o700, parents=True)
        backups = {}
        for name in ('boot_a', 'boot_b', 'persist'):
            print('Backing up and verifying ' + name + '...', flush=True)
            device = '/dev/disk/by-partlabel/' + name
            content = remote('test -b ' + device + ' && /bin/busybox base64 ' + device, 600)
            target = args.backup / (name + '.img')
            target.write_bytes(base64.b64decode(content, validate=False))
            target.chmod(0o600)
            expected = remote('/bin/busybox sha256sum ' + device, 120).decode().split()[0]
            if sha(target) != expected:
                raise RuntimeError('Backup verification failed: ' + name)
            backups[target.name] = expected
        (args.backup / 'SHA256SUMS').write_text(''.join(f'{h}  {n}\n' for n, h in backups.items()))
        url = f'http://{args.host_address}:{server.server_port}/rootfs.tar.gz'
        arguments = [boot_id, url, manifest['files']['rootfs.tar.gz'],
                     str((bundle / 'rootfs.tar.gz').stat().st_size), 'ERASE-LIUQIN-USERDATA']
        if args.enable_rescue:
            arguments.append('ENABLE-USB-RESCUE')
        # The installer script and the root contract travel with the bundle
        # rather than with the RAM image.  A released installer.img embeds both
        # of its own vintage, so a root from a distribution that image predates
        # is failed by checks it can no longer satisfy -- the Fedora port is
        # exactly that case, and the contract is the sharper of the two: it pins
        # the hashes of files this project builds per distribution.  The device
        # already fetches the root archive from this server, so it fetches these
        # two there as well, by digest.  A bundle without them keeps the copies
        # inside the image.
        script, contract = bundle / 'install-root.sh', bundle / 'native-root.contract'
        if script.is_file() and contract.is_file():
            base = f'http://{args.host_address}:{server.server_port}'
            # The base URL and the two digests travel as exported variables,
            # the device-side paths are one letter, and the variables that
            # hold them are too: every byte of this line is spendable, and
            # RAM_COMMAND_LIMIT is why.  Both fetches, both checks, the
            # contract install and the exec stay inside the short script.
            fetch = ('b=/bin/busybox; mkdir -p /run &&'
                     ' $b wget -q -O /run/i $B/install-root.sh &&'
                     ' $b wget -q -O /run/c $B/native-root.contract &&'
                     ' [ "$($b sha256sum /run/i|$b cut -c1-64)" = "$R" ] &&'
                     ' [ "$($b sha256sum /run/c|$b cut -c1-64)" = "$C" ] &&'
                     ' cp /run/c /etc/liuqin-native-root.contract &&'
                     ' exec sh /run/i "$@"'
                     ' || { echo "liuqin-install: fetch or verify failed" >&2; exit 1; }')
            install = ['sh', '-c', fetch, 'liuqin-install', *arguments]
            variables = {'B': base, 'R': sha(script), 'C': sha(contract)}
        else:
            install = ['sh', '/usr/lib/liuqin/install-root.sh', *arguments]
            variables = None
        print('Installing the system; userdata will be erased after input checks.', flush=True)
        result = remote(shlex.join(install), 3600, variables)
        if b'liuqin-install: ROOT_INSTALLED' not in result:
            raise RuntimeError('Device did not confirm root installation')
        remote("(sleep 2; /usr/sbin/liuqin-reboot bootloader) >/dev/null 2>&1 &")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            devices = subprocess.check_output(['fastboot', 'devices'], text=True, timeout=10)
            if any(line.split()[0] == args.serial for line in devices.splitlines() if line.split()):
                break
            time.sleep(2)
        else:
            raise RuntimeError('Return to Fastboot not observed; boot partition was not flashed')
        print('Writing the matching boot image to boot_a...', flush=True)
        fastboot('flash', 'boot_a', str(bundle / 'boot.img'))
        fastboot('reboot')
        print('Installation commands completed. First-boot verification is still required.')
    finally:
        if server:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit('Installation stopped: ' + str(error))
