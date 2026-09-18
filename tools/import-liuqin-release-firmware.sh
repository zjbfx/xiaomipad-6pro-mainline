#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Recover the firmware pool from a published liuqin release bundle.
#
# tools/build-liuqin-firmware-prep.sh consumes a pool laid out the way the stock
# ROM extracts it (vendor_a.img / vendor_b.img / NON-HLOS.bin / BTFM.bin / the
# upstream linux-firmware tree).  That layout is reproducible from a stock ROM,
# but the pins it verifies were frozen against one specific ROM build: a unit
# whose own ROM is newer cannot reproduce them.
#
# A published bundle is the other admissible source.  Its rootfs already carries
# the *output* of the prep -- the same 197 files the pins describe -- and the
# bundle ships SHA256SUMS for the containing images, so the recovery is
# verifiable rather than a blind copy.  This script extracts that tree out of
# the boot image's first-boot initramfs (small, and covered by the same
# SHA256SUMS as everything else), re-verifies every pin from
# build-liuqin-firmware-prep.sh, and writes a pool whose shape the prep accepts.
#
# Nothing here relaxes a gate: the prep is still run afterwards, and it still
# has to agree.
#
#   RELEASE_DIR=~/project/miPad6pro/liuqin-v0.2.0 \
#   OUT_DIR=$PWD/out/from-release-firmware \
#   sh tools/import-liuqin-release-firmware.sh
#
# Outputs, all under OUT_DIR:
#   pool/                     FIRMWARE_POOL for build-liuqin-firmware-prep.sh and
#                             for build-liuqin-native-boot.sh
#   vpu/vpu20_4v.mbn          VPU_BLOB
#   topology/Xiaomi-Pad-6-Pro-tplg.bin   TOPOLOGY_BIN
#   hsp2-tuple/{hw2.0,hw2.1}  HSP2_TUPLE_DIR
#   import.manifest           what was recovered, with hashes
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${RELEASE_DIR:?"set RELEASE_DIR to an unpacked release bundle (holds bundle.json and SHA256SUMS)"}
out_dir=${OUT_DIR:-"$project_root/out/from-release-firmware"}

