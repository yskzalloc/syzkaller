#!/usr/bin/env bash
#
# syz.sh - drive syzkaller fuzzing of the Debian-sid KASAN/KCOV kernel under
#          three VM backends and compare them.
#
#   syz.sh prepare [--reset] [--branch <branch>]
#                             build the Debian KASAN/KCOV kernel and install it
#                             into the cloud image (via debsb); --reset rebuilds
#                             from a clean ~/.debsb; --branch selects a salsa
#                             kernel-team/linux branch (default debian/latest)
#   syz.sh [-sandbox none|setuid|namespace] qemu        <time>
#                             fuzz for <time> using the qemu backend
#   syz.sh [-sandbox none|setuid|namespace] crosvm      <time>
#                             fuzz for <time> using the crosvm backend
#   syz.sh [-sandbox none|setuid|namespace] firecracker <time>
#                             fuzz for <time> using the firecracker backend
#   syz.sh [-sandbox none|setuid|namespace] compare     <time>
#                             run qemu, crosvm and firecracker each for <time>,
#                             with identical kernel/image/VM shape, and emit a
#                             side-by-side report
#
# <time> accepts 4h, 30m, 90s, 2h30m or a plain number of seconds.
#
# The fuzzing commands run 'prepare' automatically when the kernel or image is
# missing, so 'syz.sh crosvm 4h' works from a clean ~/.debsb.
#
#   - kernel/image via debsb  (~/.debsb)          <- built by 'prepare'
#   - crosvm       via cargo   (~/crosvm/target/release/crosvm)
#   - firecracker  binary      (~/firecracker/firecracker)
#   - syzkaller    via make    (~/syzkaller/bin)
#
# VM shape can be overridden with the SYZ_COUNT / SYZ_PROCS / SYZ_CPU / SYZ_MEM
# environment variables. All backends always use the same shape.
set -euo pipefail

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
SYZ_DIR=/home/debian-sid/syzkaller
DEBSB_DIR=/home/debian-sid/.debsb

HOST_ARCH=$(uname -m)
if [[ $HOST_ARCH == "aarch64" ]]; then
	TARGET_ARCH="linux/arm64"
	KERNEL_BUILD="build_arm64_none_arm64"
	KERNEL_IMAGE_REL="arch/arm64/boot/Image"
	BASE_QCOW_NAME="debian-sid-generic-arm64-daily.qcow2"
	QEMU_BIN=${QEMU_BIN:-/home/debian-sid/qemu/build/qemu-system-aarch64}
	FIRECRACKER_BIN=${FIRECRACKER_BIN:-/home/debian-sid/firecracker/build/cargo_target/release/firecracker}
else
	TARGET_ARCH="linux/amd64"
	KERNEL_BUILD="build_amd64_none_amd64"
	KERNEL_IMAGE_REL="arch/x86/boot/bzImage"
	BASE_QCOW_NAME="debian-sid-generic-amd64-daily.qcow2"
	QEMU_BIN=${QEMU_BIN:-qemu-system-x86_64}
	FIRECRACKER_BIN=${FIRECRACKER_BIN:-/home/debian-sid/firecracker/firecracker}
fi

KERNEL_OBJ=$DEBSB_DIR/linux/debian/build/$KERNEL_BUILD
BZIMAGE=$KERNEL_OBJ/$KERNEL_IMAGE_REL
SSHKEY=$DEBSB_DIR/id_ed25519
BASE_QCOW=$DEBSB_DIR/$BASE_QCOW_NAME
CROSVM_BIN=/home/debian-sid/crosvm/target/release/crosvm

# Used by 'prepare' only.
DEBSB_SRC=/home/debian-sid/debsb          # local checkout, not on PyPI
VENV=${SYZ_VENV:-/home/debian-sid/venv-debsb}
GCC15_SHIM=/home/debian-sid/.local/gcc15shim
LOCALBIN=/home/debian-sid/.local/localbin # provides zstd (CONFIG_KERNEL_ZSTD)

CACHE_DIR=${SYZ_CACHE:-/home/debian-sid/.cache/syz-crosvm}
IMAGE=$CACHE_DIR/image.qcow2          # uncompressed, shared by both backends
RUNS_DIR=$CACHE_DIR/runs

# VM shape (identical for both backends). 2 VMs x 2 vCPU x 2GB, 4 procs each
# comfortably fills an 8-core host while leaving headroom for the manager.
SYZ_COUNT=${SYZ_COUNT:-2}
SYZ_PROCS=${SYZ_PROCS:-4}
SYZ_CPU=${SYZ_CPU:-2}
SYZ_MEM=${SYZ_MEM:-2048}

