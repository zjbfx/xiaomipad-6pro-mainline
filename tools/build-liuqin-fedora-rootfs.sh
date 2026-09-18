#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build the liuqin Fedora root filesystem: a pinned Fedora Workstation (GNOME)
# aarch64 tree assembled on a Fedora host with dnf --installroot.
#
# This is the Fedora counterpart of build-liuqin-ubuntu-desktop-rootfs.sh.  Both
# produce the same two artefacts consumed by build-liuqin-native-root.sh:
#
#   <root>/            the assembled tree
#   <root>.manifest    the tree manifest (type, mode, owner, path + file hashes)
#
# Stages are individually rerunnable so a failure late in the install does not
# cost the whole download again:
#
#   sh tools/build-liuqin-fedora-rootfs.sh bootstrap    # @core base
#   sh tools/build-liuqin-fedora-rootfs.sh workstation  # GNOME desktop + device deps
#   sh tools/build-liuqin-fedora-rootfs.sh configure    # first-boot-neutral system edits
#   sh tools/build-liuqin-fedora-rootfs.sh preflight    # assert what stage 1 will assert
#   sh tools/build-liuqin-fedora-rootfs.sh manifest     # tree manifest + identity
#   sh tools/build-liuqin-fedora-rootfs.sh all          # the five in order
#
# Cross-architecture install needs an aarch64 binfmt interpreter on the host
# (Fedora: qemu-user-static).  The tree is built with --forcearch=aarch64 so the
# host's own repository definitions are reused with basearch flipped; nothing
# Fedora-specific is downloaded from a third-party mirror.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${OUT_DIR:-"$project_root/out/fedora-rootfs"}
root=$out_dir/rootfs
manifest=$root.manifest
identity=$out_dir/fedora-rootfs.identity

# Pin the release rather than following the host, so a host upgrade cannot
# silently change what this tree is.  Default to the host's release only because
# the same dnf then resolves the same repository metadata it already trusts.
fedora_release=${FEDORA_RELEASE:-$(rpm -E %fedora)}
arch=${FEDORA_ARCH:-aarch64}
# The distribution pieces the device layer and the admission gate depend on
# (GNOME session, NetworkManager, BlueZ, PipeWire, the sensor proxy), kept as an
# explicit list because comps environments move between releases and an explicit
# list is auditable and diffable.  This is *not* the desktop: the applications a
# Workstation user expects come from the comps environment the workstation stage
# installs, and an explicit list alone produces a working but empty shell.
desktop_packages=${FEDORA_DESKTOP_PACKAGES:-"\
NetworkManager NetworkManager-wifi bluez busybox chrony dbus-daemon dconf gdm gnome-control-center \
gnome-initial-setup gnome-session gnome-settings-daemon gnome-shell iio-sensor-proxy \
pipewire pipewire-pulseaudio wireplumber polkit util-linux shadow-utils \
systemd-udev systemd-pam rpm dnf5 glib2 mesa-dri-drivers libdrm libinput xorg-x11-server-Xwayland"}

# dbus-daemon and systemd-pam are named explicitly because Fedora ships both as
# weak dependencies, which install_weak_deps=False drops -- and a graphical
# session needs both:
#   * GDM's Wayland session helper execs `dbus-daemon --session --print-address`
#     to start the user session bus; without it every session dies with
#     "Unable to run session message bus" and GDM retries until it gives up.
#   * pam_systemd.so is what registers the session with logind and thus starts
#     the user systemd instance.  Without the module the `-session optional`
#     line in system-auth simply loads nothing, so gnome-session never finds
#     org.freedesktop.systemd1 on the session bus and dies before any window.
# On the device both failures look the same: a black screen, no greeter.  The
# preflight stage asserts both files for exactly that reason.

# Packages that must not land in a device root: the tablet boots the project's
# own kernel from the boot partition, and a second kernel plus its generated
# initramfs only adds weight and a conflicting /usr/lib/modules tree.
exclude_packages='kernel,kernel-core,kernel-modules,kernel-modules-extra,kernel-devel'

die() { printf 'build-liuqin-fedora-rootfs: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-liuqin-fedora-rootfs: %s\n' "$*"; }

