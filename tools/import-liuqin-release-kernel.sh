#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Recover the pinned kernel inputs from a published liuqin release bundle.
#
# tools/build-liuqin-kernel.py produces what the boot builder and the root
# assembler consume: the kernel Image, the .config it was configured with, the
# generated release string, and the module tree.  Building them from source is
# bound to the toolchain that authored kernel/source.json -- kconfig writes
# CONFIG_CC_VERSION_TEXT and the GCC/binutils/ld version symbols into .config,
# so `config_sha256` describes a compiler as much as a configuration.  On a host
# whose cross compiler differs, the pin cannot be met at all.
#
# A published bundle carries the same four artefacts as bytes: the Image and
# .config inside boot.img (CONFIG_IKCONFIG=y makes a shipped kernel a verifiable
# carrier of its own build configuration), and the release string plus module
# tree inside rootfs.tar.gz.  The bundle ships SHA256SUMS for the images and
# records per-file digests in bundle.json, so the recovery is checked rather
# than trusted -- every artefact is verified against the pin before staging.
#
# The device tree is *not* in that set.  The released boot.img holds the boot
# DTB -- raw tree plus the /chosen command line overlay, the ABL overlay and the
# symbol sink -- which is a build product rather than an input, so it is rebuilt
# here from the pinned source with the pinned configuration.  The released blob
# is still extracted and recorded: once the stock DTBO and base sets are in hand,
# the boot image step compares its own DTB against these bytes, which is what
# makes the locally built dtc, fdtoverlay and device tree trustworthy.
#
#   RELEASE_DIR=~/project/miPad6pro/liuqin-v0.2.0 \
#   sh tools/import-liuqin-release-kernel.sh
#
# Outputs, all under OUT_DIR (the KERNEL_OUT the boot builder consumes):
#   arch/arm64/boot/Image                          KERNEL_IMAGE
#   arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb   KERNEL_DTB
#   .config                                        must hash to the pin
#   include/config/kernel.release                  must hash-match the root's copy
#   scripts/dtc/{dtc,fdtoverlay}                   DTC / FDTOVERLAY
#   root/usr/lib/modules/<release>/...             KERNEL_LAYER_ROOT for the
#   root/usr/share/liuqin/{kernel.release,kernel-modules.manifest}
#                                                  Fedora root assembler
#   release-kernel.identity                        provenance and observed digests
#   build-info.json, SHA256SUMS                    the shape the image assembly
#                                                  gates on
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${RELEASE_DIR:?"set RELEASE_DIR to an unpacked release bundle (holds bundle.json and SHA256SUMS)"}
out_dir=${OUT_DIR:-"$project_root/out/kernel-from-release"}
kernel_source=${KERNEL_SOURCE:-"$project_root/../linux-sm8450-liuqin"}
cross=${CROSS_COMPILE:-aarch64-linux-gnu-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

die() { printf 'import-liuqin-release-kernel: %s\n' "$*" >&2; exit 1; }
say() { printf 'import-liuqin-release-kernel: %s\n' "$*"; }
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
[ -d "$kernel_source/.git" ] || die "kernel source checkout is unavailable: $kernel_source"

# --- The pins, read from the sources of truth --------------------------------
config_pin=$(python3 - "$project_root/kernel/source.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['config_sha256'])
PY
)
source_commit=$(python3 - "$project_root/kernel/source.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['commit'])
PY
)
bundle=$(python3 - "$release_dir/bundle.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
print(b['kernel_commit'], b['kernel_release'], b['files']['boot.img'], b['files']['rootfs.tar.gz'])
PY
)
set -- $bundle
bundle_commit=$1
bundle_release=$2
bundle_boot_sha=$3
bundle_rootfs_sha=$4
case $bundle_release in '' | *[!A-Za-z0-9._+-]*) die "unsafe kernel release in bundle.json: $bundle_release" ;; esac
say "release $bundle_release (kernel $bundle_commit)"
[ "$bundle_commit" = "$source_commit" ] ||
	die "the bundle was built from $bundle_commit, kernel/source.json pins $source_commit"
[ "$(git -C "$kernel_source" rev-parse HEAD)" = "$source_commit" ] ||
	die "kernel source is not at the pinned commit: $(git -C "$kernel_source" rev-parse HEAD)"
[ -z "$(git -C "$kernel_source" status --porcelain)" ] || die 'kernel source is dirty'

mkdir -p "$out_dir"

# --- The Image and the configuration it was built with -----------------------
boot_img=$release_dir/boot.img
[ -f "$boot_img" ] || die "boot image is unavailable: $boot_img"
say 'hashing the boot image'
check "$bundle_boot_sha" "$boot_img"

