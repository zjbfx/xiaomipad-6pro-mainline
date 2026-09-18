#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Extract the stock device tree sets a liuqin boot image is assembled against.
#
# The bootloader applies a stock liuqin DTBO overlay to whatever device tree the
# boot image carries, and aborts the boot outright when that apply fails.  A
# mainline tree has no __symbols__ node, so the boot builder exports the union of
# the symbols every stock DTBO entry names -- and it also seeds that union from
# the stock base trees, because the overlay set the ABL really applies is not
# confined to the dtbo partition.  Both sets therefore have to come out of the
# unit's own stock images:
#
#   dtbo.img        an Android DT header over 44 entries
#   vendor_boot.img a v4 header whose dtb section is 14 device trees end to end
#
# The first is not quite the format it looks like: this ROM's DT header is big
# endian (the FDTs inside it are as always big endian, which is why reading it
# with an assumption of little endian yields a 738-million-entry table).  The
# endianness is detected rather than assumed, and the table is then checked
# against the section it describes: every entry has to lie inside the image and
# has to be an FDT of exactly the size the entry claims.
#
# The extractor asserts the counts the boot builder asserts, so a table that
# changed under a ROM update fails here, next to the images, rather than in the
# middle of a boot image assembly.
#
#   DTBO_IMG=~/stock/dtbo.img VENDOR_BOOT_IMG=~/stock/vendor_boot.img \
#   sh tools/extract-liuqin-stock-dtb-sets.sh
#
# Outputs, all under OUT_DIR:
#   dtbo/entry.NN                STOCK_OVERLAY_DIR
#   vendor_boot-dtbs/dtb-NN.dtb  STOCK_BASE_DIR
#   stock-dtb-sets.identity      what was extracted, with hashes
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dtbo_img=${DTBO_IMG:?"set DTBO_IMG to the stock dtbo.img"}
vendor_boot_img=${VENDOR_BOOT_IMG:?"set VENDOR_BOOT_IMG to the stock vendor_boot.img"}
out_dir=${OUT_DIR:-"$project_root/out/stock-dtb-sets"}
rom_note=${ROM_NOTE:-}

overlay_count_expected=44
base_count_expected=14

die() { printf 'extract-liuqin-stock-dtb-sets: %s\n' "$*" >&2; exit 1; }
say() { printf 'extract-liuqin-stock-dtb-sets: %s\n' "$*"; }

