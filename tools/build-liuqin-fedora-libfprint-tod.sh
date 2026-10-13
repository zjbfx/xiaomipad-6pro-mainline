#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build the libfprint TOD ABI library for the Fedora root.
#
# Fedora has no such library, and cannot be configured into having one.  The
# tablet's OEM fingerprint driver, its fpc-oem-print client and its fprintd all
# carry `NEEDED libfprint-2-tod.so.1`, and Fedora's libfprint is built from the
# plain upstream release, which has no libfprint/tod/ directory at all: the TOD
# ABI ships only in the separate +tod1 release line (`-Dtod` defaults to true,
# but a tree with no tod sources has nothing for the switch to enable).  No
# subpackage carries it either -- `dnf repoquery --whatprovides
# libfprint-2-tod.so.1` is empty against the official repositories, which is
# what this port may read.  The Ubuntu path is the contrast: there the same
# library is a package, libfprint-2-tod1, and the deb path names it as a
# dependency.
#
# So the port builds it, from the exact source revision the project's own
# source lock names -- the digest below is that lock's, and it is the revision
# the prebuilt binaries were compiled against, so the ABI matches by
# construction rather than by two upstream revisions happening to agree.
#
# Both libraries are built and shipped together rather than only the TOD one.
# libfprint/tod/meson.build link_whole's the private libfprint implementation
# into the TOD library, so a TOD library from one revision beside a
# libfprint-2 from another puts two copies of the same core in one process; the
# pair, not the file, is the unit.
#
# The build runs inside an arm64 chroot over an overlay of the Fedora root, the
# same machinery build-liuqin-sensors-stack.sh uses for its components: the
# distribution tree is a read-only lowerdir, so the package manager and the
# compiler can never mutate the release root.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

libfprint_version='1.95.1+tod1'
# The project's source lock (fingerprint-build-inputs.tar.gz, source/SOURCE_LOCK.json)
# records this digest for this URL; the Ubuntu archive mirrors the upstream
# +tod1 release tarball under its Debian package name.
libfprint_source_sha256=b04c55ce1b1f0bcf97ca6e9e3dfbcad931ac2e8f87c29548c93d1aa69d9f6c60
libfprint_source_url="https://archive.ubuntu.com/ubuntu/pool/main/libf/libfprint/libfprint_${libfprint_version}.orig.tar.bz2"

rootfs=${FEDORA_ROOTFS_ROOT:-$project_root/out/fedora-rootfs/rootfs}
source_file=${LIBFPRINT_SOURCE:-$project_root/tools/local/downloads/libfprint/libfprint_${libfprint_version}.orig.tar.bz2}
out_dir=${OUT_DIR:-$project_root/out/liuqin-libfprint-tod-fedora}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 12)}
# The libraries land in the distribution library directory, which is lib64 on
# Fedora and lib/aarch64-linux-gnu on the Ubuntu path.  Nothing else about this
# script is distribution-shaped, so the name is a parameter rather than a
# second copy of the script.
libdir=${LIBDIR:-lib64}
caller_uid=${SUDO_UID:-$(id -u)}
caller_gid=${SUDO_GID:-$(id -g)}