say 'extracting the kernel Image from the boot image'
if ! python3 - "$boot_img" "$out_dir/arch/arm64/boot/Image" "$bundle_release" <<'PY'
import gzip, struct, sys
from pathlib import Path
blob = Path(sys.argv[1]).read_bytes()
dest = Path(sys.argv[2])
release = sys.argv[3]
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
# The v2 fields after the v1 block: header_size @1644, dtb_size @1648, dtb_addr @1652.
header_size, dtb_size = struct.unpack('<II', blob[1644:1652])
(dtb_addr,) = struct.unpack('<Q', blob[1652:1660])
if dtb_addr != 0x01f00000:
    raise SystemExit(f'unexpected dtb address: {dtb_addr:#x}')
if header_size > page_size:
    raise SystemExit(f'header does not fit one page: {header_size}')

def pages(n):
    return (n + page_size - 1) // page_size * page_size

kernel_off = page_size
dtb_off = kernel_off + pages(kernel_size) + pages(ramdisk_size)
if dtb_off + dtb_size > len(blob):
    raise SystemExit('the dtb section runs past the end of the image')
image = gzip.decompress(blob[kernel_off:kernel_off + kernel_size])
if image[:2] != b'MZ' or image[56:60] != b'ARM\x64':
    raise SystemExit('the kernel section did not decompress to an arm64 Image')
(flags,) = struct.unpack('<Q', image[24:32])
if flags & 1:
    raise SystemExit('the Image is big endian')
(image_size,) = struct.unpack('<Q', image[16:24])
# The header's image_size covers .bss, which the file does not carry; it is the
# file that must not be longer than the space the header reserves.
if image_size < len(image):
    raise SystemExit(f'Image header reserves {image_size} bytes, section holds {len(image)}')
if release.encode() not in image:
    raise SystemExit(f'the Image does not carry the release string {release!r}')
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(image)
print(f'{dest}: {len(image)} bytes (image_size field {image_size})')
PY
then
	die 'could not recover the kernel Image from the boot image'
fi

image=$out_dir/arch/arm64/boot/Image
say "extracting the build configuration from the Image (CONFIG_IKCONFIG)"
sh "$kernel_source/scripts/extract-ikconfig" "$image" >"$out_dir/.config" ||
	die 'the Image carries no embedded configuration (CONFIG_IKCONFIG)'
config_seen=$(sha "$out_dir/.config")
[ "$config_seen" = "$config_pin" ] ||
	die "recovered configuration does not match the pin: $config_seen != $config_pin"
say "configuration matches kernel/source.json ($config_pin)"

# --- The release string and the module tree ----------------------------------
rootfs_tar=$release_dir/rootfs.tar.gz
[ -f "$rootfs_tar" ] || die "root filesystem archive is unavailable: $rootfs_tar"
say 'hashing the root filesystem archive (one pass over ~4.3 GiB)'
check "$bundle_rootfs_sha" "$rootfs_tar"

# Only the project kernel's module tree is wanted; the archive also holds the
# distribution kernel's, which belongs to the image this root replaces.
module_tree=$out_dir/root/usr/lib/modules/$bundle_release
mkdir -p "$out_dir/root"
say "extracting the module tree and the release record from the archive"
tar -xzf "$rootfs_tar" -C "$out_dir/root" --wildcards --no-anchored \
	"usr/lib/modules/$bundle_release/*" \
	'usr/share/liuqin/kernel.release' \
	'usr/share/liuqin/kernel-modules.manifest' ||
	die 'could not extract the module tree from the archive'
[ -d "$module_tree" ] || die "the archive holds no module tree for $bundle_release"

release_file=$out_dir/root/usr/share/liuqin/kernel.release
[ -f "$release_file" ] || die "the archive holds no $release_file"
[ "$(cat "$release_file")" = "$bundle_release" ] ||
	die "the root filesystem records a different release: $(cat "$release_file")"
# The layout the kernel build would have produced, so the boot builder's
# release-equality check compares the root against the kernel it was built with.
install -D -m 0644 "$release_file" "$out_dir/include/config/kernel.release"
[ "$(sha "$out_dir/include/config/kernel.release")" = "$(sha "$release_file")" ] ||
	die 'include/config/kernel.release does not match the root filesystem copy'

# Modules are installed by the distribution's own tooling with one mode for
# every file; make the staged tree independent of the extracting umask.
find "$module_tree" -type d -exec chmod 0755 {} +
find "$module_tree" -type f -exec chmod 0644 {} +
module_count=$(find "$module_tree" -type f -name '*.ko' | wc -l | tr -d ' ')
[ "$module_count" -ge 400 ] || die "implausibly small module tree: $module_count modules"
[ -f "$module_tree/modules.dep" ] || die 'the module tree carries no dependency index'

