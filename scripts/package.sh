#!/usr/bin/env bash
# Package build output: AnyKernel3 flashable zip and, optionally, a boot image.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
AK3="${WORKSPACE}/AnyKernel3"

# Upstream's anykernel.sh ships a Galaxy Nexus demo between dump_boot and
# write_boot: it patches init.rc, init.tuna.rc and fstab.tuna. Those files do
# not exist on other devices, and append_file *creates* what it cannot find --
# so flashing the stock template writes two stray files into the ramdisk of
# whatever device it lands on. A plain kernel swap only needs unpack + repack.
strip_ak3_demo_patches() {
	local f="${AK3}/anykernel.sh"
	grep -q '^dump_boot;' "$f" && grep -q '^write_boot;' "$f" || {
		warn "anykernel.sh has no dump_boot/write_boot pair; leaving it alone"
		return 0
	}
	awk '
		/^dump_boot;/  { print; skip = 1; next }
		/^write_boot;/ { skip = 0 }
		!skip          { print }
	' "$f" > "${f}.new" && mv -f "${f}.new" "$f"
	ok "removed the AnyKernel3 demo ramdisk patches"
}

# The zip otherwise advertises itself as "ExampleKernel by osm0sis", which is
# what the installer prints while flashing.
set_ak3_kernel_string() {
	local label="${DEVICE:-kernel} ${KERNEL_RELEASE:-}"
	[ -n "${KSU_NAME:-}" ] && label="${label} + ${KSU_NAME} ${KSU_VERSION_LABEL:-}"
	# Collapse runs of whitespace left by any empty component.
	label=$(printf '%s' "$label" | tr -s ' ')
	sed -i "s|^kernel.string=.*|kernel.string=${label}|" "${AK3}/anykernel.sh"
}

make_anykernel3() {
	group "Building AnyKernel3 package"
	rm -rf "$AK3"

	if is_true "${USE_CUSTOM_ANYKERNEL3:-false}"; then
		local src=${CUSTOM_ANYKERNEL3_SOURCE:?CUSTOM_ANYKERNEL3_SOURCE required}
		case "$src" in
			*.tar.gz | *.tgz)
				fetch "$src" "${WORKSPACE}/ak3.tar.gz"
				extract_archive "${WORKSPACE}/ak3.tar.gz" "$AK3" ;;
			*.zip)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
			*git*)
				retry 3 git clone -q --depth=1 ${CUSTOM_ANYKERNEL3_BRANCH:+-b "$CUSTOM_ANYKERNEL3_BRANCH"} \
					"$src" "$AK3" || die "failed to clone ${src}" ;;
			*)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
		esac
	else
		retry 3 git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK3" \
			|| die "failed to clone AnyKernel3"
		# Device checks are meaningless here: we do not know the target's
		# ro.product.device, and the zip is flashed deliberately by its builder.
		sed -i 's/do.devicecheck=1/do.devicecheck=0/g' "${AK3}/anykernel.sh"
		sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' "${AK3}/anykernel.sh"
		sed -i 's/IS_SLOT_DEVICE=0;/is_slot_device=auto;/g' "${AK3}/anykernel.sh"
		strip_ak3_demo_patches
		set_ak3_kernel_string
	fi

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${AK3}/" \
		|| die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"
	if is_true "${CHECK_DTBO_IS_OK:-false}"; then
		cp "${BOOT_OUT}/dtbo.img" "${AK3}/"
	fi

	# The kernel, the base device tree and the dtbo overlay are built together
	# and only work together. AnyKernel3 replaces the dtb inside the boot image
	# only when a file literally named "dtb" sits in the zip root (ak3-core.sh
	# looks for $AKHOME/dtb); without it the repack keeps the *stock* dtb while
	# the freshly built overlay still lands in the dtbo partition. The bootloader
	# then applies a new overlay onto an old base, which on this class of device
	# means a boot failure into fastboot rather than a visible error.
	if [ -f "${BOOT_OUT}/dtb" ]; then
		cp "${BOOT_OUT}/dtb" "${AK3}/"
		ok "included dtb ($(du -h "${BOOT_OUT}/dtb" | cut -f1)) so it matches the flashed dtbo"
	fi
	rm -rf "${AK3}/.git" "${AK3}/.github" "${AK3}/README.md"

	ok "AnyKernel3 package assembled"
	endgroup
}

make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Repacking boot image"

	local tools="${WORKSPACE}/tools"
	[ -x "${tools}/unpack_bootimg.py" ] || [ -f "${tools}/unpack_bootimg.py" ] \
		|| die "mkbootimg tools not found at ${tools}"

	fetch "${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}" "${WORKSPACE}/boot-source.img"

	cd "$WORKSPACE"
	local fmt
	fmt=$(python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img --format mkbootimg) \
		|| die "failed to read the source boot image"
	info "source boot image args: ${fmt}"

	python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img >/dev/null \
		|| die "failed to unpack the source boot image"

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/out/kernel" \
		|| die "could not stage the new kernel into the unpacked ramdisk"

	# shellcheck disable=SC2086
	python3 "${tools}/mkbootimg.py" $fmt -o boot.img || die "mkbootimg failed"
	[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"

	ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
	export_env MAKE_BOOT_IMAGE_IS_OK true
	endgroup
}

write_summary() {
	summary ""
	summary "### Build artifacts"
	summary ""
	summary "| Artifact | Size |"
	summary "| --- | --- |"
	local f
	for f in "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${BOOT_OUT}/dtbo.img" "${WORKSPACE}/boot.img"; do
		[ -f "$f" ] && summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
	done
	[ -d "$AK3" ] && summary "| \`AnyKernel3\` (flashable zip) | $(du -sh "$AK3" | cut -f1) |"
	summary ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		anykernel3) make_anykernel3 ;;
		bootimg)    make_boot_image ;;
		all)        make_anykernel3; make_boot_image; write_summary ;;
		*) die "unknown package step '$1'" ;;
	esac
fi
