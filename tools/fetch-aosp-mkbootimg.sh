#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Fetch the pinned AOSP boot image tooling the boot builder runs.
#
# mkbootimg.py and unpack_bootimg.py are checksum-pinned twice over: here, and
# again in build-liuqin-native-boot.sh before either one is executed.  The pin
# names a revision, not a mirror, so any source that yields those exact bytes is
# as good as any other.
#
# The default source is the AOSP archive of that revision.  android.googlesource.com
# is unreachable from some networks; the GitHub mirror keeps the same commit, so
# it stands in when the archive cannot be fetched.  A checkout carries no archive
# digest to verify, which is why the two file hashes below are checked on both
# paths -- and they are the gate the boot builder applies anyway.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
download_dir="$project_root/tools/local/downloads"
extract_dir="$project_root/tools/local/aosp-mkbootimg"
commit=954bc3ead5e679005fddf3484d247f2557b3c2c9
archive="aosp-mkbootimg-$commit.tar.gz"
url="https://android.googlesource.com/platform/system/tools/mkbootimg/+archive/$commit.tar.gz"
mirror="https://github.com/LineageOS/android_system_tools_mkbootimg"
archive_sha256=434f155d717564c2c2cf4760afd05c338a37a5fbc3fa2eb6a474409dbf28c503
mkbootimg_sha256=37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c
unpack_sha256=06b54dd9a07c5281778e29e234e76f6e3faee8bf0c904a5ef88fdee30eeed12e

die() { printf 'fetch-aosp-mkbootimg: %s\n' "$*" >&2; exit 1; }
say() { printf 'fetch-aosp-mkbootimg: %s\n' "$*"; }

mkdir -p "$download_dir" "$extract_dir"

source=archive
if [ ! -f "$download_dir/$archive" ] || \
	! echo "$archive_sha256  $download_dir/$archive" | sha256sum --check --status; then
	rm -f "$download_dir/$archive"
	if ! curl --fail --location "$url" --output "$download_dir/$archive.part"; then
		rm -f "$download_dir/$archive.part"
		command -v git >/dev/null || die 'git is required to fetch from the mirror'
		source=mirror
	else
		mv "$download_dir/$archive.part" "$download_dir/$archive"
	fi
fi

if [ "$source" = archive ]; then
	echo "$archive_sha256  $download_dir/$archive" | sha256sum --check
	tar -xzf "$download_dir/$archive" -C "$extract_dir"
else
	say "android.googlesource.com is unreachable; taking the same commit from $mirror"
	work=$(mktemp -d)
	trap 'rm -rf "$work"' EXIT
	git -C "$work" init -q
	git -C "$work" remote add origin "$mirror"
	git -C "$work" fetch -q --depth 1 origin "$commit" ||
		die "the mirror does not carry $commit"
	# The whole tree, not just the two entry points: mkbootimg.py imports its
	# own gki/ helper on startup, which the archive path lays down as well.
	git -C "$work" checkout -q FETCH_HEAD -- . ||
		die 'the mirror checkout did not yield the boot image tools'
	rm -rf "$work/.git"
	cp -a "$work/." "$extract_dir/"
fi

echo "$mkbootimg_sha256  $extract_dir/mkbootimg.py" | sha256sum --check ||
	die 'mkbootimg.py does not match the pin'
echo "$unpack_sha256  $extract_dir/unpack_bootimg.py" | sha256sum --check ||
	die 'unpack_bootimg.py does not match the pin'

printf 'AOSP tag: android-16.0.0_r4\ncommit: %s\nsource: %s\n' "$commit" \
	"$([ "$source" = archive ] && printf '%s' "$url" || printf '%s' "$mirror")"
python3 "$extract_dir/mkbootimg.py" --help >/dev/null
python3 "$extract_dir/unpack_bootimg.py" --help >/dev/null
