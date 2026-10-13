#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Recover the pinned AudioReach topology from a published liuqin release bundle.
#
# tools/build-liuqin-audio-topology.sh builds the speaker topology from the
# AudioReach source revision the project pins, and both the firmware-prep and
# the initramfs builder verify its bytes against a hash literal.  The build
# needs an AudioReach checkout and alsatplg, which is a reasonable requirement
# for a machine that compiles the project and a hard one for a machine that
# assembles a variant of it from released pieces -- the same split the released
# kernel covers.
#
# A published bundle carries the built topology as bytes: the boot image's
# initramfs holds it at /lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin,
# because the initramfs builder installs the file it just verified.  The bundle
# ships SHA256SUMS for its images, so the recovery is checked rather than
# trusted: the boot image is verified against bundle.json before it is read,
# and the recovered topology against the hash the two builders enforce.
#
# v0.6.0 is the release to recover from: earlier ones were built from the
# pre-microphone topology (dff0c8af...), which the current builders reject.
#
#   RELEASE_DIR=~/project/miPad6pro/liuqin-v0.6.0 \
#   sh tools/import-liuqin-release-topology.sh
#
# Outputs, all under OUT_DIR (the AUDIO_TOPOLOGY the image assembly consumes):
#   Xiaomi-Pad-6-Pro-tplg.bin   the topology, at the pinned hash
#   topology.identity           provenance and observed digests
#   SHA256SUMS                  the pair above
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${RELEASE_DIR:?"set RELEASE_DIR to an unpacked release bundle (holds bundle.json and SHA256SUMS)"}
out_dir=${OUT_DIR:-"$project_root/out/topology-from-release"}

