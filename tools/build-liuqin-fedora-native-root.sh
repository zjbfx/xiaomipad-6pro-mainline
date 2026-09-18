#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Assemble the liuqin native Fedora root filesystem:
#
#   Fedora Workstation (GNOME) tree from build-liuqin-fedora-rootfs.sh
#   + the liuqin device layer installed as a file tree
#   + first-boot assembly (hostname, unit links, marker, topology gates)
#
# This is the Fedora counterpart of build-liuqin-native-root.sh.  The Ubuntu
# builder installs five .deb packages through an apt chroot; Fedora has no dpkg,
# so the device layer is installed as files and the *manifest* — not the package
# database — is what the boot contract pins.  That is deliberate: the admission
# gates hash files, so the package format is not observable to the tablet.
#
# Stages are individually rerunnable:
#
#   sh tools/build-liuqin-fedora-native-root.sh copy       # Fedora tree + system edits
#   sh tools/build-liuqin-fedora-native-root.sh device     # device layer payload
#   sh tools/build-liuqin-fedora-native-root.sh assemble   # unit links, marker, gates
#   sh tools/build-liuqin-fedora-native-root.sh preflight  # mirror of stage-1 admission
#   sh tools/build-liuqin-fedora-native-root.sh manifest   # tree manifest + hash list
#   sh tools/build-liuqin-fedora-native-root.sh pack       # rootfs.tar.gz
#   sh tools/build-liuqin-fedora-native-root.sh all        # copy..manifest
#
# Inputs, all required for `device`:
#   FEDORA_ROOTFS_ROOT        the tree produced by build-liuqin-fedora-rootfs.sh
#   KERNEL_LAYER_ROOT         released kernel layer (import-liuqin-release-kernel.sh)
#   FIRMWARE_POOL             prepared board firmware directory
#   AUDIO_TOPOLOGY            built AudioReach topology binary
#   SENSOR_STACK_TAR          built sensor stack archive (hexagonrpcd, ssccli,
#                             patched iio-sensor-proxy, registry import)
#
# The four built inputs come from the project's own builders.  POWER_SETTINGS_
# BINARY (a gnome-control-center built with the power panel patch) is deliberately
# not among them: the panel is a desktop convenience that no admission gate
# looks at, so its absence is a warning rather than a reason to refuse.  What the
# script does refuse is assembling without the kernel, because a root without its
# modules boots into a screen that never lights up.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${OUT_DIR:-"$project_root/out/fedora-native-root"}
fedora_root=${FEDORA_ROOTFS_ROOT:-"$project_root/out/fedora-rootfs/rootfs"}
kernel_layer=${KERNEL_LAYER_ROOT:?"set KERNEL_LAYER_ROOT to the released kernel layer"}
firmware_pool=${FIRMWARE_POOL:?"set FIRMWARE_POOL to the prepared firmware directory"}
audio_topology=${AUDIO_TOPOLOGY:?"set AUDIO_TOPOLOGY to the built AudioReach topology"}
sensor_stack_tar=${SENSOR_STACK_TAR:?"set SENSOR_STACK_TAR to the built sensor stack archive"}
power_settings_binary=${POWER_SETTINGS_BINARY:-}
power_key_cc=${POWER_KEY_CC:-${CROSS_COMPILE:-aarch64-linux-gnu-}gcc}
marker_sha256=4fdae4f7a27af8b0d4a2bbc168c7f01c3c5c6b5e245fcc521389d662f8212c5b