case $out_dir in
"$project_root"/out/*) ;;
*) die "refusing an output directory outside out/: $out_dir" ;;
esac
[ ! -e "$out_dir" ] || die "output directory already exists (single writer, fresh dir): $out_dir"
[ -f "$dtbo_img" ] || die "dtbo image is unavailable: $dtbo_img"
[ -f "$vendor_boot_img" ] || die "vendor boot image is unavailable: $vendor_boot_img"
command -v python3 >/dev/null || die 'python3 is required'

mkdir -p "$out_dir"
overlay_dir=$out_dir/dtbo
base_dir=$out_dir/vendor_boot-dtbs

# --- dtbo.img: the 44 overlay entries ---------------------------------------
say "extracting the DTBO entries from $dtbo_img"
if ! python3 - "$dtbo_img" "$overlay_dir" "$overlay_count_expected" <<'PY'
import struct, sys
from pathlib import Path

blob = Path(sys.argv[1]).read_bytes()
dest = Path(sys.argv[2])
expected = int(sys.argv[3])

FDT_MAGIC = b'\xd0\x0d\xfe\xed'
DT_MAGIC = 0xd7b7ab1e

# The header is eight uint32s.  The magic tells the endianness: this ROM writes
# the table big endian, and reading it the other way yields plausible-looking
# nonsense (738197504 entries) rather than an error.
for order in ('<', '>'):
    magic, total, header_size, entry_size, count, entries_off, page_size, version = \
        struct.unpack(order + '8I', blob[:32])
    if magic == DT_MAGIC:
        break
else:
    raise SystemExit('not an Android DT table (magic 0xd7b7ab1e not found)')
if version != 0:
    raise SystemExit(f'unsupported DT table version: {version}')
if count != expected:
    raise SystemExit(f'expected {expected} DTBO entries, found {count}')
if entry_size < 32:
    raise SystemExit(f'implausible DT entry size: {entry_size}')
if entries_off + count * entry_size > len(blob):
    raise SystemExit('the entry table runs past the end of the image')
if total > len(blob):
    raise SystemExit(f'the table claims {total} bytes, the image holds {len(blob)}')

dest.mkdir(parents=True, exist_ok=True)
written = 0
for index in range(count):
    off = entries_off + index * entry_size
    size, offset, dt_id, rev = struct.unpack(order + '4I', blob[off:off + 16])
    if offset + size > len(blob):
        raise SystemExit(f'entry {index} runs past the end of the image')
    entry = blob[offset:offset + size]
    if entry[:4] != FDT_MAGIC:
        raise SystemExit(f'entry {index} is not a device tree')
    (declared,) = struct.unpack('>I', entry[4:8])
    if declared != size:
        raise SystemExit(f'entry {index} declares {declared} bytes, the table records {size}')
    (dest / f'entry.{index:02d}').write_bytes(entry)
    written += 1
print(f'{written} entries, header is {"little" if order == "<" else "big"} endian, '
      f'page size {page_size}')
PY
then
	die 'could not extract the DTBO entries'
fi

# --- vendor_boot.img: the 14 base trees -------------------------------------
say "extracting the base device trees from $vendor_boot_img"
if ! python3 - "$vendor_boot_img" "$base_dir" "$base_count_expected" <<'PY'
import struct, sys
from pathlib import Path

blob = Path(sys.argv[1]).read_bytes()
dest = Path(sys.argv[2])
expected = int(sys.argv[3])

FDT_MAGIC = b'\xd0\x0d\xfe\xed'
if blob[:8] != b'VNDRBOOT':
    raise SystemExit('not an Android vendor boot image')
header_version, page_size = struct.unpack('<2I', blob[8:16])
if header_version not in (3, 4):
    raise SystemExit(f'unsupported vendor boot header version: {header_version}')
(vendor_ramdisk_size,) = struct.unpack('<I', blob[24:28])
# cmdline[2048] sits between the ramdisk fields and the rest.
header_size, dtb_size = struct.unpack('<2I', blob[2096:2104])
if page_size == 0 or page_size & (page_size - 1):
    raise SystemExit(f'implausible page size: {page_size}')

def pages(n):
    return (n + page_size - 1) // page_size * page_size

dtb_off = pages(header_size) + pages(vendor_ramdisk_size)
if dtb_off + dtb_size > len(blob):
    raise SystemExit('the dtb section runs past the end of the image')
section = blob[dtb_off:dtb_off + dtb_size]

# The section is the trees back to back, each one sized by its own header.
trees = []
pos = 0
while pos < len(section):
    if section[pos:pos + 4] != FDT_MAGIC:
        raise SystemExit(f'no device tree at offset {pos} of the dtb section')
    (declared,) = struct.unpack('>I', section[pos + 4:pos + 8])
    if declared < 8 or pos + declared > len(section):
        raise SystemExit(f'the device tree at offset {pos} declares {declared} bytes')
    trees.append(section[pos:pos + declared])
    pos += declared
if len(trees) != expected:
    raise SystemExit(f'expected {expected} base device trees, found {len(trees)}')

dest.mkdir(parents=True, exist_ok=True)
for index, tree in enumerate(trees):
    (dest / f'dtb-{index:02d}.dtb').write_bytes(tree)
print(f'{len(trees)} device trees, {sum(len(t) for t in trees)} bytes of {dtb_size}')
PY
then
	die 'could not extract the base device trees'
fi

overlay_count=$(find "$overlay_dir" -maxdepth 1 -type f -name 'entry.[0-9]*' | wc -l | tr -d ' ')
[ "$overlay_count" = "$overlay_count_expected" ] ||
	die "expected $overlay_count_expected DTBO entries, staged $overlay_count"
base_count=$(find "$base_dir" -maxdepth 1 -type f -name 'dtb-[0-9][0-9].dtb' | wc -l | tr -d ' ')
[ "$base_count" = "$base_count_expected" ] ||
	die "expected $base_count_expected base device trees, staged $base_count"

# --- What was extracted ------------------------------------------------------
{
	printf '# extracted from the stock images below\n'
	for source in "$dtbo_img" "$vendor_boot_img"; do
		printf '#   %s  %s\n' "$(sha256sum "$source" | cut -d' ' -f1)" "$source"
	done
	[ -z "$rom_note" ] || printf 'rom=%s\n' "$rom_note"
	printf 'overlay_dir=%s\n' "$overlay_dir"
	printf 'base_dir=%s\n' "$base_dir"
	printf 'overlay_count=%s\n' "$overlay_count"
	printf 'base_count=%s\n' "$base_count"
	( cd "$out_dir" && find dtbo vendor_boot-dtbs -type f -print | LC_ALL=C sort |
		while IFS= read -r rel; do
			printf '%s  %s\n' "$(sha256sum "$rel" | cut -d' ' -f1)" "$rel"
		done )
} >"$out_dir/stock-dtb-sets.identity"
chmod 0644 "$out_dir/stock-dtb-sets.identity"

say "extracted $overlay_count overlay entries and $base_count base trees"
printf 'overlays: %s\n' "$overlay_dir"
printf 'base:     %s\n' "$base_dir"
printf 'identity: %s\n' "$out_dir/stock-dtb-sets.identity"
printf '\nnext:\n'
printf '  STOCK_OVERLAY_DIR=%s \\\n' "$overlay_dir"
printf '  STOCK_BASE_DIR=%s \\\n' "$base_dir"
printf '  sh tools/build-liuqin-native-boot.sh\n'