die() { printf 'import-liuqin-release-firmware: %s\n' "$*" >&2; exit 1; }
say() { printf 'import-liuqin-release-firmware: %s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
check() { # check <expected> <file>
	[ "$(sha "$2")" = "$1" ] || die "$2 does not match its pinned hash ($1)"
}

case $out_dir in
"$project_root"/out/*) ;;
*) die "refusing an output directory outside out/: $out_dir" ;;
esac
[ ! -e "$out_dir" ] || die "output directory already exists (single writer, fresh dir): $out_dir"
[ -d "$release_dir" ] || die "release directory is unavailable: $release_dir"
[ -f "$release_dir/bundle.json" ] && [ -f "$release_dir/SHA256SUMS" ] ||
	die "not a release bundle (no bundle.json/SHA256SUMS): $release_dir"

# --- The published bundle must be the one it claims to be --------------------
rootfs_tar=$release_dir/rootfs.tar.gz
[ -f "$rootfs_tar" ] || die "root filesystem archive is unavailable: $rootfs_tar"
bundle_rootfs_sha=$(python3 - "$release_dir/bundle.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['files']['rootfs.tar.gz'])
PY
)
say 'hashing the root filesystem archive (one pass over ~4.3 GiB)'
check "$bundle_rootfs_sha" "$rootfs_tar"
say "rootfs.tar.gz matches bundle.json ($bundle_rootfs_sha)"

# The pins are the ones build-liuqin-firmware-prep.sh enforces.  They are
# duplicated here so a bad recovery fails with the file it failed on rather than
# halfway through staging; the prep still re-verifies all of them afterwards.
touch_sha256="\
2582cf81d6eeb69b57cb8b18b2afe683e9cd7e20ed0be390e14ed75302b0c584  novatek_nt36532_m81_fw_csot.bin
3d9737da5e0fc3ea64e340c495067d4d6dcbd5ca2a2351fe955ec88fab35da1e  novatek_nt36532_m81_fw_tm.bin"
bt_pattern='^(hpbtfw2[01]\.tlv|hpnv2[01]g?\.(bin|b[0-9a-f]+))$'
bt_set=d31712321a1c15591148a2e6a7ce94a12445558d2de82b48e5815abc581203a0
wlan_board_sha=aa8ae92d781e09db8cffa960b00c9606e4bb65d9c7a89f9b32df1bd24aee8573
wlan_sha256="\
d94af8648a0347903b68809b4100ea816e76afb6ead967c8b353c6521500f285  amss.bin.zst
ba583c3550d15871dbbbe1349dab64bac5badced5b6bf122aa7263f8d7df76d4  board-2.bin.zst
7769d18f26c025008221702e6884c9225f375db46d3e584e20223e33728376ec  m3.bin.zst
c4b298869269bc55ca73d71beeb756b72a9b19e710cea2af0401accbafa2d3c7  regdb.bin.zst"
reg_sha256="\
92eec693a0a9ec460be6bb3ff9e22b259b2f906eddd2984dd90654b5ecfa0f18  regulatory.db
4242d15defb0608b917a2c3cd0dbea21c026a4acc905093e8947dd494c2e26b1  regulatory.db.p7s"
gpu_sha256="\
e67d1829f57fc8326d806234b932dc3b78e28a9940df34c70752f17d5f38b7aa  a730_sqe.fw
36296b019753fbb2a4733450a2d0a94e307238227297a747d0ff2811364f5d5f  a730_zap.mbn
b2d3f0e2a98fd6259ab9ffef16df63265542e6cc9a970d53d476e823d432042a  gmu_gen70000.bin"
dsp_set=7f9b43d3815b6592f541e0b870357010488980bc040b925e93bbf12d01282908
a730_zap_sha=36296b019753fbb2a4733450a2d0a94e307238227297a747d0ff2811364f5d5f
vpu_sha=3567fd4522323b132ae4dd0f94a34782b2bc6a8c5c5fb51edfdbe364450fc118
topology_sha=dff0c8af945c66d542a004931af66435966cee12c6c430d0fa0610c6d3d5d126
tuple_sha256="\
amss.bin:cc3e477fa698a28bdb8c8115a071893f9b2f5230de190ad525e74fd69bbb6092
m3.bin:6938b4bba268a02659ee5e16992971aa0e2fab103a4f60cbccf65e4bd8ac9836
board-2.bin:15811f0b799fc26a881bce02e282834cd41b77c2812443ffd931012552a7c1f9
regdb.bin:06810e85c94c8f412c4e72cb38546cac90db7fdbadd45aae00f977f862d38a7b"

# --- Unpack the firmware subtree ---------------------------------------------
# The rootfs carries the prep's output tree itself, so the paths here are the
# ones the pins name -- no renaming, no second-guessing the initramfs layout.
# The member list is deliberately narrow: the archive also holds the whole
# distribution firmware tree, which is not this project's payload.
mkdir -p "$out_dir" "$out_dir/extracted"
stage=$out_dir/extracted
say 'extracting the firmware subtree from the root filesystem archive'
tar -xzf "$rootfs_tar" -C "$stage" --wildcards --no-anchored \
	'usr/lib/firmware/qca/*' \
	'usr/lib/firmware/novatek/liuqin/*' \
	'usr/lib/firmware/ath11k/WCN6855/hw2.0/*' \
	'usr/lib/firmware/ath11k/WCN6855/hw2.1/board.bin' \
	'usr/lib/firmware/regulatory.db' \
	'usr/lib/firmware/regulatory.db.p7s' \
	'usr/lib/firmware/qcom/sm8475/liuqin/*' \
	'usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin' \
	'usr/lib/firmware/updates/qcom/*' \
	'usr/lib/firmware/updates/ath11k/WCN6855/*/*' ||
	die 'could not extract the firmware subtree'
src=$stage/usr/lib/firmware
[ -d "$src" ] || die "the archive holds no /usr/lib/firmware tree: $src"

# --- Lay the pool out the way the prep expects -------------------------------
pool=$out_dir/pool
touch_dir=$pool/touch-nt36532/vendor/firmware
bt_dir=$pool/bt-qca6490/vendor/bt_firmware/image
wlan_dir=$pool/wlan-qca6490/upstream/WCN6855/hw2.0
wlan_board=$pool/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf
reg_dir=$pool/regulatory/upstream
gpu_dir=$pool/gpu-adreno730/vendor
dsp_dir=$pool/dsp-sm8475/vendor/qcom/sm8475/liuqin
mkdir -p "$touch_dir" "$bt_dir" "$wlan_dir" "$(dirname "$wlan_board")" "$reg_dir" "$gpu_dir" "$dsp_dir" \
	"$out_dir/vpu" "$out_dir/topology" "$out_dir/hsp2-tuple/hw2.0" "$out_dir/hsp2-tuple/hw2.1"

printf '%s\n' "$touch_sha256" | while read -r hash name; do
	check "$hash" "$src/novatek/liuqin/$name"
	install -m 0644 "$src/novatek/liuqin/$name" "$touch_dir/$name"
done

(cd "$src/qca" && ls -1 | LC_ALL=C sort | grep -E "$bt_pattern") >"$out_dir/.bt-names" ||
	die "no Bluetooth firmware in $src/qca"
while IFS= read -r name; do
	install -m 0644 "$src/qca/$name" "$bt_dir/$name"
done <"$out_dir/.bt-names"
bt_seen=$(cd "$bt_dir" && printf '%s\n' "$(cat "$out_dir/.bt-names")" | xargs sha256sum | sha256sum | cut -d' ' -f1)
[ "$bt_seen" = "$bt_set" ] || die "Bluetooth firmware set digest mismatch: $bt_seen"
rm -f "$out_dir/.bt-names"

# The fallback board data is installed under the ath11k path in the tree; the
# prep wants the vendor_a.img name back.
check "$wlan_board_sha" "$src/ath11k/WCN6855/hw2.0/board.bin"
install -m 0644 "$src/ath11k/WCN6855/hw2.0/board.bin" "$wlan_board"
[ "$(dd if="$wlan_board" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] ||
	die 'WLAN board data is not an ELF'

printf '%s\n' "$wlan_sha256" | while read -r hash name; do
	check "$hash" "$src/ath11k/WCN6855/hw2.0/$name"
	install -m 0644 "$src/ath11k/WCN6855/hw2.0/$name" "$wlan_dir/$name"
done

printf '%s\n' "$reg_sha256" | while read -r hash name; do
	check "$hash" "$src/$name"
	install -m 0644 "$src/$name" "$reg_dir/$name"
done

check "$a730_zap_sha" "$src/qcom/sm8475/liuqin/a730_zap.mbn"
install -m 0644 "$src/qcom/sm8475/liuqin/a730_zap.mbn" "$gpu_dir/a730_zap.mbn"
printf '%s\n' "$gpu_sha256" | while read -r hash name; do
	case $name in a730_zap.mbn) continue ;; esac
	check "$hash" "$src/updates/qcom/$name"
	install -m 0644 "$src/updates/qcom/$name" "$gpu_dir/$name"
done

# The device-keyed DSP payloads: everything under qcom/sm8475/liuqin except the
# zap shader, which belongs to the GPU set.
for file in "$src/qcom/sm8475/liuqin"/*; do
	name=$(basename "$file")
	[ "$name" = a730_zap.mbn ] && continue
	install -m 0644 "$file" "$dsp_dir/$name"
done
dsp_count=$(find "$dsp_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')
[ "$dsp_count" = 68 ] || die "DSP firmware count differs from 68: $dsp_count"
dsp_seen=$(cd "$dsp_dir" && find . -maxdepth 1 -type f -printf '%P\n' | LC_ALL=C sort |
	xargs sha256sum | sha256sum | cut -d' ' -f1)
[ "$dsp_seen" = "$dsp_set" ] || die "DSP firmware set digest mismatch: $dsp_seen"

check "$vpu_sha" "$src/updates/qcom/vpu/vpu20_4v.mbn"
install -m 0644 "$src/updates/qcom/vpu/vpu20_4v.mbn" "$out_dir/vpu/vpu20_4v.mbn"

check "$topology_sha" "$src/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin"
install -m 0644 "$src/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin" "$out_dir/topology/Xiaomi-Pad-6-Pro-tplg.bin"

# Both hardware-revision request paths carry a raw copy; the prep installs one
# file into both, so one verified copy per name is enough.
printf '%s\n' "$tuple_sha256" | while read -r item; do
	name=${item%%:*}
	hash=${item#*:}
	check "$hash" "$src/updates/ath11k/WCN6855/hw2.0/$name"
	for rev in hw2.0 hw2.1; do
		install -m 0644 "$src/updates/ath11k/WCN6855/hw2.0/$name" "$out_dir/hsp2-tuple/$rev/$name"
	done
done

rm -rf "$stage"

# --- What was recovered ------------------------------------------------------
{
	printf '# recovered from %s\n' "$release_dir"
	printf '# rootfs.tar.gz sha256 %s\n' "$bundle_rootfs_sha"
	printf 'pool=%s\n' "$pool"
	printf 'vpu=%s\n' "$out_dir/vpu/vpu20_4v.mbn"
	printf 'topology=%s\n' "$out_dir/topology/Xiaomi-Pad-6-Pro-tplg.bin"
	printf 'hsp2_tuple=%s\n' "$out_dir/hsp2-tuple"
	(cd "$out_dir" && find pool -type f -print | LC_ALL=C sort |
		while IFS= read -r rel; do
			printf '%s  %s\n' "$(sha256sum "$rel" | cut -d' ' -f1)" "$rel"
		done)
	(cd "$out_dir" && for rel in vpu/vpu20_4v.mbn topology/Xiaomi-Pad-6-Pro-tplg.bin \
		hsp2-tuple/hw2.0/amss.bin hsp2-tuple/hw2.0/board-2.bin \
		hsp2-tuple/hw2.0/m3.bin hsp2-tuple/hw2.0/regdb.bin; do
		printf '%s  %s\n' "$(sha256sum "$rel" | cut -d' ' -f1)" "$rel"
	done)
} >"$out_dir/import.manifest"
chmod 0644 "$out_dir/import.manifest"

say "recovered $(grep -c '^[0-9a-f]\{64\}  ' "$out_dir/import.manifest") pinned files"
printf 'pool:     %s\n' "$pool"
printf 'manifest: %s\n' "$out_dir/import.manifest"
printf '\nnext:\n'
printf '  FIRMWARE_POOL=%s \\\n' "$pool"
printf '  VPU_BLOB=%s \\\n' "$out_dir/vpu/vpu20_4v.mbn"
printf '  TOPOLOGY_BIN=%s \\\n' "$out_dir/topology/Xiaomi-Pad-6-Pro-tplg.bin"
printf '  HSP2_TUPLE_DIR=%s \\\n' "$out_dir/hsp2-tuple"
printf '  OUT_DIR=%s/../firmware-tree \\\n' "$out_dir"
printf '  sh tools/build-liuqin-firmware-prep.sh\n'