die() { printf 'build-liuqin-fedora-libfprint-tod: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-liuqin-fedora-libfprint-tod: %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die 'run as root (an overlay mount and arm64 chroot are required)'
[ -x "$rootfs/usr/lib/systemd/systemd" ] || die "not a usable Fedora root: $rootfs"
case $libdir in lib64 | lib | lib/aarch64-linux-gnu) ;; *) die "unsupported libdir: $libdir" ;; esac
case $out_dir in "$project_root"/out/* | /tmp/*) ;; *) die 'OUT_DIR must be below out or /tmp' ;; esac
command -v mount >/dev/null || die 'mount is required'
command -v tar >/dev/null || die 'tar is required'

# Fetch the pinned source once, into a cache the caller keeps.  A truncated or
# substituted download must not reach the compiler, so the digest is checked
# before anything is unpacked and the cache only ever holds a verified file.
if [ ! -f "$source_file" ]; then
	command -v curl >/dev/null || die 'curl is required to fetch the pinned source'
	mkdir -p "$(dirname -- "$source_file")"
	say "fetching libfprint $libfprint_version"
	temporary=$source_file.download
	curl -fsSL --retry 3 -o "$temporary" "$libfprint_source_url" ||
		die "could not download $libfprint_source_url"
	[ "$(sha256sum "$temporary" | cut -d' ' -f1)" = "$libfprint_source_sha256" ] ||
		die 'downloaded libfprint source does not match the pinned digest'
	mv "$temporary" "$source_file"
fi
[ "$(sha256sum "$source_file" | cut -d' ' -f1)" = "$libfprint_source_sha256" ] ||
	die "LIBFPRINT_SOURCE does not match the pinned digest: $source_file"

work=$out_dir/work
merged=$work/merged
rm -rf "$work"
mkdir -p "$work/source" "$work/upper" "$work/overlay" "$work/dest" "$merged"

cleanup() {
	status=$?
	set +e
	[ "${mounted_devpts:-0}" = 1 ] && umount "$merged/dev/pts"
	[ "${mounted_source:-0}" = 1 ] && umount "$merged/build/source"
	[ "${mounted_etc_resolv:-0}" = 1 ] && umount "$merged/etc/resolv.conf"
	[ "${mounted_resolv:-0}" = 1 ] && umount "$merged/run/systemd/resolve/stub-resolv.conf"
	[ "${mounted_proc:-0}" = 1 ] && umount "$merged/proc"
	[ "${mounted_overlay:-0}" = 1 ] && umount "$merged"
	return "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# The tarball's single top-level directory is what meson is pointed at; the
# extraction is kept below the build directory so a resumed run reuses it
# rather than depending on the caller's cache layout.
tar -xjf "$source_file" -C "$work/source"
source_tree=$(find "$work/source" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -d "$source_tree/libfprint/tod" ] ||
	die 'the pinned source has no libfprint/tod/; it cannot provide the TOD ABI'
[ -f "$source_tree/meson_options.txt" ] || die "source tree looks wrong: $source_tree"
grep -q "^option('tod'" "$source_tree/meson_options.txt" ||
	die 'the pinned source does not offer the tod build option'

mount -t overlay overlay -o "lowerdir=$rootfs,upperdir=$work/upper,workdir=$work/overlay" "$merged"
mounted_overlay=1
mkdir -p "$merged/build/source" "$merged/build/work" "$merged/build/dest" \
	"$merged/run/systemd/resolve" "$merged/dev/pts"
mount --bind "$work/source" "$merged/build/source"
mounted_source=1
mkdir -p "$merged/build/work/libfprint"
mount -t proc proc "$merged/proc"
mounted_proc=1
mount -t devpts devpts "$merged/dev/pts" -o newinstance,ptmxmode=0666,mode=0620
mounted_devpts=1
# A dnf --installroot tree carries no device nodes.  Meson's Python needs
# /dev/urandom for its own bookkeeping and the compiler opens /dev/null through
# its driver; fill in only what the tree does not already provide, in the
# disposable upper.
while read -r node kind major minor; do
	[ -n "$node" ] || continue
	[ -c "$merged/dev/$node" ] && continue
	rm -f "$merged/dev/$node"
	mknod -m 0666 "$merged/dev/$node" "$kind" "$major" "$minor" ||
		die "could not create /dev/$node"
done <<'DEVS'
null c 1 3
zero c 1 5
full c 1 7
random c 1 8
urandom c 1 9
tty c 5 0
DEVS
[ -e "$merged/dev/ptmx" ] || ln -sfn pts/ptmx "$merged/dev/ptmx"
: >"$merged/run/systemd/resolve/stub-resolv.conf"
mount --bind /etc/resolv.conf "$merged/run/systemd/resolve/stub-resolv.conf"
mounted_resolv=1
# A Fedora root ships no /etc/resolv.conf -- systemd-resolved generates it at
# boot, and build-liuqin-fedora-rootfs.sh removes any copy so the tablet cannot
# inherit the build host's resolver.  dnf opens that path directly, so the host
# resolver has to be bound there for the dependency install to resolve.
if [ ! -L "$merged/etc/resolv.conf" ] && [ ! -s "$merged/etc/resolv.conf" ]; then
	[ -e "$merged/etc/resolv.conf" ] || : >"$merged/etc/resolv.conf"
	mount --bind /etc/resolv.conf "$merged/etc/resolv.conf"
	mounted_etc_resolv=1
fi

say 'installing the arm64 build dependencies'
# These are Fedora's own BuildRequires for libfprint, plus meson and a compiler,
# minus everything only its documentation, GObject introspection and installed
# tests need -- this build produces two shared objects and nothing else.  gusb,
# pixman, gudev and openssl are pulled in by drivers=all, which is what Fedora
# builds and what keeps the resulting libfprint-2 a faithful replacement for
# the package's own.
chroot "$merged" /usr/bin/env dnf -y --setopt=install_weak_deps=False \
	install gcc gcc-c++ meson ninja-build pkgconf-pkg-config \
	glib2-devel libgusb-devel libgudev-devel openssl-devel pixman-devel systemd-devel \
	|| die 'could not install the build dependencies into the chroot'

say "building libfprint $libfprint_version"
cat >"$merged/build/build.sh" <<'EOF'
#!/bin/sh
set -eu
jobs=${JOBS:-12}
unset LC_ALL
export LANG=C.UTF-8
# A stable package version and no host paths in the debug information: the two
# libraries are device-layer artifacts, and a caller comparing two builds of the
# same revision should see the same bytes.
export SOURCE_DATE_EPOCH=0
export CFLAGS='-O2 -g0 -ffile-prefix-map=/build=. -fdebug-prefix-map=/build=.'
export LDFLAGS='-Wl,--build-id=sha1'
meson setup /build/work/libfprint /build/source/libfprint-* \
	--prefix=/usr --libdir="$LIBDIR" --buildtype=release --wrap-mode=nodownload \
	-Ddrivers=all -Dtod=true \
	-Ddoc=false -Dintrospection=false -Dinstalled-tests=false -Dgtk-examples=false
meson compile -C /build/work/libfprint -j "$jobs"
DESTDIR=/build/dest meson install -C /build/work/libfprint
EOF
chmod 0755 "$merged/build/build.sh"
chroot "$merged" /usr/bin/env LIBDIR="$libdir" JOBS="$jobs" /build/build.sh ||
	die 'the libfprint build failed'

# Only the three runtime files are kept.  The .so development symlinks, the
# pkgconfig files, the headers and the gir are build-time concerns, and the udev
# rules and hwdb stay Fedora's: the libfprint package is still installed, and a
# second copy of a file systemd already reads would be a second owner of it.
dest=$merged/build/dest/usr/$libdir
[ -f "$dest/libfprint-2.so.2.0.0" ] || die "no libfprint-2.so.2.0.0 was installed under usr/$libdir"
[ -f "$dest/libfprint-2-tod.so.1" ] || die "no libfprint-2-tod.so.1 was installed under usr/$libdir"
for soname in libfprint-2.so.2 libfprint-2-tod.so.1; do
	[ -e "$dest/$soname" ] || die "the build produced no $soname"
done

say 'reading back the sonames and the symbols the driver imports'
for library in "$dest"/libfprint-2.so.2.0.0 "$dest"/libfprint-2-tod.so.1; do
	machine=$(LC_ALL=C readelf -h "$library" |
		sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
	[ "$machine" = AArch64 ] || die "not an AArch64 library: $library ($machine)"
done
# The library is only useful if the prebuilt driver's imports resolve against
# it.  Its two namespaces are its own: the TOD ABI is what the driver and the
# client ask the TOD library for, and these are the symbols this build must
# define.  Checking them here means a source that silently stopped exporting one
# fails at build time rather than on the tablet at enrollment.
defined_symbols() { # <library>
	LC_ALL=C readelf --dyn-syms --wide "$1" |
		awk '$7 != "UND" {print $8}' | sed 's/@.*//' | LC_ALL=C sort -u
}
tod_symbols=$(defined_symbols "$dest/libfprint-2-tod.so.1")
for symbol in fpi_device_probe_complete fpi_device_enroll_complete \
	fpi_device_verify_complete fpi_print_set_type; do
	printf '%s\n' "$tod_symbols" | grep -qx "$symbol" ||
		die "libfprint-2-tod.so.1 does not define $symbol"
