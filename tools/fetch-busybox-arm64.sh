#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Fetch the pinned static ARM64 BusyBox the first-boot initramfs runs.
#
# This is the initramfs's own BusyBox, not the root filesystem's: stage 1 is a
# BusyBox script, and the applet set it relies on is the one this Ubuntu build
# carries.  The distribution's BusyBox is a separate thing, owned by the root
# and pinned by its own contract.
#
# The package is checksum-pinned and so is the binary inside it.  On a host with
# dpkg that is the whole story; on Fedora, where dpkg does not exist, the payload
# comes out of the same ar archive with binutils and tar.  The pin makes the
# extraction route irrelevant to what lands in the tree.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
download_dir="$project_root/tools/local/downloads"
extract_dir="$project_root/tools/local/busybox-arm64"
package=busybox-static_1.36.1-6ubuntu3.1_arm64.deb
url="http://ports.ubuntu.com/pool/main/b/busybox/$package"
package_sha256=d96535e0402c011e0ee43449799df2f4504d44b842e4f2b3a6cbc845508eaafc
binary_sha256=52151e7f322f926b64049cdaa1410dc3ea6485525e0624b05813791c219ae933

die() { printf 'fetch-busybox-arm64: %s\n' "$*" >&2; exit 1; }

mkdir -p "$download_dir" "$extract_dir"

if [ ! -f "$download_dir/$package" ] || \
	! echo "$package_sha256  $download_dir/$package" | sha256sum --check --status; then
	curl --fail --location "$url" --output "$download_dir/$package.part"
	mv "$download_dir/$package.part" "$download_dir/$package"
fi

echo "$package_sha256  $download_dir/$package" | sha256sum --check

if command -v dpkg-deb >/dev/null; then
	dpkg-deb --extract "$download_dir/$package" "$extract_dir"
	dpkg-deb --field "$download_dir/$package" Package Version Architecture
else
	# A .deb is an ar archive whose last members are control.tar.* and
	# data.tar.*.  The payload keeps its own compression, and tar reads that
	# from the file rather than from the name.
	command -v ar >/dev/null || die 'ar (binutils) is required to unpack the package'
	member=$(ar t "$download_dir/$package" | LC_ALL=C grep -E '^data\.tar\.' | head -n 1)
	[ -n "$member" ] || die "the package carries no data archive: $download_dir/$package"
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	ar p "$download_dir/$package" "$member" >"$work/$member"
	tar -xf "$work/$member" -C "$extract_dir"
	printf '%s (unpacked without dpkg)\n' "$member"
fi

echo "$binary_sha256  $extract_dir/usr/bin/busybox" | sha256sum --check ||
	die 'the BusyBox inside the package does not match the pin'

LC_ALL=C file "$extract_dir/usr/bin/busybox"