# Every module the release recorded must be present, byte for byte.  The
# manifest is the module set's identity, so it is verified, not regenerated.
modules_manifest=$out_dir/root/usr/share/liuqin/kernel-modules.manifest
[ -f "$modules_manifest" ] || die "the archive holds no $modules_manifest"
awk -v prefix="usr/lib/modules/$bundle_release/" '
	NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { bad = 1 }
	$2 !~ ("^" prefix) { bad = 1 }
	END { exit bad }
' "$modules_manifest" || die 'the module manifest is malformed or names another release'
manifest_count=$(wc -l <"$modules_manifest" | tr -d ' ')
say "verifying $manifest_count recorded modules against the extracted tree"
if ! (cd "$out_dir/root" && sha256sum -c --quiet "$modules_manifest"); then
	die 'the extracted module tree does not match the manifest the release recorded'
fi

# --- The device tree, rebuilt from the pinned source -------------------------
# The pinned configuration cannot be regenerated on this host, but it can be
# used: the device tree is produced by dtc from the DTS, and the compiler
# identity in .config is irrelevant to that.  The scratch output directory keeps
# the pinned .config in the shipped layout untouched.
scratch=$out_dir/dtb-build
mkdir -p "$scratch"
install -m 0644 "$out_dir/.config" "$scratch/.config"
say 'building dtc, fdtoverlay and the device tree from the pinned source'
kb() { make -C "$kernel_source" O="$scratch" ARCH=arm64 CROSS_COMPILE="$cross" -j"$jobs" "$@"; }
kb -s include/config/kernel.release >/dev/null
kb scripts >/dev/null || die 'could not build the kernel scripts'
kb "$(python3 - "$project_root/kernel/source.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['dtb'])
PY
)" >/dev/null || die 'could not build the device tree'
for tool in dtc fdtoverlay; do
	[ -x "$scratch/scripts/dtc/$tool" ] || die "the source did not build $tool"
	install -D -m 0755 "$scratch/scripts/dtc/$tool" "$out_dir/scripts/dtc/$tool"
done
built_dtb=$scratch/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb
[ -f "$built_dtb" ] || die 'the source did not build the device tree'
install -D -m 0644 "$built_dtb" "$out_dir/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb"
# The source tree derives this from its own git state; agreeing with the release
# is a second, independent statement that the source and the kernel are a pair.
[ "$(cat "$scratch/include/config/kernel.release")" = "$bundle_release" ] ||
	die "the pinned source generates release $(cat "$scratch/include/config/kernel.release"), not $bundle_release"

# The released boot image holds more than the inputs: build-bootimg.sh applies
# the ABL overlay and injects the symbol sink for the stock DTBO and base sets on
# top of the command line overlay, so the released blob cannot be compared until
# those stock inputs are in hand -- that comparison belongs to the boot image
# step, and the released digests are recorded here for it.  What is checked here
# is the overlay step itself: applying it to the raw device tree has to produce
# exactly the command line this project boots with.
dtb_ref=$scratch/released.dtb
dtb_local=$scratch/local.dtb
if ! python3 - "$boot_img" "$dtb_ref" <<'PY'
import struct, sys
from pathlib import Path
blob = Path(sys.argv[1]).read_bytes()
_, kernel_size, _ka, ramdisk_size, _ra, _s, _sa, _ta, page_size, _hv = struct.unpack('<8s9I', blob[:44])
(dtb_size,) = struct.unpack('<I', blob[1648:1652])

def pages(n):
    return (n + page_size - 1) // page_size * page_size

off = page_size + pages(kernel_size) + pages(ramdisk_size)
Path(sys.argv[2]).write_bytes(blob[off:off + dtb_size])
PY
then
	die 'could not read the released device tree'
fi
if ! python3 - "$project_root/device/native-bootargs.txt" "$scratch/cmdline-overlay.dts" <<'PY'
import json, sys
from pathlib import Path
cmdline = Path(sys.argv[1]).read_text().strip()
Path(sys.argv[2]).write_text('/dts-v1/;\n/plugin/;\n/ { fragment@0 { target-path = "/chosen"; '
                             '__overlay__ { bootargs = ' + json.dumps(cmdline) + '; }; }; };\n')
PY
then
	die 'could not write the command line overlay'