done
core_symbols=$(defined_symbols "$dest/libfprint-2.so.2.0.0")
for symbol in fp_context_new fp_device_get_type; do
	printf '%s\n' "$core_symbols" | grep -qx "$symbol" ||
		die "libfprint-2.so.2.0.0 does not define $symbol"
done

artifacts=$out_dir/artifacts
mkdir -p "$artifacts"
stage=$work/stage
mkdir -p "$stage/usr/$libdir"
cp -a "$dest"/libfprint-2.so.2.0.0 "$stage/usr/$libdir/"
cp -a "$dest"/libfprint-2.so.2 "$stage/usr/$libdir/"
# The real file carries the soname; a build that produced only a symlink would
# leave the runtime loader with nothing to open.
rm -f "$stage/usr/$libdir/libfprint-2-tod.so.1"
cp -a "$dest"/libfprint-2-tod.so.1 "$stage/usr/$libdir/"
[ -f "$stage/usr/$libdir/libfprint-2-tod.so.1" ] ||
	die 'libfprint-2-tod.so.1 is not a regular file in the artifact'

chroot "$merged" rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' |
	LC_ALL=C sort >"$work/fedora-build-deps.tsv"

# The archive records the revision it came from, so a root built months later
# can say which source produced the library in it without re-deriving it from
# a digest.
cat >"$work/build-info.json" <<EOF
{
  "libfprint_version": "$libfprint_version",
  "libfprint_source_sha256": "$libfprint_source_sha256",
  "libfprint_source_url": "$libfprint_source_url",
  "libdir": "$libdir",
  "meson_options": "-Ddrivers=all -Dtod=true -Ddoc=false -Dintrospection=false -Dinstalled-tests=false -Dgtk-examples=false"
}
EOF
cp "$work/build-info.json" "$work/fedora-build-deps.tsv" "$stage/"

tar -C "$stage" -cf - usr build-info.json fedora-build-deps.tsv |
	gzip -9 -n >"$artifacts/libfprint-tod.tar.gz"
sha256sum "$artifacts/libfprint-tod.tar.gz" | cut -d' ' -f1 >"$artifacts/libfprint-tod.sha256"
chown -R "$caller_uid:$caller_gid" "$artifacts" 2>/dev/null || true

say "PASS ${artifacts}/libfprint-tod.tar.gz"
printf '%s  usr/%s/libfprint-2.so.2.0.0\n%s  usr/%s/libfprint-2-tod.so.1\n' \
	"$(sha256sum "$stage/usr/$libdir/libfprint-2.so.2.0.0" | cut -d' ' -f1)" "$libdir" \
	"$(sha256sum "$stage/usr/$libdir/libfprint-2-tod.so.1" | cut -d' ' -f1)" "$libdir"
say "LIBFPRINT_TOD_TAR=$artifacts/libfprint-tod.tar.gz"