# Kernel config for fuzzing. The first block is what makes the image bootable
# with no initrd under both backends (crosvm always loads the kernel directly,
# so anything needed to reach the root filesystem has to be built in, not
# modular); the rest is coverage, sanitizers and fault injection.
KCONFIG_ITEMS=(
	# --- boot without an initrd ---
	CONFIG_VIRTIO=y CONFIG_VIRTIO_PCI=y CONFIG_VIRTIO_BLK=y
	CONFIG_VIRTIO_NET=y CONFIG_VIRTIO_CONSOLE=y
	CONFIG_VIRTIO_MMIO=y CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
	CONFIG_SERIAL_AMBA_PL011=y CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
	CONFIG_ARM_GIC_V3=y
	CONFIG_EXT4_FS=y CONFIG_IP_PNP=y CONFIG_IP_PNP_DHCP=y
	# --- coverage for syzkaller ---
	CONFIG_KCOV=y CONFIG_KCOV_INSTRUMENT_ALL=y CONFIG_KCOV_ENABLE_COMPARISONS=y
	CONFIG_DEBUG_FS=y CONFIG_DEBUG_KERNEL=y
	# --- KASAN memory bug detection ---
	CONFIG_KASAN=y CONFIG_KASAN_INLINE=y
	# --- symbolization ---
	CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
	# --- fault injection ---
	CONFIG_FAULT_INJECTION=y CONFIG_FAULT_INJECTION_DEBUG_FS=y
	CONFIG_FAILSLAB=y CONFIG_FAIL_MAKE_REQUEST=y
	CONFIG_FAIL_IO_TIMEOUT=y CONFIG_FAIL_FUTEX=y
	# --- namespaces for the syzkaller sandbox ---
	CONFIG_USER_NS=y CONFIG_NET_NS=y
	# --- extra fuzzing surface. Debian ships these modular and nothing
	#     autoloads them before syzkaller probes for the feature. Asking for
	#     =y does not always get it: kconfig silently demotes a symbol whose
	#     dependencies are modular (RFKILL=m pins CFG80211/MAC80211, MAC802154=m
	#     pins IEEE802154_HWSIM, PSAMPLE=m pins NETDEVSIM). Those land as
	#     modules and prep_image autoloads them via GUEST_MODULES instead.
	#     USB is different: USB_DUMMY_HCD needs "USB=y || (USB=m && USB_GADGET=m)",
	#     so without CONFIG_USB=y the symbol is not even offered and raw-gadget
	#     has no UDC to bind to.
	CONFIG_USB=y CONFIG_USB_GADGET=y CONFIG_USB_DUMMY_HCD=y CONFIG_USB_RAW_GADGET=y
	CONFIG_MAC80211_HWSIM=y CONFIG_MAC80211=y CONFIG_CFG80211=y
	CONFIG_IEEE802154=y CONFIG_IEEE802154_SOCKET=y CONFIG_IEEE802154_HWSIM=y
	CONFIG_NET_DEVLINK=y CONFIG_NETDEVSIM=y
	# --- bug detection beyond KASAN. These cost throughput but find classes
	#     KASAN cannot: lock inversion/deadlock, sleeping in atomic context,
	#     object lifetime and workqueue stalls.
	CONFIG_PROVE_LOCKING=y CONFIG_DEBUG_ATOMIC_SLEEP=y
	CONFIG_DEBUG_VM=y CONFIG_DEBUG_OBJECTS=y CONFIG_DEBUG_OBJECTS_FREE=y
	CONFIG_WQ_WATCHDOG=y CONFIG_FAULT_INJECTION_USERCOPY=y
	# Lockdep's chain tables are statically sized from this (MAX_LOCKDEP_CHAINS
	# = 1 << bits, and MAX_LOCKDEP_CHAIN_HLOCKS derives from it). The default of
	# 16 is exhausted by fuzzing load: the 8h run of 2026-08-15 hit
	# "BUG: MAX_LOCKDEP_CHAINS too low!" 23 times plus 2 HLOCKS variants, each
	# one killing a VM and disabling lockdep on it. Valid range is 10..21.
	CONFIG_LOCKDEP_CHAINS_BITS=18
	# syzkaller's Leak feature needs kmemleak; without it the probe reports
	# "failed to write(kmemleak, scan=off)".
	CONFIG_DEBUG_KMEMLEAK=y
	# The Debian kernel is built with CONFIG_DEBUG_INFO_BTF_MODULES=y, which
	# emits per-module BTF that the kernel validates against vmlinux BTF at
	# insmod time. The Debian build produces a base/module BTF that does not
	# match, so every modular driver is rejected with -EINVAL:
	#   "failed to validate module [tun] BTF: -22"
	#   modprobe: could not insert 'tun'/'mac80211_hwsim'/'netdevsim': Invalid argument
	# That silently strips the entire modular fuzzing surface (tun -> no
	# NetInjection, and none of the GUEST_MODULES load), which showed up as a
	# firecracker run reaching only ~31k coverage vs ~45k on an older kernel.
	# MODULE_ALLOW_BTF_MISMATCH makes the kernel log a warning and load the
	# module anyway instead of failing (kernel/bpf/btf.c). It affects every
	# backend equally; without it =m drivers are useless.
	CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
	# An oops must end the VM so syzkaller attributes it to the program that
	# triggered it rather than letting a wounded guest keep fuzzing.
	CONFIG_PANIC_ON_OOPS=y
)

# Options that must end up =y in the generated .config, or the VMs will not
# boot / will produce no coverage. Checked after every build.
# Options that must be built in: the guest boots with no initrd, and coverage
# and sanitizer support cannot be loaded after the fact.
KCONFIG_REQUIRED=(
	CONFIG_KCOV CONFIG_KCOV_INSTRUMENT_ALL CONFIG_KASAN
	CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_EXT4_FS CONFIG_IP_PNP
	CONFIG_USB CONFIG_USB_RAW_GADGET CONFIG_USB_DUMMY_HCD
	CONFIG_DEBUG_KMEMLEAK
	CONFIG_MODULE_ALLOW_BTF_MISMATCH
	CONFIG_PROVE_LOCKING CONFIG_PANIC_ON_OOPS
)

if [[ $HOST_ARCH == "aarch64" ]]; then
	KCONFIG_REQUIRED+=(
		CONFIG_SERIAL_AMBA_PL011 CONFIG_SERIAL_AMBA_PL011_CONSOLE
		CONFIG_VIRTIO_MMIO
	)
fi

# Options that must have an exact non-boolean value, checked verbatim.
KCONFIG_REQUIRED_VAL=(
	CONFIG_LOCKDEP_CHAINS_BITS=18
)

# Options that may be modules. Asking for =y does not make them =y: kconfig
# silently demotes a symbol whose dependencies are modular, and Debian ships
# RFKILL=m (so CFG80211/MAC80211 cannot be =y), MAC802154=m and PSAMPLE=m.
# syzkaller only needs the corresponding device present, so =m plus an entry
# in the guest's modules-load.d (see prep_image) is equivalent for fuzzing.
KCONFIG_REQUIRED_ANY=(
	CONFIG_MAC80211_HWSIM CONFIG_IEEE802154_HWSIM CONFIG_NETDEVSIM
)