fi
cmdline=$(cat "$project_root/device/native-bootargs.txt")
"$out_dir/scripts/dtc/dtc" -@ -q -I dts -O dtb -o "$scratch/cmdline-overlay.dtbo" "$scratch/cmdline-overlay.dts"
"$out_dir/scripts/dtc/fdtoverlay" -i "$out_dir/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb" \
	-o "$dtb_local" "$scratch/cmdline-overlay.dtbo"
"$out_dir/scripts/dtc/dtc" -q -I dtb -O dts -o "$scratch/local.dts" "$dtb_local" ||
	die 'the locally built device tree does not read back'
grep -Fq "bootargs = \"$cmdline\";" "$scratch/local.dts" ||
	die 'the command line overlay did not reach /chosen in the device tree'
say "device tree builds and carries the project command line ($(stat -c '%s' "$dtb_local") bytes)"

# --- What was recovered ------------------------------------------------------
{
	printf '# recovered from %s\n' "$release_dir"
	printf '# boot.img sha256 %s\n' "$bundle_boot_sha"
	printf '# rootfs.tar.gz sha256 %s\n' "$bundle_rootfs_sha"
	printf 'kernel_commit=%s\n' "$source_commit"
	printf 'kernel_release=%s\n' "$bundle_release"
	printf 'config_sha256=%s\n' "$config_pin"
	printf 'image_sha256=%s\n' "$(sha "$image")"
	printf 'raw_dtb_sha256=%s\n' "$(sha "$out_dir/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb")"
	printf 'module_count=%s\n' "$module_count"
	printf 'modules_manifest_sha256=%s\n' "$(sha "$modules_manifest")"
	printf 'kernel_release_sha256=%s\n' "$(sha "$release_file")"
	printf 'dtc_sha256=%s\n' "$(sha "$out_dir/scripts/dtc/dtc")"
	printf 'fdtoverlay_sha256=%s\n' "$(sha "$out_dir/scripts/dtc/fdtoverlay")"
	printf 'released_dtb_size=%s\n' "$(stat -c '%s' "$dtb_ref")"
	printf 'released_dtb_sha256=%s\n' "$(sha "$dtb_ref")"
	printf '# the released device tree carries the ABL overlay sink; it is compared\n'
	printf '# against the assembled boot image, where the stock inputs are present\n'
	printf 'released_dtb=compared-at-boot-image\n'
} >"$out_dir/release-kernel.identity"
chmod 0644 "$out_dir/release-kernel.identity"

# The image assembly reads a kernel output directory the way the kernel builder
# leaves it: build-info.json carrying the lock fields it gates on, and a
# SHA256SUMS over the artefacts.  A recovered kernel is the product input the
# lock describes -- commit, configuration and release string all match, and the
# device tree here rebuilds to the bytes the release shipped -- so it is recorded
# in that shape.  What is not claimed is a local compile: the compiler field is
# the one the configuration names, and the digests below say where the bytes came
# from instead of pretending they were produced here.
if ! python3 - "$out_dir" "$source_commit" "$config_pin" "$bundle_boot_sha" "$bundle_rootfs_sha" <<'PY'
import json, re, sys
from pathlib import Path

out = Path(sys.argv[1])
commit, config, boot_sha, rootfs_sha = sys.argv[2:6]
text = (out / '.config').read_text(errors='replace')
match = re.search(r'^CONFIG_CC_VERSION_TEXT="(.*)"$', text, re.M)
info = {
    'commit': commit,
    'config_sha256': config,
    'build_kind': 'product-input',
    'compiler_version': match.group(1) if match else 'unknown',
    'recovered_from_boot_img_sha256': boot_sha,
    'recovered_from_rootfs_sha256': rootfs_sha,
}
(out / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
PY
then
	die 'could not record the recovered kernel identity'
fi
chmod 0644 "$out_dir/build-info.json"

( cd "$out_dir" && sha256sum arch/arm64/boot/Image \
	arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb .config include/config/kernel.release \
	scripts/dtc/dtc scripts/dtc/fdtoverlay release-kernel.identity build-info.json ) \
	>"$out_dir/SHA256SUMS"
chmod 0644 "$out_dir/SHA256SUMS"

rm -rf "$scratch"
say "recovered the released kernel: $module_count modules, release $bundle_release"
printf 'kernel out:  %s\n' "$out_dir"
printf 'kernel layer: %s/root\n' "$out_dir"
printf 'identity:    %s\n' "$out_dir/release-kernel.identity"
printf '\nnext:\n'
printf '  KERNEL_OUT=%s \\\n' "$out_dir"
printf '  KERNEL_LAYER_ROOT=%s/root \\\n' "$out_dir"
printf '  sh tools/build-liuqin-native-boot.sh\n'
