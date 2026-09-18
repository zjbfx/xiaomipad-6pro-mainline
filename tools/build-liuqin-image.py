#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Assemble matching device packages, rootfs and boot from prepared inputs."""
import argparse
import fcntl
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess


INPUTS = {
    'UBUNTU_DESKTOP_ROOT', 'DESKTOP_ROOTFS_MANIFEST', 'FIRMWARE_POOL',
    'FIRMWARE_TREE', 'FIRMWARE_MANIFEST_SHA256', 'AUDIO_TOPOLOGY',
    'WLAN_HSP2_TUPLE', 'STOCK_OVERLAY_DIR', 'STOCK_BASE_DIR',
    'SENSOR_STACK_TAR', 'SENSOR_STACK_SHA256', 'POWER_SETTINGS_BINARY',
    'POWER_SETTINGS_MANIFEST', 'BUSYBOX', 'MKBOOTIMG_DIR',
}

# The Fedora assembly reuses everything distribution-neutral — kernel modules,
# board firmware, audio topology, WLAN set, stock DTBO/DTB inputs, boot image —
# and replaces only the two Ubuntu-shaped pieces: the base tree it starts from,
# and the five .deb device packages with the file tree the Fedora assembler
# installs.  installer.img stays a released artefact: it is the ephemeral RAM
# environment used to install, not part of the system being installed.
INPUTS_FEDORA = {
    'FEDORA_ROOTFS_ROOT', 'FEDORA_ROOTFS_MANIFEST', 'FIRMWARE_POOL', 'FIRMWARE_TREE',
    'AUDIO_TOPOLOGY', 'WLAN_HSP2_TUPLE', 'STOCK_OVERLAY_DIR', 'STOCK_BASE_DIR',
    'SENSOR_STACK_TAR', 'SENSOR_STACK_SHA256', 'POWER_SETTINGS_BINARY',
    'MKBOOTIMG_DIR', 'INSTALLER_IMG',
}

# The power panel (a gnome-control-center carrying the button-policy patch) is a
# desktop convenience that no admission gate looks at.  The Fedora root
# assembler treats its absence as a warning; the assembly does the same, so an
# image without it is a working tablet whose Power panel lacks the project's
# controls rather than a bundle that cannot be built.
OPTIONAL_FEDORA = {'POWER_SETTINGS_BINARY'}