# Modules the guest must load at boot for syzkaller to detect the matching
# feature. Names are the .ko names, not the CONFIG_ symbols.
GUEST_MODULES=(mac80211_hwsim mac802154_hwsim netdevsim)

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
die() { echo "syz.sh: error: $*" >&2; exit 1; }

usage() {
	sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^#\{0,1\} \{0,1\}//'
	exit 1
}

# to_seconds 4h -> 14400 ; accepts h/m/s components or a bare integer.
to_seconds() {
	local s=$1 total=0 rest=$1 num unit
	if [[ $s =~ ^[0-9]+$ ]]; then echo "$s"; return; fi
	while [[ $rest =~ ^([0-9]+)([hms])(.*)$ ]]; do
		num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
		case $unit in
			h) total=$((total + num * 3600)) ;;
			m) total=$((total + num * 60)) ;;
			s) total=$((total + num)) ;;
		esac
	done
	[[ -z $rest ]] || die "invalid duration: $1 (use forms like 4h, 30m, 90s, 2h30m)"
	echo "$total"
}

# Things 'prepare' does not build: they have their own build systems.
# Only the backends actually requested are checked, so 'qemu <t>' does not need
# crosvm or firecracker installed, and vice versa. Called as
#   check_tools qemu crosvm firecracker
# with the list of backends the command is about to run.
check_tools() {
	[[ -x $SYZ_DIR/bin/syz-manager ]] || die "syz-manager not built ($SYZ_DIR/bin). Run 'make' in $SYZ_DIR."
	local backend
	for backend in "$@"; do
		case $backend in
			qemu)
				if [[ $HOST_ARCH == "aarch64" ]]; then
					command -v "$QEMU_BIN" >/dev/null || command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 not found ($QEMU_BIN)"
				else
					command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not in PATH"
				fi
				;;
			crosvm)
				[[ -x $CROSVM_BIN ]] || die "crosvm binary not found: $CROSVM_BIN (cargo build --release in ~/crosvm)" ;;
			firecracker)
				[[ -x $FIRECRACKER_BIN ]] || die "firecracker binary not found: $FIRECRACKER_BIN" ;;
		esac
	done
}

# Everything 'prepare' produces.
have_kernel_image() {
	[[ -f $BZIMAGE && -d $KERNEL_OBJ && -f $SSHKEY && -f $BASE_QCOW ]]
}