case $out_dir in
"$project_root"/out/*) ;;
*) die "refusing an output directory outside out/: $out_dir" ;;
esac

[ "$(id -u)" = 0 ] || die 'run as root (rpm install into a foreign root needs it)'
command -v dnf >/dev/null || die 'dnf is required'
command -v qemu-aarch64-static >/dev/null || command -v qemu-aarch64 >/dev/null ||
	die 'an aarch64 binfmt interpreter is required (dnf install qemu-user-static)'

# Only the official Fedora repositories are consulted.  A build host commonly
# carries third-party repositories (RPM Fusion, Copr) that have no aarch64
# branch; letting dnf read them makes every metadata refresh fail with a 404 for
# the target architecture and can abort the install.  Copying the two official
# definitions into a private reposdir is both reproducible and immune to
# whatever the host has been configured with.
repos_dir=$out_dir/repos.d
prepare_repos() {
	[ -d "$repos_dir" ] && [ -n "$(ls -A "$repos_dir" 2>/dev/null)" ] && return 0
	mkdir -p "$repos_dir"
	for repo in fedora.repo fedora-updates.repo fedora-updates-archive.repo; do
		[ -f "/etc/yum.repos.d/$repo" ] && cp "/etc/yum.repos.d/$repo" "$repos_dir/"
	done
	[ -n "$(ls -A "$repos_dir" 2>/dev/null)" ] ||
		die 'no official Fedora repository definitions found in /etc/yum.repos.d'
	say "using official repositories only: $(ls "$repos_dir" | tr '\n' ' ')"
}
prepare_repos

dnf_install_root() {
	dnf --installroot="$root" --releasever="$fedora_release" --forcearch="$arch" \
		--setopt=reposdir="$repos_dir" \
		--setopt=install_weak_deps=False --setopt=keepcache=False \
		--setopt=tsflags=nodocs --exclude="$exclude_packages" -y "$@"
}

stage_bootstrap() {
	[ ! -e "$root" ] || die "bootstrap refuses an existing tree: $root (remove it to rebuild)"
	mkdir -p "$root"
	say "installing the Fedora $fedora_release $arch base into $root"
	dnf_install_root install @core
	# The binfmt interpreter is what makes the following stages possible at all;
	# prove it now instead of failing halfway through the desktop install.
	[ -x "$root/usr/lib/systemd/systemd" ] || die 'no systemd in the new tree'
	[ -x "$root/usr/bin/dnf" ] || dnf_install_root install dnf
	say 'bootstrap PASS'
}

stage_workstation() {
	[ -x "$root/usr/lib/systemd/systemd" ] || die "run the bootstrap stage first: $root"
	say "installing GNOME and the device-layer dependencies"
	# The image is a Fedora Workstation, so the desktop comes from the same comps
	# environment the installer uses: Files, Terminal, Software, Firefox,
	# LibreOffice, the document and image viewers.  The explicit list is added on
	# top because it carries what the device layer and the admission gate need,
	# and those must not depend on a group definition that moves between
	# releases.  The kernel exclude above still applies to group members.
	# Two invocations on purpose: `group install` is how dnf5 resolves an
	# environment id, and the package list stays a separate, explicit step.
	dnf_install_root group install '@workstation-product-environment'
	# shellcheck disable=SC2086
	dnf_install_root install $desktop_packages
	# Stage 1 admits the root only if its systemd really is a systemd.
	chroot "$root" /usr/lib/systemd/systemd --version >/dev/null ||
		die 'the new tree cannot execute its own systemd'
	say 'workstation PASS'
}

stage_configure() {
	[ -d "$root/etc" ] || die "run the bootstrap stage first: $root"
	say 'applying first-boot-neutral system edits'

	printf 'liuqin\n' >"$root/etc/hostname"
	chmod 0644 "$root/etc/hostname"

	# Stage 1 execs /usr/lib/systemd/systemd directly, and the project's own
	# topology gate wants exactly this symlink at exactly this path.
	ln -sfn ../lib/systemd/systemd "$root/usr/sbin/init"

	# Fedora's display manager is gdm.service; the project's admission gate is
	# parameterised for it (see initramfs/init), unlike Ubuntu's gdm3.
	if [ -e "$root/usr/lib/systemd/system/gdm.service" ]; then
		ln -sfn /usr/lib/systemd/system/gdm.service "$root/etc/systemd/system/display-manager.service"
	else
		die 'gdm.service is missing; is gdm in the package list?'
	fi
	ln -sfn /usr/lib/systemd/system/graphical.target "$root/etc/systemd/system/default.target"

	# The sensor stack's provisioning resolves this account in the target root
	# (tools/provision-liuqin-from-persist.sh); Fedora has no such user and the
	# tree would fail provisioning without it.  Pick stable ids so the registry
	# ownership written on the tablet is reproducible.
	#
	# /etc/gshadow takes name:passwd:admins:members -- four fields, the same
	# shape as /etc/group.  A /etc/shadow-shaped line here (nine fields) does not
	# parse, and then every %sysusers scriptlet that reads the file dies with
	# "Failed to add existing group ... Invalid argument" -- which makes dnf
	# refuse every package that creates a user or a group, long after this line
	# was written.  Keep the two formats apart.
	if ! grep -q '^fastrpc:' "$root/etc/group" 2>/dev/null; then
		printf 'fastrpc:x:2907:\n' >>"$root/etc/group"
		printf 'fastrpc:x:2907:2907:liuqin fastrpc:/nonexistent:/usr/sbin/nologin\n' >>"$root/etc/passwd"
		printf 'fastrpc:!*:20000:0:99999:7:::\n' >>"$root/etc/shadow"
		printf 'fastrpc:!::\n' >>"$root/etc/gshadow"
	fi

	# systemd generates the machine id on first boot; a placeholder that is
	# already populated would be copied to every installed tablet.
	rm -f "$root/etc/machine-id"
	: >"$root/etc/machine-id"
	chmod 0444 "$root/etc/machine-id"

	# The project's shell and guard scripts run on a BusyBox pinned at
	# /usr/local/bin/busybox.  Fedora ships one, so no external static build is
	# needed; it is dynamically linked, which is fine because it only ever runs
	# inside this root.
	if [ -x "$root/usr/bin/busybox" ]; then
		install -D -m 0755 "$root/usr/bin/busybox" "$root/usr/local/bin/busybox"
	else
		die 'the busybox package did not install /usr/bin/busybox'
	fi

	# The repository cache is host metadata, not part of the system.
	rm -rf "$root/var/cache/dnf" "$root/var/cache/PackageKit" "$root/var/lib/dnf"
	rm -f "$root/etc/resolv.conf"
	say 'configure PASS'
}

# Mirrors the stage-1 gates in initramfs/init for the native profile, with the
# Fedora names.  Failing here costs seconds; failing on the tablet costs a boot
# loop and a rescue shell.
stage_preflight() {
	[ -d "$root/etc" ] || die "run the bootstrap stage first: $root"
	say 'asserting the stage-1 admission requirements'

	for path in \
		/usr/lib/systemd/systemd \
		/usr/sbin/gdm \
		/usr/bin/gnome-shell \
		/usr/bin/hexagonrpcd \
		/usr/local/bin/busybox \
		/usr/local/bin/liuqin-shell \
		/usr/libexec/iio-sensor-proxy \
		/usr/local/sbin/liuqin-gnome-storage-guard \
		/usr/local/sbin/liuqin-gnome-usb-rescue \
		/usr/local/libexec/liuqin-power-keyd \
		/usr/local/libexec/liuqin-power-key-action \
		/usr/local/sbin/liuqin-bt-public-addr \
		/usr/local/sbin/liuqin-wlan-mac \
		/usr/libexec/liuqin-ssc-sample-gate; do
		# The project-owned half of this list is installed by the device layer,
		# which runs after this stage; only the distro half is checked here.
		case $path in
		/usr/bin/gnome-shell | /usr/sbin/gdm | /usr/libexec/iio-sensor-proxy | \
		/usr/lib/systemd/systemd)
			[ -e "$root$path" ] || die "missing from the Fedora tree: $path"
			;;
		esac
	done

	[ -L "$root/usr/sbin/init" ] &&
		[ "$(readlink "$root/usr/sbin/init")" = ../lib/systemd/systemd ] ||
		die '/usr/sbin/init is not the systemd symlink'
	[ -L "$root/etc/systemd/system/default.target" ] &&
		[ "$(readlink "$root/etc/systemd/system/default.target")" = /usr/lib/systemd/system/graphical.target ] ||
		die 'default.target does not point at graphical.target'
	[ -L "$root/etc/systemd/system/display-manager.service" ] &&
		[ "$(readlink "$root/etc/systemd/system/display-manager.service")" = /usr/lib/systemd/system/gdm.service ] ||
		die 'display-manager.service does not point at gdm.service'
	grep -q '^fastrpc:' "$root/etc/passwd" || die 'the fastrpc account is missing'
	# Both files are weak dependencies that install_weak_deps=False drops, and
	# neither absence is visible until first boot: dbus-daemon is what GDM execs
	# for the session bus, pam_systemd.so is what makes logind register the
	# session and start the user systemd instance.  Fail here instead of on the
	# tablet, where the symptom is only a black screen.
	for path in /usr/bin/dbus-daemon /usr/lib64/security/pam_systemd.so; do
		[ -e "$root$path" ] || die "missing from the Fedora tree (weak dependency): $path"
	done
	[ "$(stat -c '%a' "$root/etc/machine-id")" = 444 ] || die 'machine-id is not the 0444 placeholder'
	chroot "$root" /usr/lib/systemd/systemd --version >/dev/null ||
		die 'the tree cannot execute its own systemd'
	say 'preflight PASS'
}

stage_manifest() {
	[ -d "$root" ] || die "run the bootstrap stage first: $root"
	[ ! -e "$manifest" ] || die "manifest already exists: $manifest (remove it to rebuild)"
	say "writing $manifest"
	# Same shape as the Ubuntu builder's manifest: one line per entry as
	# "type mode owner:group path", with the sha256 appended for regular files.
	# The contract generator consumes the hashes, build-liuqin-native-root.sh
	# consumes the types and modes.
	cd "$root"
	find . -printf '%y %m %u:%g %p\n' | LC_ALL=C sort >"$manifest.types"
	find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null |
		sed 's|  \./|  ./|' >"$manifest.hashes"
	entries=$(wc -l <"$manifest.types")
	# Floor only: this catches an empty or half-installed tree.  The explicit
	# package list is deliberately smaller than a Workstation ISO install (no
	# office suite, no games, no second kernel), so ~37k entries is the expected
	# order of magnitude rather than a target.
	[ "$entries" -ge 20000 ] ||
		die "only $entries entries in the tree; is this really a Workstation root?"
	{
		printf '# liuqin Fedora rootfs manifest\n'
		printf '# release=%s arch=%s\n' "$fedora_release" "$arch"
		cat "$manifest.types"
	} >"$manifest"
	rm -f "$manifest.types"

	# Record what was actually resolved, so a later build can be compared even
	# though Fedora has no single pinned download hash like the Ubuntu ISO.
	chroot "$root" rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null |
		LC_ALL=C sort >"$out_dir/fedora-rootfs.packages"
	{
		printf 'fedora_release=%s\n' "$fedora_release"
		printf 'arch=%s\n' "$arch"
		printf 'entries=%s\n' "$entries"
		printf 'packages=%s\n' "$(wc -l <"$out_dir/fedora-rootfs.packages")"
		printf 'packages_sha256=%s\n' "$(sha256sum "$out_dir/fedora-rootfs.packages" | cut -d' ' -f1)"
		printf 'manifest_sha256=%s\n' "$(sha256sum "$manifest" | cut -d' ' -f1)"
	} >"$identity"
	say "manifest PASS ($entries entries)"
}

case ${1:-all} in
bootstrap) stage_bootstrap ;;
workstation) stage_workstation ;;
configure) stage_configure ;;
preflight) stage_preflight ;;
manifest) stage_manifest ;;
all)
	stage_bootstrap
	stage_workstation
	stage_configure
	stage_preflight
	stage_manifest
	;;
*)
	printf 'usage: %s [bootstrap|workstation|configure|preflight|manifest|all]\n' "$0" >&2
	exit 2
	;;
esac