die() { printf 'import-liuqin-release-topology: %s\n' "$*" >&2; exit 1; }
say() { printf 'import-liuqin-release-topology: %s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
check() { [ "$(sha "$2")" = "$1" ] || die "$2 does not match its pinned hash ($1)"; }

case $out_dir in
"$project_root"/out/*) ;;
*) die "refusing an output directory outside out/: $out_dir" ;;
esac
[ ! -e "$out_dir" ] || die "output directory already exists (single writer, fresh dir): $out_dir"
[ -d "$release_dir" ] || die "release directory is unavailable: $release_dir"
[ -f "$release_dir/bundle.json" ] && [ -f "$release_dir/SHA256SUMS" ] ||
	die "not a release bundle (no bundle.json/SHA256SUMS): $release_dir"

# --- The pin, read from the two builders that enforce it ---------------------
# They describe one payload: the firmware tree stage 1 loads at runtime and the
# copy the same image carries into its initramfs.  Two literals that disagree
# mean the project is mid-edit, and a recovery against either one of them would
# be picking a side, so require them to be the same value first.
initramfs_pin=$(sed -n 's/^audio_topology_sha256=\([0-9a-f]\{64\}\)$/\1/p' \
	"$project_root/tools/lib/build-initramfs.sh")
prep_pin=$(sed -n 's/^topology_sha256=\([0-9a-f]\{64\}\)$/\1/p' \
	"$project_root/tools/build-liuqin-firmware-prep.sh")
[ -n "$initramfs_pin" ] || die 'the initramfs builder states no topology pin'
[ -n "$prep_pin" ] || die 'the firmware-prep builder states no topology pin'
[ "$initramfs_pin" = "$prep_pin" ] ||
	die "the builders disagree on the topology pin: $initramfs_pin != $prep_pin"
pin=$initramfs_pin
say "topology pin (build-initramfs.sh and build-liuqin-firmware-prep.sh): $pin"

# --- The published bundle must be the one it claims to be --------------------
boot_img=$release_dir/boot.img
[ -f "$boot_img" ] || die "boot image is unavailable: $boot_img"
bundle_boot_sha=$(python3 - "$release_dir/bundle.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['files']['boot.img'])
PY
)
say 'hashing the boot image'
check "$bundle_boot_sha" "$boot_img"

mkdir -p "$out_dir"
member=lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin
say "extracting $member from the boot image's initramfs"
if ! python3 - "$boot_img" "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin" "$member" <<'PY'
import gzip, struct, sys
from pathlib import Path

blob = Path(sys.argv[1]).read_bytes()
dest = Path(sys.argv[2])
member = sys.argv[3]

# The layout assumptions are the ones the kernel recovery made, and they are
# asserted rather than assumed: a boot image that no longer matches them is a
# different artefact, not one to read with a guessed offset.
magic, kernel_size, _ka, ramdisk_size, _ra, second_size, _sa, _ta, page_size, header_version = \
    struct.unpack('<8s9I', blob[:44])
if magic != b'ANDROID!':
    raise SystemExit('not an Android boot image')
if header_version != 2:
    raise SystemExit(f'expected a v2 boot image, found v{header_version}')
if page_size != 4096:
    raise SystemExit(f'unexpected page size: {page_size}')
if second_size:
    raise SystemExit('the boot image carries a second stage; layout assumption is wrong')

def pages(n):
    return (n + page_size - 1) // page_size * page_size

offset = page_size + pages(kernel_size)
if offset + ramdisk_size > len(blob):
    raise SystemExit('the ramdisk section runs past the end of the image')
if blob[offset:offset + 2] != b'\x1f\x8b':
    raise SystemExit('the ramdisk section is not gzip')
ramdisk = gzip.decompress(blob[offset:offset + ramdisk_size])

# Newc cpio (070701, no CRC, GNU cpio --format=newc), the format the initramfs
# builder writes.  The header is the magic plus thirteen 8-digit hex fields.
# The alignment is the archive's, not one field's: the header is 110 bytes, so
# the name is padded until header+name - not the name alone - reaches a four
# byte boundary, and the data is padded the same way behind it.
def field(header, index):
    return int(header[6 + index * 8:6 + (index + 1) * 8], 16)

count = 0
position = 0
while position + 110 <= len(ramdisk):
    header = ramdisk[position:position + 110]
    if header[:6] not in (b'070701', b'070702'):
        if position == 0:
            raise SystemExit('the initramfs is not a newc cpio archive')
        # Concatenated archives (the builder may append a second one) leave a
        # gap behind the trailer; pick the next header up if there is one.
        following = ramdisk.find(b'070701', position)
        if following < 0:
            break
        position = following
        continue
    size = field(header, 6)
    name_size = field(header, 11)
    name_start = position + 110
    name = ramdisk[name_start:name_start + name_size - 1].decode('utf-8', 'replace')
    data_start = position + (110 + name_size + 3) // 4 * 4
    if name.lstrip('./') == member:
        count += 1
        payload = ramdisk[data_start:data_start + size]
        if len(payload) != size:
            raise SystemExit('the initramfs entry is truncated')
        dest.write_bytes(payload)
    position = data_start + (size + 3) // 4 * 4
if count != 1:
    raise SystemExit(f'the initramfs holds {count} entries for {member}, expected one')
print(f'{dest}: {dest.stat().st_size} bytes')
PY
then
	die 'could not recover the topology from the boot image'
fi
check "$pin" "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin"
chmod 0644 "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin"
say 'the recovered topology matches the pin'

# --- What was recovered ------------------------------------------------------
{
	printf '# recovered from %s\n' "$release_dir"
	printf '# boot.img sha256 %s\n' "$bundle_boot_sha"
	printf 'topology=%s\n' "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin"
	printf 'topology_sha256=%s\n' "$(sha "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin")"
	printf 'topology_size=%s\n' "$(stat -c '%s' "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin")"
	printf 'initramfs_member=%s\n' "$member"
} >"$out_dir/topology.identity"
chmod 0644 "$out_dir/topology.identity"

( cd "$out_dir" && sha256sum Xiaomi-Pad-6-Pro-tplg.bin topology.identity ) >"$out_dir/SHA256SUMS"
chmod 0644 "$out_dir/SHA256SUMS"

say "recovered the released topology: $(stat -c '%s' "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin") bytes"
printf 'topology: %s\n' "$out_dir/Xiaomi-Pad-6-Pro-tplg.bin"
printf 'identity: %s\n' "$out_dir/topology.identity"
printf '\nnext: point AUDIO_TOPOLOGY at the topology above\n'