# Fedora's cross compiler is configured without a default sysroot: its own
# /usr/aarch64-linux-gnu/sys-root stays empty, and the glibc headers and startup
# objects live in a release-versioned sysroot package, so every compile has to
# name that directory.  CROSS_SYSROOT overrides what is discovered here.
cross_sysroot=${CROSS_SYSROOT:-}
if [ -z "$cross_sysroot" ]; then
	for candidate in /usr/aarch64-redhat-linux/sys-root/*; do
		if [ -d "$candidate/usr/include" ]; then
			cross_sysroot=$candidate
			break
		fi
	done
fi
cross_sysroot_flag=
[ -z "$cross_sysroot" ] || cross_sysroot_flag="--sysroot=$cross_sysroot"

# The Fedora gcc driver appends -latomic_asneeded to every non-static link; it is
# an ld script that pulls libatomic in only when something references it.  The
# cross toolchain has no aarch64 libatomic to satisfy that name, and the device
# helpers reference no atomic helpers, so the default is switched off where the
# compiler knows the option.  A toolchain without Fedora's patch (Debian's cross
# gcc) rejects the flag and has no need of it.
atomic_flag=
if "$power_key_cc" -fno-link-libatomic -x c -E /dev/null >/dev/null 2>&1; then
	atomic_flag=-fno-link-libatomic
fi

die() { printf 'build-liuqin-fedora-native-root: %s\n' "$*" >&2; exit 1; }
say() { printf 'build-liuqin-fedora-native-root: %s\n' "$*"; }

case $out_dir in
"$project_root"/out/*) ;;
*) die "refusing an output directory outside out/: $out_dir" ;;
esac
[ "$(id -u)" = 0 ] || die 'run as root (tree copy, ownership and xattrs need it)'
[ -x "$fedora_root/usr/lib/systemd/systemd" ] || die "not a Fedora root: $fedora_root"
root=$out_dir/rootfs

stage_copy() {
	[ ! -e "$out_dir" ] || die "copy refuses an existing output: $out_dir"
	mkdir -p "$out_dir"
	say "copying the Fedora tree to $root"
	cp -a "$fedora_root" "$root"

	# cp -a keeps the setuid and setgid bits only when the copy really runs with
	# the privilege to set them (CAP_FSETID).  When it does not, both are dropped
	# without a word: the tree still boots, and the only symptom appears on the
	# tablet, where sudo, passwd, su and pkexec stop working and the error text
	# ("effective uid is not 0") points at the account instead of the tree.  The
	# source tree is authoritative -- RPM installed it -- so replay the bits from
	# it and leave the count behind for preflight to re-check.
	find "$fedora_root" -perm /6000 -printf '%m %P\n' >"$out_dir/privileged.map"
	while read -r mode path; do
		[ -e "$root/$path" ] || die "a privileged file vanished in the copy: $path"
		chmod "$mode" "$root/$path"
	done <"$out_dir/privileged.map"
	[ "$(find "$root" -perm /6000 2>/dev/null | wc -l)" -ge "$(wc -l <"$out_dir/privileged.map")" ] ||
		die 'the copy dropped privileged mode bits and they could not be restored'

	# Fedora ships /etc/resolv.conf absent and lets systemd-resolved own the
	# stub; a leftover host copy would pin the tablet to the build host's DNS.
	rm -f "$root/etc/resolv.conf"

	# BlueZ must come up without a userspace handshake: the tablet's adapter is
	# addressed by the project's preconfigure unit, which runs before it.
	if [ -f "$root/etc/bluetooth/main.conf" ]; then
		if grep -q '^\[Policy\]' "$root/etc/bluetooth/main.conf"; then
			sed -i '/^\[Policy\]/a AutoEnable=true' "$root/etc/bluetooth/main.conf"
		else
			printf '\n[Policy]\nAutoEnable=true\n' >>"$root/etc/bluetooth/main.conf"
		fi
		grep -A1 '^\[Policy\]' "$root/etc/bluetooth/main.conf" | grep -qx 'AutoEnable=true' ||
			die 'could not set BlueZ AutoEnable'
	else
		die 'BlueZ main.conf is missing; is bluez in the package list?'
	fi

	# The first-boot marker is the root's identity for stage 1, and stage 1
	# pins its exact size and hash.
	printf 'liuqin-native-root-v1\n' >"$root/etc/liuqin-native-root"
	chown 0:0 "$root/etc/liuqin-native-root"
	chmod 0644 "$root/etc/liuqin-native-root"
	[ "$(sha256sum "$root/etc/liuqin-native-root" | cut -d' ' -f1)" = "$marker_sha256" ] ||
		die 'marker content does not match the stage-1 pin'
	say 'copy PASS'
}

stage_device() {
	[ -x "$root/usr/lib/systemd/systemd" ] || die "run the copy stage first: $root"
	say 'installing the device layer'

	# Board firmware first: it is the largest payload and the one stage 1 opens
	# during the first boot.
	[ -d "$firmware_pool" ] || die "firmware pool missing: $firmware_pool"
	cp -a "$firmware_pool/." "$root/usr/lib/firmware/"

	# The kernel the tablet boots.  Its Image and device tree go into the boot
	# image, its module tree goes here, and the release record is what the boot
	# builder compares against include/config/kernel.release -- so the two halves
	# have to be the same build.  Fedora's own kernel is excluded by the rootfs
	# builder, which leaves this tree as the only one in the root.
	[ -d "$kernel_layer/usr/lib/modules" ] || die "kernel layer missing: $kernel_layer"
	kernel_release=$(cat "$kernel_layer/usr/share/liuqin/kernel.release")
	case $kernel_release in
	'' | *[!A-Za-z0-9._+-]*) die "unsafe kernel release: $kernel_release" ;;
	esac
	[ -d "$kernel_layer/usr/lib/modules/$kernel_release" ] ||
		die "kernel layer holds no module tree for $kernel_release"
	cp -a "$kernel_layer/usr/lib/modules/$kernel_release" "$root/usr/lib/modules/"
	install -D -m 0644 "$kernel_layer/usr/share/liuqin/kernel.release" \
		"$root/usr/share/liuqin/kernel.release"
	find "$root/usr/lib/modules/$kernel_release" -type d -exec chmod 0755 {} +
	find "$root/usr/lib/modules/$kernel_release" -type f -exec chmod 0644 {} +
	rm -f "$root/usr/lib/modules/$kernel_release/build" "$root/usr/lib/modules/$kernel_release/source"

	# The binary dependency index belongs to the kmod that will read it, and the
	# release was indexed by another distribution's.  Re-index with this host's
	# depmod -- the same kmod family as the root -- and require the text indexes,
	# which are the module graph itself, to come out unchanged.  A graph that
	# moves is a different kernel and must stop the assembly.
	command -v depmod >/dev/null || die 'depmod (kmod) is required to index the module tree'
	index_before=$(mktemp -d)
	for index in modules.dep modules.alias modules.symbols modules.builtin \
		modules.softdep modules.devname; do
		cp -a "$root/usr/lib/modules/$kernel_release/$index" "$index_before/$index"
	done
	depmod -b "$root" "$kernel_release" || die 'depmod failed on the module tree'
	for index in modules.dep modules.alias modules.symbols modules.builtin \
		modules.softdep modules.devname; do
		cmp -s "$index_before/$index" "$root/usr/lib/modules/$kernel_release/$index" ||
			die "the module graph changed under depmod: $index"
	done
	rm -rf "$index_before"
	# The record of what the modules are is regenerated from the tree that is
	# actually in this root, so it never describes a tree that was re-indexed
	# underneath it.
	( cd "$root" && find "usr/lib/modules/$kernel_release" -type f -print0 |
		LC_ALL=C sort -z | xargs -0 sha256sum ) >"$root/usr/share/liuqin/kernel-modules.manifest"
	chmod 0644 "$root/usr/share/liuqin/kernel-modules.manifest"
	say "kernel layer installed: release $kernel_release"

	# The project-owned file tree: units, helpers, dconf locks, UCM, udev rules.
	# This is device/gnome-overlay in the repository, copied whole.  The
	# snap-admission pair comes along with it and is inert here -- the native
	# contract pins both files, and what stage 1 requires is that nothing
	# activates the unit, which the assemble stage enforces.
	# Fedora is usrmerged: /usr/local/sbin is a symlink to bin.  Two things
	# depend on it being a real directory here.  The units and the admission
	# contract name /usr/local/sbin explicitly, and the contract hashes the tree
	# by path, so a file that landed in bin would be recorded under the wrong
	# name and refuse generation.  And the sensor stack archive carries a
	# /usr/local/sbin directory entry, which replaces a symlink at that path --
	# stranding everything copied through it before the archive is unpacked.
	# The Ubuntu root this layout comes from has no such merge, so the root gets
	# a real directory; both paths stay on PATH.
	if [ -L "$root/usr/local/sbin" ]; then
		rm -f "$root/usr/local/sbin"
		mkdir -m 0755 "$root/usr/local/sbin"
		chown 0:0 "$root/usr/local/sbin"
	fi

	overlay=$project_root/device/gnome-overlay
	[ -d "$overlay" ] || die "device overlay missing: $overlay"
	( cd "$overlay" && find . -print ) |
		while IFS= read -r entry; do
			[ -d "$overlay/$entry" ] && continue
			mkdir -p "$root/$(dirname "$entry")"
			cp -a "$overlay/$entry" "$root/$entry"
		done

	# The overlay's /etc/dconf/profile/gdm is shaped for Ubuntu, where the
	# packaged profile stacks only user-db:user and the shipped file-db, so a
	# local override is the only slot for /etc/dconf/db/gdm.d.  Fedora's packaged
	# profile already stacks system-db:gdm -- that is what carries the power-key
	# delegation -- plus local/site/distro, and points file-db at
	# /usr/share/gdm/greeter-dconf-defaults.  The overlay's file-db names
	# /var/lib/gdm3/greeter-dconf-defaults, which does not exist on this root, so
	# keeping the override would cost the greeter every value in
	# greeter-dconf-defaults -- session-name=gnome-login among them.
	# gnome-shell only draws the login screen for that session name; without it
	# the greeter comes up as an unlocked plain desktop with no lock-down keys,
	# which reads as "a terminal opened but nothing unlocks".  Let the
	# distribution's own profile stand and assert the two lines this depends on.
	rm -f "$root/etc/dconf/profile/gdm"
	if [ -e "$root/etc/dconf/profile/gdm" ]; then
		die 'a /etc/dconf/profile/gdm override survived the Fedora rewrite'
	fi
	grep -qx 'system-db:gdm' "$root/usr/share/dconf/profile/gdm" ||
		die 'the distribution dconf profile no longer carries system-db:gdm'
	grep -qx 'file-db:/usr/share/gdm/greeter-dconf-defaults' \
		"$root/usr/share/dconf/profile/gdm" ||
		die 'the distribution dconf profile no longer points at its greeter defaults'

	# The overlay ships the storage guard against the legacy GNOME marker.  This
	# root carries /etc/liuqin-native-root instead, and the guard hangs off
	# basic.target.requires: a guard looking for the wrong marker fails the boot
	# into a rescue shell rather than a desktop.  Same rewrite, and the same
	# drift checks, as the device-layer package builder.
	guard=$root/usr/local/sbin/liuqin-gnome-storage-guard
	grep -qx 'marker=/etc/liuqin-gnome-root' "$guard" ||
		die 'storage guard drifted from the reviewed legacy marker'
	grep -qx 'marker_sha=bd86a359f5b6bf05f09abf544967489e924c251ab7c07684df62b0dbda4c3fca' "$guard" ||
		die 'storage guard drifted from the reviewed legacy marker hash'
	sed -i \
		-e 's|^marker=/etc/liuqin-gnome-root$|marker=/etc/liuqin-native-root|' \
		-e 's|^marker_sha=bd86a359f5b6bf05f09abf544967489e924c251ab7c07684df62b0dbda4c3fca$|marker_sha=4fdae4f7a27af8b0d4a2bbc168c7f01c3c5c6b5e245fcc521389d662f8212c5b|' \
		"$guard"
	grep -qx 'marker=/etc/liuqin-native-root' "$guard" ||
		die 'storage guard native marker rewrite did not land'

	# Speaker topology and the compiled device helpers.
	install -D -m 0644 "$audio_topology" "$root/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin"

	# The sensor stack: hexagonrpcd, ssccli, the patched iio-sensor-proxy and the
	# registry import.
	[ -f "$sensor_stack_tar" ] || die "sensor stack archive missing: $sensor_stack_tar"
	tar -xf "$sensor_stack_tar" -C "$root" --numeric-owner --same-owner || die 'sensor stack extraction failed'
	# The stack ships the SSC-enabled proxy under /usr/local with an ExecStart
	# override, which is how a distribution that owns the original file is left
	# alone.  This root replaces the file at the distribution's own path instead
	# -- stage 1 admits the root on /usr/libexec/iio-sensor-proxy -- so the
	# binary moves and the drop-in loses exactly the two override lines that
	# pointed at the copy.  Fedora has no dpkg-divert: the RPM records the file
	# as modified, and reinstalling that package is the way back.
	sensor_proxy=$root/usr/local/libexec/liuqin-iio-sensor-proxy
	[ -x "$sensor_proxy" ] || die 'the sensor stack did not provide the SSC proxy'
	install -D -m 0755 "$sensor_proxy" "$root/usr/libexec/iio-sensor-proxy"
	rm -f "$sensor_proxy"
	dropin=$root/etc/systemd/system/iio-sensor-proxy.service.d/90-liuqin-ssc.conf
	[ -f "$dropin" ] || die 'the sensor stack carries no SSC drop-in'
	grep -qx 'ExecStart=/usr/local/libexec/liuqin-iio-sensor-proxy' "$dropin" ||
		die 'the SSC drop-in drifted from the reviewed ExecStart override'
	grep -vx -e 'ExecStart=' -e 'ExecStart=/usr/local/libexec/liuqin-iio-sensor-proxy' \
		"$dropin" >"$out_dir/.dropin.tmp"
	mv "$out_dir/.dropin.tmp" "$dropin"
	chmod 0644 "$dropin"
	[ -x "$root/usr/libexec/iio-sensor-proxy" ] ||
		die 'the sensor stack did not provide /usr/libexec/iio-sensor-proxy'

	# The power panel's schema is compiled here rather than shipped prebuilt: the
	# compiled form is an artefact of the glib that wrote it, so the root gets
	# the one its own glib will read.
	[ -f "$root/usr/share/liuqin/power/io.github.liuqin.power.gschema.xml" ] ||
		die 'the power panel schema is missing from the device overlay'
	command -v glib-compile-schemas >/dev/null || die 'glib-compile-schemas is required'
	glib-compile-schemas --strict "$root/usr/share/liuqin/power"
	chmod 0644 "$root/usr/share/liuqin/power/gschemas.compiled"

	# The patched power panel replaces Fedora's binary.  Fedora has no
	# dpkg-divert, so the RPM the file came from is the documented way back; the
	# panel is not an admission requirement, and a root without it still boots.
	if [ -n "$power_settings_binary" ]; then
		[ -f "$power_settings_binary" ] || die "settings binary missing: $power_settings_binary"
		[ -e "$root/usr/bin/gnome-control-center" ] ||
			die 'gnome-control-center is missing from the Fedora tree'
		install -m 0755 "$power_settings_binary" "$root/usr/bin/gnome-control-center"
	else
		say 'WARNING: POWER_SETTINGS_BINARY is unset; the power panel is not installed'
	fi

	# /usr/local/bin/busybox is what liuqin-shell and the guard scripts run on.
	# build-liuqin-fedora-rootfs.sh already installed it from the Fedora package
	# and the contract pins its hash from there, so only its presence is checked.
	[ -x "$root/usr/local/bin/busybox" ] ||
		die '/usr/local/bin/busybox is missing; run the configure stage of the rootfs builder'

	# The power key daemon comes from the project's own C source, compiled with
	# the deterministic flags the device-layer package builder uses so the
	# contract's pin describes a build anyone can repeat.
	source_file=$project_root/device/power-key/liuqin-power-keyd.c
	[ -f "$source_file" ] || die "power key source missing: $source_file"
	command -v "$power_key_cc" >/dev/null || die "cross compiler is unavailable: $power_key_cc"
	mkdir -p "$root/usr/local/libexec"
	# shellcheck disable=SC2086 # the two flags are empty when unavailable
	LC_ALL=C SOURCE_DATE_EPOCH=0 "$power_key_cc" \
		$cross_sysroot_flag $atomic_flag \
		-std=c11 -O2 -pipe \
		-Wall -Wextra -Werror -Wformat=2 -Wshadow -Wstrict-prototypes \
		-Wmissing-prototypes -fno-common -fstack-protector-strong \
		-D_FORTIFY_SOURCE=3 \
		-ffile-prefix-map="$project_root"=. \
		-ffile-prefix-map="$root"=/build/liuqin-device-support \
		-Wl,-z,relro,-z,now -Wl,--build-id=sha1 \
		"$source_file" -o "$root/usr/local/libexec/liuqin-power-keyd"
	chmod 0755 "$root/usr/local/libexec/liuqin-power-keyd"
	command -v readelf >/dev/null || die 'readelf is required to verify generated executables'
	[ "$(LC_ALL=C readelf -h "$root/usr/local/libexec/liuqin-power-keyd" |
		sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')" = AArch64 ] ||
		die 'power-key daemon is not an AArch64 executable'

	# The device layer is copied from build-host trees that belong to the
	# developer; nothing in the installed root may carry that ownership.
	chown -R 0:0 "$root/usr" "$root/etc"
	say 'device PASS'
}

# Symlinks and modes Stage 1 asserts.  Failing here costs seconds; failing on the
# tablet costs a boot loop and a rescue shell.
stage_assemble() {
	[ -x "$root/usr/lib/systemd/systemd" ] || die "run the copy stage first: $root"
	say 'assembling the first-boot topology'

	link_unit() { # link_unit <target.wants> <unit>
		mkdir -p "$root/etc/systemd/system/$1"
		ln -sfn "../$2" "$root/etc/systemd/system/$1/$2"
	}
	link_unit basic.target.requires liuqin-gnome-storage-guard.service
	link_unit multi-user.target.wants liuqin-gnome-usb-rescue.service
	link_unit multi-user.target.wants liuqin-power-keyd.service
	link_unit graphical.target.wants liuqin-backlight-default.service

	# Obsolete activation paths: the Bluetooth helper is a dependency of the
	# preconfigure unit now, and a leftover link would start it too early.
	for obsolete in bluetooth.service.wants/liuqin-bt-public-addr.service \
		bluetooth.service.requires/liuqin-bt-public-addr.service; do
		rm -f "$root/etc/systemd/system/$obsolete"
		[ ! -e "$root/etc/systemd/system/$obsolete" ] ||
			die "obsolete Bluetooth activation remains: $obsolete"
	done

	# The snap admission unit stays in the tree -- the native contract pins the
	# unit and its helper -- but nothing may require it: stage 1 rejects a root
	# whose basic.target is still gated on that text check.
	rm -f "$root/etc/systemd/system/basic.target.requires/liuqin-snap-root-admission.service"
	[ ! -e "$root/etc/systemd/system/basic.target.requires/liuqin-snap-root-admission.service" ] ||
		die 'snap admission still gates basic.target'

	# Boundaries: no per-device data may be baked into a distributable tree.
	for forbidden in "$root/var/lib/liuqin-private" "$root/etc/liuqin-rescue-enabled"; do
		[ ! -e "$forbidden" ] || die "per-device data present in the public tree: $forbidden"
	done
	if find "$root/usr/lib/firmware" -name '*-calr.bin' -print -quit 2>/dev/null | grep -q .; then
		die 'Cirrus calibration is present; it is per-device and must not ship'
	fi
	say 'assemble PASS'
}

stage_preflight() {
	[ -d "$root/etc" ] || die "run the copy stage first: $root"
	say 'mirroring the stage-1 admission gates'
	failed=0
	check_mode() { # check_mode <mode> <path...>
		mode=$1
		shift
		for path in "$@"; do
			actual=$(stat -c '%a' "$root$path" 2>/dev/null || true)
			if [ "$actual" != "$mode" ]; then
				printf '  %s: mode %s, expected %s\n' "$path" "${actual:-missing}" "$mode" >&2
				failed=1
			fi
		done
	}
	# Stage 1 accepts either distribution's display manager.
	if [ "$(stat -c '%a' "$root/usr/sbin/gdm" 2>/dev/null || true)" != 755 ] &&
		[ "$(stat -c '%a' "$root/usr/sbin/gdm3" 2>/dev/null || true)" != 755 ]; then
		printf '  no display manager executable (gdm or gdm3)\n' >&2
		failed=1
	fi
	check_mode 755 \
		/usr/lib/systemd/systemd /usr/bin/gnome-shell \
		/usr/bin/hexagonrpcd \
		/usr/local/bin/busybox /usr/local/bin/liuqin-shell \
		/usr/libexec/iio-sensor-proxy \
		/usr/local/sbin/liuqin-gnome-storage-guard \
		/usr/local/sbin/liuqin-gnome-usb-rescue \
		/usr/local/libexec/liuqin-power-keyd \
		/usr/local/libexec/liuqin-power-key-action \
		/usr/local/sbin/liuqin-bt-public-addr \
		/usr/local/sbin/liuqin-wlan-mac \
		/usr/libexec/liuqin-ssc-sample-gate
	check_mode 644 \
		/etc/dconf/db/local.d/locks/00-liuqin-power \
		/etc/systemd/system/liuqin-gnome-storage-guard.service \
		/etc/systemd/system/liuqin-gnome-usb-rescue.service \
		/etc/systemd/system/liuqin-power-keyd.service \
		/etc/systemd/system/liuqin-backlight-default.service \
		/etc/systemd/system/bluetooth.service.d/20-liuqin-public-address.conf \
		/etc/systemd/system/liuqin-bt-preconfigure.service \
		/etc/systemd/system/liuqin-hexagonrpcd-sdsp.service \
		/etc/systemd/system/liuqin-ssc-sample-gate.service \
		/etc/systemd/system/liuqin-sensor-stack.target \
		/etc/systemd/system/liuqin-wlan-mac.service \
		/etc/systemd/system/NetworkManager.service.d/20-liuqin-wlan-mac.conf \
		/etc/udev/rules.d/80-liuqin-fastrpc.rules \
		/usr/lib/firmware/qcom/sm8450/Xiaomi-Pad-6-Pro-tplg.bin \
		/usr/share/liuqin/kernel.release \
		/usr/share/liuqin/kernel-modules.manifest \
		/usr/share/liuqin/power/gschemas.compiled \
		/usr/share/qcom/sm8450/Xiaomi/liuqin/sensors/sns_reg_version

	# The greeter only reaches its login screen through the distribution's own
	# dconf profile: an override in /etc shadows it, and one pointing file-db at
	# the Ubuntu path leaves gnome-shell without session-name=gnome-login -- it
	# then renders a plain unlocked desktop where the login screen belongs.  The
	# device stage writes and asserts both of these; this is the independent
	# re-check that a re-run of the stage cannot quietly undo.
	if [ -e "$root/etc/dconf/profile/gdm" ]; then
		printf '  an /etc/dconf/profile/gdm override shadows the distribution profile\n' >&2
		failed=1
	fi
	grep -qx 'file-db:/usr/share/gdm/greeter-dconf-defaults' \
		"$root/usr/share/dconf/profile/gdm" 2>/dev/null || {
		printf '  the distribution dconf profile does not point at its greeter defaults\n' >&2
		failed=1
	}

	# The mode bits RPM installs that a copy can drop silently.  A tree missing
	# them boots and looks healthy right up to the moment someone types sudo,
	# and the tool then reports an account problem ("effective uid is not 0")
	# rather than a tree problem.  The copy stage replays them; this is the
	# assertion that the replay worked.
	check_mode 4111 /usr/bin/sudo
	check_mode 4755 \
		/usr/bin/passwd /usr/bin/su /usr/bin/pkexec /usr/bin/mount /usr/bin/unix_chkpwd \
		/usr/lib/polkit-1/polkit-agent-helper-1
	if [ -f "$out_dir/privileged.map" ]; then
		tree_privileged=$(find "$root" -perm /6000 2>/dev/null | wc -l)
		[ "$tree_privileged" -ge "$(wc -l <"$out_dir/privileged.map")" ] || {
			printf '  the tree carries %s privileged files, the source had %s\n' \
				"$tree_privileged" "$(wc -l <"$out_dir/privileged.map")" >&2
			failed=1
		}
	fi

	# The helpers have to sit at the path the units call and the contract pins.
	# On a usrmerged root a symlink here sends the copy into bin, which the
	# mode checks above would still accept -- and the contract generator would
	# reject much later, after the whole tree is assembled.
	if [ -L "$root/usr/local/sbin" ]; then
		printf '  /usr/local/sbin is a symlink; the device helpers are not at their pinned path\n' >&2
		failed=1
	fi

	for link in \
		"basic.target.requires/liuqin-gnome-storage-guard.service ../liuqin-gnome-storage-guard.service" \
		"multi-user.target.wants/liuqin-gnome-usb-rescue.service ../liuqin-gnome-usb-rescue.service" \
		"multi-user.target.wants/liuqin-power-keyd.service ../liuqin-power-keyd.service" \
		"graphical.target.wants/liuqin-backlight-default.service ../liuqin-backlight-default.service"; do
		set -- $link
		actual=$(readlink "$root/etc/systemd/system/$1" 2>/dev/null || true)
		[ "$actual" = "$2" ] || {
			printf '  %s -> %s, expected %s\n' "$1" "${actual:-nothing}" "$2" >&2
			failed=1
		}
	done
	[ "$(readlink "$root/usr/sbin/init" 2>/dev/null || true)" = ../lib/systemd/systemd ] || {
		printf '  /usr/sbin/init is not the systemd symlink\n' >&2
		failed=1
	}
	[ "$(readlink "$root/etc/systemd/system/default.target" 2>/dev/null || true)" = /usr/lib/systemd/system/graphical.target ] || {
		printf '  default.target is not graphical.target\n' >&2
		failed=1
	}
	grep -qx 'Requires=liuqin-bt-preconfigure.service' \
		"$root/etc/systemd/system/bluetooth.service.d/20-liuqin-public-address.conf" 2>/dev/null || {
		printf '  Bluetooth drop-in does not require the preconfigure unit\n' >&2
		failed=1
	}
	# The guard runs before basic.target completes; if it looks for a marker this
	# root does not carry, the boot stops there rather than reaching the desktop.
	guard=$root/usr/local/sbin/liuqin-gnome-storage-guard
	grep -qx 'marker=/etc/liuqin-native-root' "$guard" 2>/dev/null || {
		printf '  the storage guard still checks the legacy marker\n' >&2
		failed=1
	}
	# A release record without a module tree, or the other way round, is a root
	# whose kernel and modules are not a pair.
	kernel_release=$(cat "$root/usr/share/liuqin/kernel.release" 2>/dev/null || true)
	case $kernel_release in
	'' | *[!A-Za-z0-9._+-]*)
		printf '  the kernel release record is missing or malformed\n' >&2
		failed=1
		;;
	*)
		[ -f "$root/usr/lib/modules/$kernel_release/modules.dep" ] || {
			printf '  no module tree for %s\n' "$kernel_release" >&2
			failed=1
		}
		;;
	esac
	chroot "$root" /usr/lib/systemd/systemd --version >/dev/null 2>&1 || {
		printf '  systemd will not execute under chroot\n' >&2
		failed=1
	}
	[ "$failed" = 0 ] || die 'preflight failed; the tablet would reject this root'
	say 'preflight PASS'
}

stage_manifest() {
	[ -d "$root" ] || die "run the copy stage first: $root"
	say 'writing the tree manifest and hash list'
	cd "$root"
	find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null |
		sed 's|  \./|  /|' >"$out_dir/native-root.hashes"
	entries=$(wc -l <"$out_dir/native-root.hashes")
	# Floor only: catches an empty or half-copied tree.  See the same note in
	# build-liuqin-fedora-rootfs.sh about the expected entry count.
	[ "$entries" -ge 20000 ] || die "only $entries hashed files; is this a real root?"
	chroot "$root" rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null |
		LC_ALL=C sort >"$out_dir/fedora-native-root.packages" || true
	{
		printf 'profile=native\n'
		printf 'distribution=fedora\n'
		printf 'entries=%s\n' "$entries"
		printf 'hashes_sha256=%s\n' "$(sha256sum "$out_dir/native-root.hashes" | cut -d' ' -f1)"
		printf 'packages_sha256=%s\n' "$(sha256sum "$out_dir/fedora-native-root.packages" | cut -d' ' -f1)"
	} >"$out_dir/fedora-native-root.identity"
	say "manifest PASS ($entries files)"
}

stage_pack() {
	[ -f "$out_dir/native-root.hashes" ] || die 'run the manifest stage first'
	[ ! -f "$out_dir/rootfs.tar.gz" ] || die "refusing to overwrite $out_dir/rootfs.tar.gz"
	say 'packing rootfs.tar.gz'
	sh "$project_root/tools/lib/rootfs-archive.sh" pack "$root" "$out_dir/rootfs.tar.gz"
	say 'pack PASS'
}

case ${1:-all} in
copy) stage_copy ;;
device) stage_device ;;
assemble) stage_assemble ;;
preflight) stage_preflight ;;
manifest) stage_manifest ;;
pack) stage_pack ;;
all)
	stage_copy
	stage_device
	stage_assemble
	stage_preflight
	stage_manifest
	;;
*)
	printf 'usage: %s [copy|device|assemble|preflight|manifest|pack|all]\n' "$0" >&2
	exit 2
	;;
esac