def main():
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True,
                        help='Local JSON object of prepared-input environment variables')
    parser.add_argument('--kernel-out', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=project / 'out/image')
    parser.add_argument('--stage', choices=['all', 'modules', 'debs', 'device', 'copy', 'install',
                                          'assemble', 'preflight', 'manifest', 'boot', 'runtime',
                                          'installer', 'pack', 'bundle', 'release-assets'],
                        default='all')
    parser.add_argument('--distro', choices=['ubuntu', 'fedora'], default='ubuntu',
                        help='Which userspace the root is assembled from (default: ubuntu)')
    parser.add_argument('--device-tested', action='store_true',
                        help='Mark release assets after completing device installation tests')
    args = parser.parse_args()
    if args.device_tested and args.stage != 'release-assets':
        parser.error('--device-tested is only valid with --stage release-assets')
    inputs = INPUTS_FEDORA if args.distro == 'fedora' else INPUTS
    optional = OPTIONAL_FEDORA if args.distro == 'fedora' else set()
    # Keys starting with an underscore are documentation, not inputs: they let
    # the shipped template explain itself without becoming part of the contract.
    supplied = {key: value for key, value in json.loads(args.inputs.read_text()).items()
                if not key.startswith('_')}
    absent = sorted(inputs - optional - set(supplied))
    if set(supplied) - inputs or absent or not all(isinstance(v, str) and v
                                                   for v in supplied.values()):
        parser.error('Input keys must match: ' + ', '.join(sorted(inputs)) +
                     ('; missing ' + ', '.join(absent) if absent else ''))
    for key, value in supplied.items():
        if not key.endswith('_SHA256'):
            supplied[key] = str((args.inputs.resolve().parent / value).resolve())
            value = supplied[key]
        if not key.endswith('_SHA256') and not Path(value).exists():
            parser.error('Prepared input missing: ' + key)
    out, kernel = args.out.resolve(), args.kernel_out.resolve()
    if project / 'out' not in out.parents:
        parser.error('--out must be inside the project out directory')
    lock = json.loads((project / 'kernel/source.json').read_text())
    info = json.loads((kernel / 'build-info.json').read_text())
    if info['commit'] != lock['commit'] or info.get('build_kind') != 'product-input':
        parser.error('Kernel build must match the product lock, not a development override')
    if info['config_sha256'] != lock['config_sha256']:
        parser.error('Kernel configuration does not match the product lock')
    subprocess.run(['sha256sum', '-c', '--quiet', 'SHA256SUMS'], cwd=kernel, check=True)
    env = os.environ.copy()
    # Privileged assembly reads exactly these user-owned repositories.
    env.update(GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='safe.directory',
               GIT_CONFIG_VALUE_0=str(project), GIT_CONFIG_KEY_1='safe.directory',
               GIT_CONFIG_VALUE_1=str(project.parent / 'linux-sm8450-liuqin'))
    env.update(supplied, KERNEL_SOURCE=str(project.parent / 'linux-sm8450-liuqin'),
               KERNEL_DIR=str(project.parent / 'linux-sm8450-liuqin'), KERNEL_COMMIT=lock['commit'],
               KERNEL_OUT=str(kernel), KERNEL_IMAGE=str(kernel / 'arch/arm64/boot/Image'),
               KERNEL_DTB=str(kernel / 'arch/arm64/boot/dts' / lock['dtb']),
               KERNEL_LAYER_ROOT=str(kernel / 'root'),
               KERNEL_MODULES_DIR=str(out / 'modules'), DEBS_DIR=str(out / 'debs'),
               NATIVE_ROOT_HASHES=str(out / 'root/native-root.hashes'))
    stages = {
        'modules': ('build-liuqin-kernel-modules.sh', [], out / 'modules'),
        'boot': ('build-liuqin-native-boot.sh', [], out / 'boot'),
    }
    if args.distro == 'fedora':
        # No runtime/installer stages: the released installer image is reused,
        # so deriving one from an Ubuntu tree is not part of this assembly.
        stages.update({
            'copy': ('build-liuqin-fedora-native-root.sh', ['copy'], out / 'root'),
            'device': ('build-liuqin-fedora-native-root.sh', ['device'], out / 'root'),
            'assemble': ('build-liuqin-fedora-native-root.sh', ['assemble'], out / 'root'),
            'preflight': ('build-liuqin-fedora-native-root.sh', ['preflight'], out / 'root'),
            'manifest': ('build-liuqin-fedora-native-root.sh', ['manifest'], out / 'root'),
            'pack': ('build-liuqin-fedora-native-root.sh', ['pack'], out / 'root'),
        })
    else:
        stages.update({
            'debs': ('build-liuqin-debs.sh', ['all'], out / 'debs'),
            'copy': ('build-liuqin-native-root.sh', ['copy'], out / 'root'),
            'install': ('build-liuqin-native-root.sh', ['debs'], out / 'root'),
            'assemble': ('build-liuqin-native-root.sh', ['assemble'], out / 'root'),
            'manifest': ('build-liuqin-native-root.sh', ['manifest'], out / 'root'),
            'runtime': ('lib/build-installer-runtime.py', ['--root', supplied['UBUNTU_DESKTOP_ROOT'],
                                                         '--out', str(out / 'installer-runtime')], out / 'installer-runtime'),
            'installer': ('build-liuqin-native-boot.sh', [], out / 'installer'),
            'pack': ('build-liuqin-native-root.sh', ['pack'], out / 'root'),
        })
    selected = [*stages, 'bundle'] if args.stage == 'all' else [args.stage]
    if args.stage == 'all' and out.exists():
        parser.error('all requires a fresh output; resume with --stage instead')
    out.mkdir(parents=True, exist_ok=True)
    owner = (out / '.image.lock').open('a')
    try:
        fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('another assembly owns this output')
    for stage in selected:
        if stage == 'release-assets':
            destination = out / 'release-assets'
            shutil.copytree(out / 'bundle', destination,
                            ignore=shutil.ignore_patterns('rootfs.tar.gz'))
            metadata = json.loads((destination / 'bundle.json').read_text())
            for name in ('INSTALL-TESTING.md', 'INSTALL-TESTING.zh-CN.md'):
                shutil.copyfile(project / 'docs' / name, destination / name)
                metadata['files'][name] = hashlib.sha256((destination / name).read_bytes()).hexdigest()
            if args.device_tested:
                metadata['status'] = 'DEVICE_TESTED'
                metadata['tested_storage_layout'] = 'known 256 GB layout'
            # Each GitHub Release asset must remain below its 2 GiB limit.
            subprocess.run(['split', '-b', '1900M', '-d', '-a', '2',
                            str(out / 'bundle/rootfs.tar.gz'),
                            str(destination / 'rootfs.tar.gz.part-')], check=True)
            (destination / 'bundle.json').write_text(json.dumps(metadata, indent=2) + '\n')
            hashes = dict(metadata['files'])
            hashes['bundle.json'] = hashlib.sha256((destination / 'bundle.json').read_bytes()).hexdigest()
            (destination / 'SHA256SUMS').write_text(''.join(f'{h}  {n}\n' for n, h in hashes.items()))
            continue
        if stage == 'bundle':
            destination = out / 'bundle'
            destination.mkdir()
            files = {'boot.img': out / 'boot/boot-liuqin-native.img',
                     'installer.img': (Path(supplied['INSTALLER_IMG']) if args.distro == 'fedora'
                                       else out / 'installer/boot-liuqin-native.img'),
                     'rootfs.tar.gz': out / 'root/rootfs.tar.gz',
                     'install.py': project / 'tools/install-liuqin.py',
                     'install-root.sh': project / 'tools/lib/install-root.sh',
                     'native-root.contract': out / 'boot/native-root.contract',
                     'INSTALL-TESTING.md': project / 'docs/INSTALL-TESTING.md',
                     'INSTALL-TESTING.zh-CN.md': project / 'docs/INSTALL-TESTING.zh-CN.md',
                     'NOTICE': project / 'NOTICE', 'LICENSE': project / 'LICENSE'}
            hashes = {}
            for name, source in files.items():
                if name in ('boot.img', 'installer.img', 'rootfs.tar.gz'):
                    os.link(source, destination / name)
                else:
                    shutil.copyfile(source, destination / name)
                with source.open('rb') as stream:
                    hashes[name] = hashlib.file_digest(stream, 'sha256').hexdigest()
            metadata = {'device': 'liuqin', 'status': 'OFFLINE_ASSEMBLED',
                        'kernel_commit': lock['commit'],
                        'project_commit': subprocess.check_output(['git', '-C', str(project), 'rev-parse', 'HEAD'], env=env, text=True).strip(),
                        'project_dirty': bool(subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'], env=env)),
                        'kernel_release': (kernel / 'include/config/kernel.release').read_text().strip(),
                        'files': hashes}
            (destination / 'bundle.json').write_text(json.dumps(metadata, indent=2) + '\n')
            hashes['bundle.json'] = hashlib.sha256((destination / 'bundle.json').read_bytes()).hexdigest()
            (destination / 'SHA256SUMS').write_text(''.join(f'{h}  {n}\n' for n, h in hashes.items()))
            continue
        script, arguments, destination = stages[stage]
        print('Stage: ' + stage, flush=True)
        stage_env = dict(env, OUT_DIR=str(destination))
        if script == 'build-liuqin-fedora-native-root.sh':
            # One firmware tree, two consumers with different shapes.  The root
            # assembler installs the prepared /usr/lib/firmware closure; the
            # initramfs builder underneath the boot stage reads the raw vendor
            # pool.  FIRMWARE_TREE keeps one meaning in both profiles -- the
            # tree build-liuqin-firmware-prep.sh emits -- so the closure is
            # derived here rather than left to whoever writes the input file.
            closure = Path(supplied['FIRMWARE_TREE']) / 'usr/lib/firmware'
            if not closure.is_dir():
                parser.error('FIRMWARE_TREE carries no firmware closure: ' + str(closure))
            stage_env['FIRMWARE_POOL'] = str(closure)
        if stage == 'installer':
            stage_env['INSTALLER_RUNTIME'] = str(out / 'installer-runtime')
        subprocess.run(['python3' if script.endswith('.py') else 'sh',
                        str(project / 'tools' / script), *arguments], env=stage_env, check=True)
    print('Selected assembly stages completed; device validation is separate')


if __name__ == '__main__':
    main()