# The Debian kernel packaging pins C_COMPILER=gcc-15. If only a newer gcc is
# installed, point the gcc-15 names at it: no GCC plugins are enabled, so the
# version does not have to match exactly.
ensure_toolchain() {
	if [[ $HOST_ARCH == "aarch64" ]]; then
		if ! command -v aarch64-linux-gnu-gcc-15 >/dev/null && ! command -v gcc-15 >/dev/null && [[ ! -x $GCC15_SHIM/gcc-15 ]]; then
			local newer
			newer=$(ls /usr/bin/aarch64-linux-gnu-gcc-1[6-9] /usr/bin/gcc-1[6-9] 2>/dev/null | sort -V | tail -1) || true
			[[ -n $newer ]] || die "no gcc-15 (or newer) found for the Debian kernel build"
			echo ">> creating gcc-15 shim in $GCC15_SHIM -> $(basename "$newer")"
			mkdir -p "$GCC15_SHIM"
			local suffix=${newer##*gcc-}
			local n
			for n in gcc cpp g++; do
				[[ -x /usr/bin/$n-$suffix ]] && ln -sf "/usr/bin/$n-$suffix" "$GCC15_SHIM/$n-15"
				[[ -x /usr/bin/aarch64-linux-gnu-$n-$suffix ]] &&
					ln -sf "/usr/bin/aarch64-linux-gnu-$n-$suffix" "$GCC15_SHIM/aarch64-linux-gnu-$n-15"
			done
		fi
	else
		if ! command -v x86_64-linux-gnu-gcc-15 >/dev/null && [[ ! -x $GCC15_SHIM/gcc-15 ]]; then
			local newer
			newer=$(ls /usr/bin/x86_64-linux-gnu-gcc-1[6-9] 2>/dev/null | sort -V | tail -1) || true
			[[ -n $newer ]] || die "no gcc-15 (or newer) found for the Debian kernel build"
			echo ">> creating gcc-15 shim in $GCC15_SHIM -> $(basename "$newer")"
			mkdir -p "$GCC15_SHIM"
			local suffix=${newer##*gcc-}
			local n
			for n in gcc cpp g++; do
				[[ -x /usr/bin/$n-$suffix ]] && ln -sf "/usr/bin/$n-$suffix" "$GCC15_SHIM/$n-15"
				[[ -x /usr/bin/x86_64-linux-gnu-$n-$suffix ]] &&
					ln -sf "/usr/bin/x86_64-linux-gnu-$n-$suffix" "$GCC15_SHIM/x86_64-linux-gnu-$n-15"
			done
		fi
	fi
	# CONFIG_KERNEL_ZSTD compresses the boot image with the zstd binary.
	command -v zstd >/dev/null ||
		die "zstd not found in PATH (needed to compress the boot image); install it or drop it in $LOCALBIN"
}

# Verify the options the run actually depends on really made it into .config.
# debsb writes them to debian/config.local, but a typo or a dropped dependency
# would otherwise only show up as a VM that never boots or reports no coverage.
# Assert the out-of-tree kernel patches really made it into the tree that was
# compiled. This is not paranoia: debian/patches/series is git-tracked and
# debsb runs "git checkout FETCH_HEAD" when it reuses an existing clone, so a
# local series edit can be reverted and the build would then quietly produce an
# unpatched kernel that still looks like a success.
verify_patches() {
	if [[ $HOST_ARCH != "x86_64" ]]; then
		echo ">> skipping x86-specific quilt patch verification on $HOST_ARCH"
		return 0
	fi
	local linux=$DEBSB_DIR/linux
	local applied=$linux/.pc/applied-patches
	# The out-of-tree KASAN fixes are applied by quilt during the Debian package
	# build (debian/rules setup), which records them in .pc/applied-patches and
	# leaves them applied in the working tree. debsb resets the git tree to
	# FETCH_HEAD when it reuses a clone, so grepping the source for a specific
	# patched line is brittle: a branch bump (e.g. debian/latest 7.2~rc7 ->
	# 7.2.2) rebases the patch into a different form and the old signature line
	# disappears even though the fix is present. Check quilt's applied state
	# instead, which tracks the patch by name across rebases.
	local patches=(
		bugfix/x86/x86-cacheinfo-bounds-check-sibling-leaf-indexing.patch
		bugfix/x86/x86-cacheinfo-match-sibling-leaves-by-level-and-type.patch
	)
	[[ -f $applied ]] || die "no quilt applied-patches state at $applied; the Debian build did not run 'debian/rules setup'"
	local p missing=()
	for p in "${patches[@]}"; do
		grep -qxF "$p" "$applied" || missing+=("$p")
	done
	if (( ${#missing[@]} )); then
		die "x86/cacheinfo KASAN patches NOT applied by quilt: ${missing[*]} (see $applied)"
	fi
	# Belt and braces: the applied working-tree source must have the bounds-safe
	# sibling helper the patches introduce (matches siblings by iterating only up
	# to num_leaves), regardless of the exact refactor. The old unbounded form
	# indexed a sibling array with this CPU's leaf index and had no such helper.
	local src=$linux/arch/x86/kernel/cpu/cacheinfo.c
	[[ -f $src ]] || die "no $src to verify patches against"
	grep -qE 'sibling_cache_leaf|index >= sib_cpu_ci->num_leaves' "$src" ||
		die "x86/cacheinfo bounds-check fix is not present in the applied $src"
	echo ">> kernel patches verified (${#patches[@]} x86/cacheinfo KASAN patches applied via quilt)"
}

verify_kconfig() {
	local cfg=$KERNEL_OBJ/.config missing=() opt
	[[ -f $cfg ]] || die "no .config at $cfg after the build"
	for opt in "${KCONFIG_REQUIRED[@]}"; do
		grep -qx "$opt=y" "$cfg" || missing+=("$opt")
	done
	for opt in "${KCONFIG_REQUIRED_ANY[@]}"; do
		grep -qxE "$opt=[ym]" "$cfg" || missing+=("$opt")
	done
	for opt in "${KCONFIG_REQUIRED_VAL[@]}"; do
		grep -qxF "$opt" "$cfg" || missing+=("$opt")
	done
	if (( ${#missing[@]} )); then
		die "kernel built without required options: ${missing[*]}"
	fi
	echo ">> kernel config verified (${#KCONFIG_REQUIRED[@]} built in, "\
		"${#KCONFIG_REQUIRED_ANY[@]} built in or modular, "\
		"${#KCONFIG_REQUIRED_VAL[@]} exact-value)"
	verify_patches
}

# Build the Debian KASAN/KCOV kernel and install it into the cloud image.
#   prepare [--reset] [--branch <branch>]
# --reset rebuilds from a clean ~/.debsb; --branch selects a salsa
# kernel-team/linux branch (default debian/latest) that debsb clones and builds.
prepare() {
	local reset="" branch=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--reset) reset=--reset; shift ;;
			--branch)
				[[ $# -ge 2 ]] || die "prepare: --branch needs a branch name"
				branch=$2; shift 2 ;;
			--branch=*) branch=${1#--branch=}; shift ;;
			*) die "prepare: unknown option '$1' (use --reset and/or --branch <branch>)" ;;
		esac
	done

	if [[ $reset == --reset ]]; then
		echo ">> --reset: removing $DEBSB_DIR"
		rm -rf "$DEBSB_DIR"
	fi

	if [[ ! -x $VENV/bin/debsb ]]; then
		if [[ -x /home/debian-sid/venv-debsb/bin/debsb ]]; then
			VENV=/home/debian-sid/venv-debsb
		else
			echo ">> creating venv and installing debsb from $DEBSB_SRC"
			[[ -d $DEBSB_SRC ]] || die "debsb source not found: $DEBSB_SRC"
			python3 -m venv "$VENV"
			"$VENV/bin/pip" install -q -e "$DEBSB_SRC"
		fi
	fi

	# PATH first: ensure_toolchain looks for gcc-15 and zstd, and both may be
	# provided by these directories rather than by the system.
	export PATH="$GCC15_SHIM:$LOCALBIN:$PATH"
	ensure_toolchain

	local args=() item
	for item in "${KCONFIG_ITEMS[@]}"; do args+=(--configitem "$item"); done

	if [[ -n $branch ]]; then
		echo ">> building Debian kernel + image from salsa branch '$branch' "\
			"(${#KCONFIG_ITEMS[@]} config items); this takes a while"
	else
		echo ">> building Debian kernel + image (${#KCONFIG_ITEMS[@]} config items); this takes a while"
	fi
	"$VENV/bin/debsb" build --debian ${reset:+--reset} ${branch:+--branch "$branch"} "${args[@]}"

	have_kernel_image || die "build finished but artifacts are missing (expected $BZIMAGE)"
	verify_kconfig

	# The image changed, so anything derived from it must be rebuilt: drop the
	# converted copy and the one-time masking marker so prep_image redoes both.
	rm -f "$IMAGE" "$CACHE_DIR/.efi-masked"
	echo ">> prepare complete: $BZIMAGE"
}

# Used by the fuzzing commands: build only if something is actually missing.
ensure_prepared() {
	if ! have_kernel_image; then
		echo ">> kernel/image not found, running 'prepare' first"
		prepare
	fi
}

# Build the uncompressed, crosvm-readable image once, refreshing it whenever the
# debsb base image is newer. crosvm's qcow2 reader rejects compressed clusters,
# which the debsb/cloud image uses, so we always run through qemu-img convert.
prep_image() {
	mkdir -p "$CACHE_DIR"
	# One-time: make sure the FAT /boot/efi mount cannot wedge a direct-kernel
	# boot into emergency mode. debsb already marks it nofail, this is belt and
	# braces (see docs/linux/setup_linux-host_crosvm-vm_x86-64-kernel.md).
	if [[ ! -f $CACHE_DIR/.efi-masked ]]; then
		echo ">> preparing the base image for direct-kernel boot (one-time)"
		# Two independent fixes, both applied inside the guest:
		#
		# 1. boot-efi.mount: keep the FAT /boot/efi mount from wedging a
		#    direct-kernel boot into emergency mode.
		#
		# 2. Leave eth0 alone, but only eth0. crosvm has no DHCP server and the
		#    guest address comes from the kernel ip= argument (IP_PNP). The
		#    cloud image's network manager takes eth0 over during boot and,
		#    finding no DHCP, flushes that static address, so the host loses all
		#    routes to the guest ("No route to host") and syzkaller can never
		#    ssh in. qemu hides this because syzkaller reaches it on a forwarded
		#    localhost port instead of the guest's own address.
		#
		#    Disabling cloud-init's network config is what stops the flush, but
		#    it is all-or-nothing: with no config at all, every *other* NIC is
		#    left down too, including the ens2 of the qemu VM debsb boots to
		#    install the kernel packages, which then never reaches ssh. So
		#    cloud-init is switched off and systemd-networkd is given an
		#    explicit policy covering both cases. networkd applies the first
		#    matching file in lexical order, so eth0 stops at the 05- file and
		#    never reaches the 50- one.
		#
		#    eth0's policy cannot be static, because the *qemu* backend also
		#    sets net.ifnames=0 and so its NIC is eth0 too -- but there the
		#    address comes from slirp over DHCP, so marking eth0 unmanaged
		#    kills qemu ("can't ssh into the instance", zero execs). The two
		#    backends are told apart by the kernel ip= argument, which only
		#    crosvm passes, and syz-netcfg.service picks the policy at boot
		#    before systemd-networkd starts.
		# The eth0 selector is a script plus a unit file; pass it through
		# base64 rather than fighting three levels of shell quoting.
		local netfix_b64
		netfix_b64=$(base64 -w0 <<-'EOS'
			set -e
			cat > /usr/local/sbin/syz-netcfg <<'INNER'
			#!/bin/sh
			# crosvm boots with ip=... (IP_PNP): leave eth0 alone.
			# qemu boots without it and needs DHCP on eth0.
			set -e
			mkdir -p /etc/systemd/network
			if grep -qE '(^| )ip=[0-9]' /proc/cmdline; then
			    printf '[Match]\nName=eth0\n\n[Link]\nUnmanaged=yes\n' \
			        > /etc/systemd/network/05-eth0.network
			else
			    printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\n\n[Link]\nRequiredForOnline=no\n' \
			        > /etc/systemd/network/05-eth0.network
			fi
			INNER
			chmod 0755 /usr/local/sbin/syz-netcfg
			cat > /etc/systemd/system/syz-netcfg.service <<'INNER'
			[Unit]
			Description=Select eth0 network policy (crosvm static ip= vs qemu DHCP)
			DefaultDependencies=no
			After=systemd-remount-fs.service
			Before=systemd-networkd.service network-pre.target
			Wants=network-pre.target

			[Service]
			Type=oneshot
			RemainAfterExit=yes
			ExecStart=/usr/local/sbin/syz-netcfg

			[Install]
			WantedBy=sysinit.target
			INNER
			systemctl enable syz-netcfg.service
			rm -f /etc/systemd/network/05-eth0-unmanaged.network
			# qemu-safe default, so a failure of the unit breaks crosvm
			# loudly in testing rather than breaking qemu silently.
			printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\n\n[Link]\nRequiredForOnline=no\n' \
			    > /etc/systemd/network/05-eth0.network
		EOS
		)
		if ( . "$VENV/bin/activate" && \
		     debsb run --ssh --root --exec '
			set -e
			systemctl mask boot-efi.mount >/dev/null 2>&1 || true
			echo '"$netfix_b64"' | base64 -d | sh
			# cloud-init must not rewrite the network config on next boot.
			mkdir -p /etc/cloud/cloud.cfg.d
			printf "network: {config: disabled}\n" \
				>/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
			mkdir -p /etc/systemd/network
			rm -f /etc/systemd/network/10-eth0-unmanaged.network
			# every other NIC (debsb install VM ens2, etc): plain DHCP.
			printf "[Match]\nName=e*\n\n[Network]\nDHCP=yes\n\n[Link]\nRequiredForOnline=no\n" \
				>/etc/systemd/network/50-dhcp.network
			mkdir -p /etc/NetworkManager/conf.d
			printf "[keyfile]\nunmanaged-devices=interface-name:eth0\n" \
				>/etc/NetworkManager/conf.d/99-unmanaged-eth0.conf
			rm -f /etc/network/interfaces.d/eth0 /etc/netplan/*.yaml 2>/dev/null || true
			# 3. Load the emulation drivers syzkaller probes for. Debian builds
			#    these modular (see KCONFIG_REQUIRED_ANY), and syzkaller never
			#    modprobes: it decides a feature is unavailable when the device
			#    is not already there.
			mkdir -p /etc/modules-load.d
			printf "'"$(printf '%s\\n' "${GUEST_MODULES[@]}")"'" \
				>/etc/modules-load.d/syzkaller.conf
			true' ); then
			touch "$CACHE_DIR/.efi-masked"
		else
			echo ">> warning: could not prepare the base image; the guest may be unreachable" >&2
		fi
	fi
	if [[ ! -f $IMAGE || $BASE_QCOW -nt $IMAGE ]]; then
		echo ">> converting base image to uncompressed $IMAGE"
		# The masking step above boots a qemu VM against $BASE_QCOW; after its
		# ssh exec returns the VM is still powering off and briefly holds the
		# image's write lock. Retry until that lock is released (or time out).
		local tries=0
		until qemu-img convert -O qcow2 "$BASE_QCOW" "$IMAGE"; do
			tries=$((tries + 1))
			if (( tries >= 30 )); then
				echo ">> ERROR: base image still locked after 60s; aborting" >&2
				return 1
			fi
			echo ">> base image busy (poweroff in progress), retrying ($tries)..." >&2
			sleep 2
		done
	fi
}

# gen_config <backend> <rundir> <http-port>
# NOTE on suppressions: deliberately none. It is tempting to suppress the
# "BUG: MAX_LOCKDEP..." and "WARNING in rcu_check_gp_start_stall" noise, but a
# suppressed crash is filed under the generic "suppressed report" bucket and
# loses its title, which would make it impossible to confirm that
# CONFIG_LOCKDEP_CHAINS_BITS=18 actually eliminated the lockdep exhaustion.
# Add suppressions only once that is verified.
gen_config() {
	local backend=$1 rundir=$2 port=$3 sandbox=${4:-${SANDBOX:-setuid}} vmblock
	if [[ $backend == qemu ]]; then
		# image_device/network_device force virtio so the guest sees the same
		# /dev/vda and virtio NIC crosvm gives it; e1000 is modular here and
		# would leave a no-initrd guest with no network at all.
		if [[ $HOST_ARCH == "aarch64" ]]; then
			local qemu_args="-machine virt,virtualization=on,gic-version=max -cpu max,sve128=on,pauth=off -accel tcg"
			if [[ -w /dev/kvm ]]; then
				qemu_args="-machine virt,gic-version=3,accel=kvm -cpu host"
			fi
			vmblock=$(cat <<-JSON
				"vm": {
					"count": $SYZ_COUNT,
					"qemu": "$QEMU_BIN",
					"kernel": "$BZIMAGE",
					"cmdline": "root=/dev/vda1 rw console=ttyAMA0 earlycon=pl011 net.ifnames=0 ip=dhcp init=/sbin/syz-init",
					"qemu_args": "$qemu_args",
					"image_device": "drive index=0,media=disk,if=virtio,format=qcow2,file=",
					"network_device": "virtio-net-pci",
					"cpu": $SYZ_CPU,
					"mem": $SYZ_MEM
				}
			JSON
			)
		else
			vmblock=$(cat <<-JSON
				"vm": {
					"count": $SYZ_COUNT,
					"kernel": "$BZIMAGE",
					"cmdline": "root=/dev/vda1 rw net.ifnames=0 ip=dhcp init=/sbin/syz-init",
					"image_device": "drive index=0,media=disk,if=virtio,format=qcow2,file=",
					"network_device": "virtio-net-pci",
					"cpu": $SYZ_CPU,
					"mem": $SYZ_MEM
				}
			JSON
			)
		fi
	elif [[ $backend == firecracker ]]; then
		# Firecracker, like crosvm, always loads the kernel directly and has no
		# user-mode networking: the guest address comes from the kernel ip=
		# argument (IP_PNP), which the backend adds along with root_device and
		# console. It cannot read qcow2 and has no copy-on-write overlay, so the
		# backend converts $IMAGE to a per-VM raw copy with qemu-img itself.
		local fc_cmdline="rw net.ifnames=0 init=/sbin/syz-init"
		[[ $HOST_ARCH == "aarch64" ]] && fc_cmdline="rw console=ttyAMA0 earlycon=pl011 net.ifnames=0 init=/sbin/syz-init"
		vmblock=$(cat <<-JSON
			"vm": {
				"count": $SYZ_COUNT,
				"firecracker": "$FIRECRACKER_BIN",
				"kernel": "$BZIMAGE",
				"cpu": $SYZ_CPU,
				"mem": $SYZ_MEM,
				"root_device": "/dev/vda1",
				"cmdline": "$fc_cmdline"
			}
		JSON
		)
	else
		local cv_cmdline="rw net.ifnames=0 init=/sbin/syz-init"
		[[ $HOST_ARCH == "aarch64" ]] && cv_cmdline="rw console=ttyAMA0 earlycon=pl011 net.ifnames=0 init=/sbin/syz-init"
		vmblock=$(cat <<-JSON
			"vm": {
				"count": $SYZ_COUNT,
				"crosvm": "$CROSVM_BIN",
				"kernel": "$BZIMAGE",
				"cpu": $SYZ_CPU,
				"mem": $SYZ_MEM,
				"root_device": "/dev/vda1",
				"cmdline": "$cv_cmdline"
			}
		JSON
		)
	fi
	cat <<-JSON
		{
			"target": "$TARGET_ARCH",
			"http": "127.0.0.1:$port",
			"workdir": "$rundir/workdir",
			"kernel_obj": "$KERNEL_OBJ",
			"image": "$IMAGE",
			"sshkey": "$SSHKEY",
			"ssh_user": "root",
			"syzkaller": "$SYZ_DIR",
			"procs": $SYZ_PROCS,
			"sandbox": "$sandbox",
			"type": "$backend",
			$vmblock
		}
	JSON
}

# run_backend <backend> <seconds> <rundir> <http-port> [sandbox]
run_backend() {
	local backend=$1 secs=$2 rundir=$3 port=$4 sandbox=${5:-${SANDBOX:-setuid}}
	mkdir -p "$rundir/workdir"
	local cfg=$rundir/manager.cfg bench=$rundir/bench.json log=$rundir/manager.log
	gen_config "$backend" "$rundir" "$port" "$sandbox" >"$cfg"
	rm -f "$bench"

	echo ">> $backend: fuzzing for ${secs}s (sandbox: $sandbox)"
	echo ">> config:  $cfg"
	echo ">> log:     $log"
	echo ">> bench:   $bench"
	[[ $backend == qemu ]] && echo ">> web UI:  http://127.0.0.1:$port"

	local mgr=("$SYZ_DIR/bin/syz-manager" -config "$cfg" -bench "$bench")
	local rc=0
	set +e
	if [[ $backend == crosvm || $backend == firecracker ]]; then
		# crosvm and firecracker both set up a tap device per VM, which needs
		# CAP_NET_ADMIN. Running the whole manager in a user+net+mount namespace
		# gives it that without any host-wide privilege (see the setup doc's
		# networking section). Firecracker never creates the tap itself, so the
		# backend does it with "ip tuntap"; that also needs to run in this
		# namespace.
		#
		# A fresh netns starts with loopback DOWN, and the web dashboard binds
		# 127.0.0.1: bring lo up first or nothing can connect to it, not even
		# from inside the namespace. The dashboard is unreachable from the host
		# either way (the namespace has no veth to it), so reach it with:
		#   MGR=$(pgrep -f bin/syz-manager | head -1)
		#   nsenter -t $MGR -U -n --preserve-credentials --setuid 0 --setgid 0 \
		#           curl -s http://127.0.0.1:$port/
		unshare -Urnm bash -c '
			ip link set lo up 2>/dev/null || true
			exec "$@"' _ timeout -s INT -k 120 "$secs" "${mgr[@]}" >"$log" 2>&1
		rc=$?
	else
		timeout -s INT -k 120 "$secs" "${mgr[@]}" >"$log" 2>&1
		rc=$?
	fi
	set -e
	# timeout exits 124 when it had to stop a still-running manager: that is the
	# normal end of a timed run, not a failure.
	if [[ $rc -ne 0 && $rc -ne 124 && $rc -ne 130 && $rc -ne 137 ]]; then
		echo ">> warning: $backend manager exited early (rc=$rc); see $log" >&2
		tail -n 15 "$log" >&2 || true
	fi
	if [[ ! -s $bench ]]; then
		echo ">> warning: no bench data was written for $backend; the VMs may never have booted." >&2
		echo ">> last log lines:" >&2
		tail -n 25 "$log" >&2 || true
	fi
	return 0
}

# --------------------------------------------------------------------------
# Reporting (parses the concatenated pretty-printed JSON in a bench file)
# --------------------------------------------------------------------------
REPORT_PY=$CACHE_DIR/.syz-report.py

write_report_py() {
	mkdir -p "$CACHE_DIR"
	cat >"$REPORT_PY" <<'PY'
import json, sys

KEYS = ["corpus", "coverage", "signal", "max signal", "exec total",
        "crashes", "exec retries", "instance restart", "executor restarts",
        "no exec requests", "no exec duration", "cover overflows",
        "prog exec time", "syscalls", "modules"]

def load(path):
    """Read a bench file of concatenated indented JSON objects."""
    try:
        text = open(path).read()
    except OSError:
        return []
    dec, snaps, i, n = json.JSONDecoder(), [], 0, len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        obj, end = dec.raw_decode(text, i)
        snaps.append(obj)
        i = end
    return snaps

def secs(s):
    """Wall-clock seconds of fuzzing. 'uptime' is manager wall time in seconds;
    'fuzzing' is summed VM time in nanoseconds, so it is only a fallback."""
    if s.get("uptime", 0):
        return s["uptime"]
    if s.get("fuzzing", 0):
        return s["fuzzing"] / 1e9
    return 0

def rate(s):
    t = secs(s)
    return s.get("exec total", 0) / t if t else 0.0

def summarize(path, label):
    snaps = load(path)
    print(f"=== {label} ===")
    if not snaps:
        print("  (no bench data)\n")
        return
    f = snaps[-1]
    for k in KEYS:
        if k in f:
            print(f"  {k:20s} {f[k]}")
    print(f"  {'uptime (wall s)':20s} {int(secs(f))}")
    if f.get("fuzzing"):
        print(f"  {'fuzzing (VM-s)':20s} {int(f['fuzzing'] / 1e9)}")
    print(f"  {'exec/sec (mean)':20s} {rate(f):.1f}")
    print()

def cmp_col(q, c):
    if q == 0:
        return "n/a"
    return f"{(c - q) / q * 100:+.1f}%"

def compare(qpath, cpath, fpath, out):
    """Three-way comparison. qemu is the baseline; crosvm and firecracker are each
    reported as a percentage delta against it, since the VMM changes only how fast
    programs are shipped, not which ones."""
    qs, cs, fs = load(qpath), load(cpath), load(fpath)
    lines = []
    def emit(s=""):
        lines.append(s)
    emit("# QEMU vs crosvm vs firecracker (syzkaller, same kernel/image/VM shape)")
    emit()
    if not qs or not cs or not fs:
        emit("Incomplete data: "
             f"qemu snapshots={len(qs)}, crosvm snapshots={len(cs)}, "
             f"firecracker snapshots={len(fs)}.")
        text = "\n".join(lines) + "\n"
        open(out, "w").write(text)
        print(text)
        return
    q, c, f = qs[-1], cs[-1], fs[-1]
    emit("## Headline")
    emit()
    emit("```")
    emit(f"{'':22s}{'qemu':>12s}{'crosvm':>12s}{'firecracker':>12s}"
         f"{'crosvm vs q':>14s}{'fc vs q':>14s}")
    for k in ["corpus", "coverage", "signal", "max signal", "exec total"]:
        qv, cv, fv = q.get(k, 0), c.get(k, 0), f.get(k, 0)
        emit(f"{k:22s}{qv:>12d}{cv:>12d}{fv:>12d}"
             f"{cmp_col(qv, cv):>14s}{cmp_col(qv, fv):>14s}")
    qt, ct, ft = int(secs(q)), int(secs(c)), int(secs(f))
    emit(f"{'wall time (s)':22s}{qt:>12d}{ct:>12d}{ft:>12d}{'':>14s}{'':>14s}")
    qr, cr, fr = rate(q), rate(c), rate(f)
    emit(f"{'exec/sec (mean)':22s}{qr:>12.1f}{cr:>12.1f}{fr:>12.1f}"
         f"{cmp_col(qr, cr):>14s}{cmp_col(qr, fr):>14s}")
    # coverage per 1k execs
    q1k = q.get("coverage", 0) / (q.get("exec total", 1) or 1) * 1000
    c1k = c.get("coverage", 0) / (c.get("exec total", 1) or 1) * 1000
    f1k = f.get("coverage", 0) / (f.get("exec total", 1) or 1) * 1000
    emit(f"{'coverage/1k execs':22s}{q1k:>12.0f}{c1k:>12.0f}{f1k:>12.0f}"
         f"{cmp_col(q1k, c1k):>14s}{cmp_col(q1k, f1k):>14s}")
    emit(f"{'crashes':22s}{q.get('crashes',0):>12d}{c.get('crashes',0):>12d}"
         f"{f.get('crashes',0):>12d}")
    emit("```")
    emit()
    emit("## Stability")
    emit()
    emit("```")
    emit(f"{'':22s}{'qemu':>12s}{'crosvm':>12s}{'firecracker':>12s}")
    for k in ["instance restart", "executor restarts", "exec retries",
              "no exec requests", "no exec duration", "cover overflows",
              "prog exec time", "syscalls", "modules"]:
        emit(f"{k:22s}{q.get(k,0):>12d}{c.get(k,0):>12d}{f.get(k,0):>12d}")
    emit("```")
    emit()
    emit("## Coverage growth over time (per-minute bench snapshots)")
    emit()
    emit("```")
    emit(f"{'min':>4s}{'q cov':>9s}{'c cov':>9s}{'f cov':>9s}"
         f"{'q exec':>10s}{'c exec':>10s}{'f exec':>10s}")
    n = min(len(qs), len(cs), len(fs))
    for i in range(n):
        qq, cc, ff = qs[i], cs[i], fs[i]
        qcov, ccov, fcov = qq.get("coverage", 0), cc.get("coverage", 0), ff.get("coverage", 0)
        qex, cex, fex = qq.get("exec total", 0), cc.get("exec total", 0), ff.get("exec total", 0)
        emit(f"{i+1:>4d}{qcov:>9d}{ccov:>9d}{fcov:>9d}"
             f"{qex:>10d}{cex:>10d}{fex:>10d}")
    emit("```")
    emit()
    emit("Notes: coverage follows throughput (exec total); the VMM does not "
         "change which programs syzkaller runs, only how fast they are shipped. "
         "A single set of runs cannot establish a small percentage difference "
         "as a property of the backends. Treat this as evidence that the crosvm "
         "and firecracker backends keep up with qemu, not as a benchmark.")
    text = "\n".join(lines) + "\n"
    open(out, "w").write(text)
    print(text)

if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "summary":
        summarize(sys.argv[2], sys.argv[3])
    elif mode == "compare":
        compare(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
PY
}

report_one() {
	local backend=$1 rundir=$2
	write_report_py
	python3 "$REPORT_PY" summary "$rundir/bench.json" "$backend"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
SANDBOX=${SYZ_SANDBOX:-setuid}

# Parse options
args=()
while [[ $# -gt 0 ]]; do
	case $1 in
		-sandbox|--sandbox)
			[[ $# -ge 2 ]] || die "missing argument for $1"
			SANDBOX=$2
			shift 2
			;;
		-sandbox=*|--sandbox=*)
			SANDBOX="${1#*=}"
			shift
			;;
		*)
			args+=("$1")
			shift
			;;
	esac
done
if [[ ${#args[@]} -gt 0 ]]; then
	set -- "${args[@]}"
else
	set --
fi

case $SANDBOX in
	none|setuid|namespace) ;;
	*) die "invalid sandbox '$SANDBOX': must be none, setuid, or namespace" ;;
esac

[[ $# -ge 1 ]] || usage
cmd=$1
case $cmd in
	prepare)
		shift
		prepare "$@"
		;;
	crosvm|qemu|firecracker)
		[[ $# -eq 2 ]] || usage
		secs=$(to_seconds "$2")
		[[ $secs -gt 0 ]] || die "duration must be > 0"
		check_tools "$cmd"
		ensure_prepared
		prep_image
		ts=$(date +%Y%m%d-%H%M%S)
		rundir=$RUNS_DIR/$cmd-$SANDBOX-$ts
		case $cmd in
			qemu)        port=56761 ;;
			crosvm)      port=56762 ;;
			firecracker) port=56763 ;;
		esac
		run_backend "$cmd" "$secs" "$rundir" "$port" "$SANDBOX"
		echo
		report_one "$cmd" "$rundir"
		echo ">> results in $rundir"
		;;
	compare)
		[[ $# -eq 2 ]] || usage
		secs=$(to_seconds "$2")
		[[ $secs -gt 0 ]] || die "duration must be > 0"
		check_tools qemu crosvm firecracker
		ensure_prepared
		prep_image
		ts=$(date +%Y%m%d-%H%M%S)
		cmpdir=$RUNS_DIR/compare-$SANDBOX-$ts
		echo "############ QEMU (${secs}s, sandbox: $SANDBOX) ############"
		run_backend qemu "$secs" "$cmpdir/qemu" 56761 "$SANDBOX"
		echo "############ crosvm (${secs}s, sandbox: $SANDBOX) ############"
		run_backend crosvm "$secs" "$cmpdir/crosvm" 56762 "$SANDBOX"
		echo "############ firecracker (${secs}s, sandbox: $SANDBOX) ############"
		run_backend firecracker "$secs" "$cmpdir/firecracker" 56763 "$SANDBOX"
		echo
		echo "############ Report ############"
		write_report_py
		python3 "$REPORT_PY" compare \
			"$cmpdir/qemu/bench.json" "$cmpdir/crosvm/bench.json" \
			"$cmpdir/firecracker/bench.json" \
			"$cmpdir/report.md"
		echo ">> report written to $cmpdir/report.md"
		;;
	-h|--help|help)
		usage
		;;
	*)
		die "unknown command '$cmd' (use prepare | qemu | crosvm | firecracker | compare)"
		;;
esac
