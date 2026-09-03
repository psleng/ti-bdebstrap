#!/bin/bash
# Filename: build.sh
# Author: "Sai Sree Kartheek Adivi <s-adivi@ti.com>"
# Description: Script to build a Debian SD card image for TI Platforms
###############################################################################

# set -x

legacy_boot_layout() {
    BOOT3OFFSET=0
    SPLOFFSET=0x800
    UBOOTOFFSET=0x1800
    BOOTIMG_SIZE_BYTES=$((7 * 1024 * 1024))

    case "$machine" in
        am64xx-evm|j7200-evm)
            ;;
        *)
            SPLOFFSET=0x700
            UBOOTOFFSET=0x1000
            BOOTIMG_SIZE_BYTES=$((4 * 1024 * 1024))
            ;;
    esac
}

derive_boot_layout_from_uboot_env() {
    local uboot_src="$topdir/build/$distro/bsp_sources/ti-u-boot"
    local env_dir="$uboot_src/include/environment/ti"
    local igos_r5_cfg="$uboot_src/configs/am64x_igos_r5_defconfig"
    local igos_a53_cfg="$uboot_src/configs/am64x_igos_a53_defconfig"
    local board_env=""
    local dfu_env_file=""
    local block=""

    # iGOS-specific source-of-truth: patched defconfigs use raw-mode sectors.
    # - r5 defconfig sector is where tiboot3 loads tispl.bin
    # - a53 defconfig sector is where tispl loads u-boot.img
    if [ -f "$igos_r5_cfg" ] && [ -f "$igos_a53_cfg" ]; then
        local r5_sector a53_sector
        r5_sector=$(awk -F= '/^CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=/{print $2; exit}' "$igos_r5_cfg")
        a53_sector=$(awk -F= '/^CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=/{print $2; exit}' "$igos_a53_cfg")
        if [ -n "$r5_sector" ] && [ -n "$a53_sector" ]; then
            BOOT3OFFSET=0
            SPLOFFSET="$r5_sector"
            UBOOTOFFSET="$a53_sector"
            BOOTIMG_SIZE_BYTES=$((4 * 1024 * 1024))
            echo "I: $0: Derived iGOS boot layout from defconfigs: tiboot3=$BOOT3OFFSET tispl=$SPLOFFSET u-boot=$UBOOTOFFSET bytes=$BOOTIMG_SIZE_BYTES" >&2
            return 0
        fi
    fi

    case "$machine" in
        am64xx-evm)
            board_env="$uboot_src/board/ti/am64x/am64x.env"
            ;;
        j7200-evm)
            board_env="$uboot_src/board/ti/j721e/j721e.env"
            ;;
        *)
            board_env="$uboot_src/board/ti/am64x/am64x.env"
            ;;
    esac

    if [ -f "$board_env" ]; then
        # Pick k3_dfu*.env included by board env. If multiple are present (preprocessor branches),
        # prefer k3_dfu_combined.env because it matches current K3 eMMC combined layout.
        local includes
        includes=$(grep -oE 'k3_dfu[^>]*\.env' "$board_env" | awk '!seen[$0]++' || true)
        if echo "$includes" | grep -q '^k3_dfu_combined\.env$'; then
            dfu_env_file="k3_dfu_combined.env"
        elif [ -n "$includes" ]; then
            dfu_env_file=$(echo "$includes" | head -n1)
        fi
    fi

    if [ -z "$dfu_env_file" ]; then
        if [ -f "$env_dir/k3_dfu_combined.env" ]; then
            dfu_env_file="k3_dfu_combined.env"
        elif [ -f "$env_dir/k3_dfu.env" ]; then
            dfu_env_file="k3_dfu.env"
        fi
    fi

    if [ -z "$dfu_env_file" ] || [ ! -f "$env_dir/$dfu_env_file" ]; then
        echo "W: $0: Cannot locate TI U-Boot DFU env file; using legacy boot layout" >&2
        legacy_boot_layout
        return 0
    fi

    # Extract dfu_alt_info_emmc block only.
    block=$(awk '
        /^dfu_alt_info_emmc=/ {inblk=1; next}
        inblk && /^[[:space:]]*[A-Za-z0-9_]+=/{exit}
        inblk {print}
    ' "$env_dir/$dfu_env_file")

    if [ -z "$block" ]; then
        echo "W: $0: dfu_alt_info_emmc missing in $dfu_env_file; using legacy boot layout" >&2
        legacy_boot_layout
        return 0
    fi

    local tiboot_line tispl_line uboot_line
    tiboot_line=$(echo "$block" | tr ';' '\n' | grep -E '^[[:space:]]*tiboot3\.bin\.raw[[:space:]]+raw[[:space:]]+' | head -n1 || true)
    tispl_line=$(echo "$block" | tr ';' '\n' | grep -E '^[[:space:]]*tispl\.bin\.raw[[:space:]]+raw[[:space:]]+' | head -n1 || true)
    uboot_line=$(echo "$block" | tr ';' '\n' | grep -E '^[[:space:]]*u-boot\.img\.raw[[:space:]]+raw[[:space:]]+' | head -n1 || true)

    if [ -z "$tiboot_line" ] || [ -z "$tispl_line" ] || [ -z "$uboot_line" ]; then
        echo "W: $0: Missing one or more raw boot entries in $dfu_env_file; using legacy boot layout" >&2
        legacy_boot_layout
        return 0
    fi

    BOOT3OFFSET=$(echo "$tiboot_line" | awk '{print $3}')
    SPLOFFSET=$(echo "$tispl_line" | awk '{print $3}')
    UBOOTOFFSET=$(echo "$uboot_line" | awk '{print $3}')

    # Size image to cover full dfu_alt_info_emmc raw span (including u-env/sysfw if present).
    local max_end=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local end_hex end_dec
        end_hex=$(echo "$line" | awk '{print $4}')
        end_dec=$((end_hex))
        if [ "$end_dec" -gt "$max_end" ]; then
            max_end="$end_dec"
        fi
    done <<EOF
$(echo "$block" | tr ';' '\n' | grep -E '^[[:space:]]*[^[:space:]]+\.raw[[:space:]]+raw[[:space:]]+')
EOF

    if [ "$max_end" -le 0 ]; then
        echo "W: $0: Could not compute image size from $dfu_env_file; using legacy boot layout" >&2
        legacy_boot_layout
        return 0
    fi

    BOOTIMG_SIZE_BYTES=$((max_end * 512))
    echo "I: $0: Derived boot layout from $dfu_env_file: tiboot3=$BOOT3OFFSET tispl=$SPLOFFSET u-boot=$UBOOTOFFSET bytes=$BOOTIMG_SIZE_BYTES" >&2
}

function mkdeb() {
    # Make a .deb of u-boot
    dir="$1"

    VERS=$bsp_version
    ARCH=$(dpkg-architecture -q DEB_BUILD_ARCH)
    PKGNAME=u-boot
    PKG=$(mktemp -t -d $PKGNAME-debXXXXX)
    chmod go+rx $PKG
    mkdir -p $PKG/DEBIAN

    # The control file
    cat > $PKG/DEBIAN/control <<-%
	Package: $PKGNAME
	Version: $VERS
	Priority: optional
	Architecture: $ARCH
	Section: kernel
	Maintainer: Perle Systems <psleng@perle.com>
	Homepage: https://github.com/psleng
	Description: The u-boot for ${machine}
	 machine: ${machine}
	 bsp_version: ${bsp_version}
	 distro: ${distro}
	 host_arch: ${host_arch}
	%

    # The data
    mkdir -p $PKG/usr/lib/$PKGNAME/platform
    cp -pr "$dir"/* $PKG/usr/lib/$PKGNAME/platform

    # Add a single raw boot image payload built from tiboot3.bin, tispl.bin, u-boot.img
    derive_boot_layout_from_uboot_env

    TIBOOT3="$dir/tiboot3.bin"
    TISPL="$dir/tispl.bin"
    UBOOTIMG="$dir/u-boot.img"
    RAW_BOOT_IMG="$PKG/usr/lib/$PKGNAME/platform/u-boot-raw-boot-${machine}.img"
    RAW_BOOT_IMG_LATEST="$PKG/usr/lib/$PKGNAME/platform/u-boot-raw-boot.img"

    if [ -f "$TIBOOT3" ] && [ -f "$TISPL" ] && [ -f "$UBOOTIMG" ]; then
        truncate -s "$BOOTIMG_SIZE_BYTES" "$RAW_BOOT_IMG"
        dd if="$TIBOOT3" of="$RAW_BOOT_IMG" bs=512 seek="$BOOT3OFFSET" conv=notrunc status=none
        dd if="$TISPL" of="$RAW_BOOT_IMG" bs=512 seek="$((SPLOFFSET))" conv=notrunc status=none
        dd if="$UBOOTIMG" of="$RAW_BOOT_IMG" bs=512 seek="$((UBOOTOFFSET))" conv=notrunc status=none
        ln -s "$(basename "$RAW_BOOT_IMG")" "$RAW_BOOT_IMG_LATEST"
    else
        echo "W: $0: Cannot make raw boot image, one or more boot binaries missing in $dir" >&2
    fi

    # Config files: N/A
    # > $PKG/DEBIAN/conffiles

    # Postinst actions: N/A

    # Changelog
    CHANGELOG=$PKG/usr/share/doc/$PKGNAME/changelog.gz
    mkdir -p $(dirname $CHANGELOG)
    (
     echo "$PKGNAME ($VERS) unstable; urgency=medium"
     echo "  [ psleng ]"
     echo "  * $PKGNAME binaries"
     # cd build/*/bsp_sources/ti-u-boot
     # git log | sed 's/^./* &/'
     echo
     echo " -- TI (nobody@example.com) $(date -R)"
    ) | gzip -9 > $CHANGELOG

    # Copyright
    COPYRIGHT=$PKG/usr/share/doc/$PKGNAME/copyright
    mkdir -p $(dirname $COPYRIGHT)
    echo 'Copyright (C) 2016-2021 Texas Instruments Incorporated - https://www.ti.com' > $COPYRIGHT

    # The md5sums
    (cd $PKG; find . -type f | grep -v /DEBIAN | xargs md5sum) > $PKG/DEBIAN/md5sums

    # Build $PKGNAME.deb
    fakeroot dpkg-deb --build $PKG

    DEBPKG=${PKGNAME}_${VERS}_${ARCH}.deb
    DEB_OUT_DIR=${TI_BDEBSTRAP_HOME:-${topdir}/ti-bdebstrap}
    mkdir -p "$DEB_OUT_DIR"
    DST=${DEB_OUT_DIR}/$DEBPKG
    mv -f $PKG.deb $DST
    echo "I: $0: Made $(realpath $DST) from $dir"
    # lintian $DEBPKG

    rm -rf "$PKG"
}

function mkdeb_tpm_assets() {
    # Make a .deb of OP-TEE TPM runtime+assets
    # (tee-supplicant + service + udev rules + TA files)
    VERS=$bsp_version
    PKGNAME=optee-tpm-assets
    ARCH=all
    PKG=$(mktemp -t -d $PKGNAME-debXXXXX)
    chmod go+rx $PKG
    mkdir -p $PKG/DEBIAN

    local optee_dir="${OPTEE_DIR:-${topdir}/build/${distro}/bsp_sources/optee_os}"
    local rt_rootfs="${topdir}/build/${distro}/tisdk-debian-${distro}-${bsp_version}-rootfs"
    local ta_src_dir="${optee_dir}/out/arm-plat-k3/export-ta_arm64/ta"
    local rules_src_dir="${optee_dir}/optee_client/tee-supplicant"
    local teec_lib=""
    local teec_pc=""
    local supp_bin=""
    local supp_unit=""

    # The control file
    cat > $PKG/DEBIAN/control <<-%
	Package: $PKGNAME
	Version: $VERS
	Priority: optional
	Architecture: $ARCH
	Section: misc
	Maintainer: Perle Systems <psleng@perle.com>
	Homepage: https://github.com/psleng
	Description: OP-TEE TPM assets for ${machine}
	 Contains OP-TEE runtime binaries and assets for machine: ${machine},
	 bsp_version: ${bsp_version}, distro: ${distro}.
	 Includes tee-supplicant runtime + systemd unit, udev rules and OP-TEE
	 Trusted Application (.ta) files required by fTPM.
	%

    # Resolve runtime binary and service from preferred locations.
    # Prefer staged rootfs artifacts, fall back to optee_client build outputs.
    for p in \
        "${rt_rootfs}/usr/sbin/tee-supplicant" \
        "${optee_dir}/optee_client/tee-supplicant/tee-supplicant"
    do
        if [ -f "$p" ]; then
            supp_bin="$p"
            break
        fi
    done

    for p in \
        "${rt_rootfs}/usr/lib/systemd/system/tee-supplicant@.service" \
        "${optee_dir}/optee_client/tee-supplicant/tee-supplicant@.service"
    do
        if [ -f "$p" ]; then
            supp_unit="$p"
            break
        fi
    done

    # Resolve libteec static lib + pkg-config metadata.
    # Prefer staged rootfs artifacts, fall back to optee_client build outputs.
    for p in \
        "${rt_rootfs}/usr/lib/libteec.a" \
        "${optee_dir}/optee_client/libteec/libteec.a"
    do
        if [ -f "$p" ]; then
            teec_lib="$p"
            break
        fi
    done

    for p in \
        "${rt_rootfs}/usr/lib/pkgconfig/teec.pc" \
        "${optee_dir}/optee_client/libteec/teec.pc"
    do
        if [ -f "$p" ]; then
            teec_pc="$p"
            break
        fi
    done

    # Validate source artifacts exist
    shopt -s nullglob
    local ta_files=("${ta_src_dir}"/*.ta)
    local rules_files=("${rules_src_dir}"/*.rules)
    local rules_templates=("${rules_src_dir}"/*.rules.in)
    shopt -u nullglob

    if [ ${#ta_files[@]} -eq 0 ]; then
        echo "W: $0: No TPM TA files found at ${ta_src_dir}; skipping ${PKGNAME} package" >&2
        rm -rf "$PKG"
        return 0
    fi

    if [ ${#rules_files[@]} -eq 0 ] && [ ${#rules_templates[@]} -eq 0 ]; then
        echo "W: $0: No tee-supplicant rules sources found at ${rules_src_dir}; skipping ${PKGNAME} package" >&2
        rm -rf "$PKG"
        return 0
    fi

    if [ -z "$supp_bin" ] || [ -z "$supp_unit" ] || [ -z "$teec_lib" ] || [ -z "$teec_pc" ]; then
        echo "W: $0: Missing tee-supplicant runtime artifacts; skipping ${PKGNAME} package" >&2
        echo "W: $0: searched runtime roots: ${rt_rootfs} and ${rules_src_dir}" >&2
        echo "W: $0: tee-supplicant=${supp_bin:-missing} unit=${supp_unit:-missing} libteec=${teec_lib:-missing} teec.pc=${teec_pc:-missing}" >&2
        rm -rf "$PKG"
        return 0
    fi

    # The data
    mkdir -p "$PKG/usr/sbin" "$PKG/usr/lib/systemd/system"
    cp -p "$supp_bin" "$PKG/usr/sbin/tee-supplicant"
    cp -p "$supp_unit" "$PKG/usr/lib/systemd/system/tee-supplicant@.service"

    mkdir -p "$PKG/usr/lib/pkgconfig"
    cp -p "$teec_lib" "$PKG/usr/lib/libteec.a"
    cp -p "$teec_pc" "$PKG/usr/lib/pkgconfig/teec.pc"

    mkdir -p "$PKG/usr/lib/firmware/optee"
    cp -pr "${ta_src_dir}"/*.ta "$PKG/usr/lib/firmware/optee/"

    mkdir -p "$PKG/etc/udev/rules.d"
    if [ ${#rules_files[@]} -gt 0 ]; then
        cp -pr "${rules_src_dir}"/*.rules "$PKG/etc/udev/rules.d/"
    fi

    # Newer optee_client may only provide template files (*.rules.in).
    # Render them with current upstream defaults from tee-supplicant CMakeLists:
    # CFG_TEE_SUPPL_USER=root, CFG_TEE_GROUP=root, CFG_TEEPRIV_GROUP=root.
    if [ ${#rules_templates[@]} -gt 0 ]; then
        local tpl
        for tpl in "${rules_templates[@]}"; do
            local out
            out="$PKG/etc/udev/rules.d/$(basename "${tpl%.in}")"
            sed \
                -e 's/@CFG_TEE_SUPPL_USER@/root/g' \
                -e 's/@CFG_TEE_GROUP@/root/g' \
                -e 's/@CFG_TEEPRIV_GROUP@/root/g' \
                "$tpl" > "$out"
        done
    fi

    # Mirror udev rules into /usr/etc path used by TI rootfs layout.
    mkdir -p "$PKG/usr/etc/udev/rules.d"
    cp -pr "$PKG/etc/udev/rules.d"/*.rules "$PKG/usr/etc/udev/rules.d/"

    # Changelog
    CHANGELOG=$PKG/usr/share/doc/$PKGNAME/changelog.gz
    mkdir -p $(dirname $CHANGELOG)
    (
     echo "$PKGNAME ($VERS) unstable; urgency=medium"
     echo "  [ psleng ]"
    echo "  * OP-TEE TPM runtime+assets (tee-supplicant + libteec + udev rules + .ta)"
     echo
     echo " -- TI (nobody@example.com) $(date -R)"
    ) | gzip -9 > $CHANGELOG

    # Copyright
    COPYRIGHT=$PKG/usr/share/doc/$PKGNAME/copyright
    mkdir -p $(dirname $COPYRIGHT)
    echo 'Copyright (C) 2016-2021 Texas Instruments Incorporated - https://www.ti.com' > $COPYRIGHT

    # The md5sums
    (cd $PKG; find . -type f | grep -v /DEBIAN | xargs md5sum) > $PKG/DEBIAN/md5sums

    # Build package
    fakeroot dpkg-deb --build $PKG

    DEBPKG=${PKGNAME}_${VERS}_${ARCH}.deb
    DEB_OUT_DIR=${TI_BDEBSTRAP_HOME:-${topdir}/ti-bdebstrap}
    mkdir -p "$DEB_OUT_DIR"
    DST=${DEB_OUT_DIR}/$DEBPKG
    mv -f $PKG.deb $DST
    echo "I: $0: Made $(realpath $DST) from ${ta_src_dir} and ${rules_src_dir}"

    rm -rf "$PKG"
}

export topdir="${NEXUS_ROOT:-$(git rev-parse --show-toplevel)}"

# Parse args
ARGS=$(getopt --options='' --longoptions=repo:,ubootonly --name "$0" -- "$@") || exit 1
eval set -- "$ARGS"
unset ARGS
while :; do
    case "$1" in
    --repo)         shift;; # Ignore
    --ubootonly)    ubootonly=1;;
    --)             shift; break;;
    *)              echo Cannot parse "$1"; exit 1;;
    esac
    shift
done

source ${topdir}/scripts/setup.sh
source ${topdir}/scripts/common.sh
source ${topdir}/scripts/build_bsp.sh
source ${topdir}/scripts/build_distroiGOS.sh

if [ "$EUID" -ne 0 ] ; then
    echo "Failed to run: requires root privileges"
    echo "Exiting"
    exit 1
fi

# exit if no arguments are passed
if [ "$#" -ne 0 ]; then
    builds="$@"
else
    echo "build.sh: missing operand"
    echo "Specify one or more builds from the \"builds.toml\" file."
    exit 1
fi

mkdir -p ${topdir}/build

for build in ${builds}
do

    echo "${build}"

    validate_section "Build" ${build} "${topdir}/builds.toml"

    machine=($(read_build_config ${build} machine))
    distro_codename=($(read_build_config ${build} distro_codename))
    rt_linux=($(read_build_config ${build} rt_linux))

    if [ ${rt_linux} == "true" ]; then
        distro=${distro_codename}-rt-${machine}
    else
        distro=${distro_codename}-${machine}
    fi

    bsp_version=($(read_bsp_config ${distro} bsp_version))

    export host_arch=`uname -m`
    export native_build=false
    export cross_compile=aarch64-none-linux-gnu-
    if [ "$host_arch" == "aarch64" ]; then
        native_build=true
        cross_compile=
    fi

    echo "machine: ${machine}"
    echo "bsp_version: ${bsp_version}"
    echo "distro: ${distro}"
    echo "host_arch: ${host_arch}"

    setup_build_tools

    setup_log_file "${build}"

    validate_build ${machine} ${bsp_version} ${distro_codename}/${distro}.yaml

    #generate_rootfs ${distro} ${distro_codename} ${machine} ${bsp_version}

    uboot=${topdir}/build/${distro}/tisdk-debian-${distro}-${bsp_version}-boot
    ubootfile=$uboot/u-boot.img

    # Build BSP when either u-boot payload or OP-TEE runtime/asset inputs are missing.
    # This guarantees --ubootonly can emit BOTH:
    #   - u-boot_<ver>_<arch>.deb
    #   - optee-tpm-assets_<ver>_all.deb
    optee_dir=${topdir}/build/${distro}/bsp_sources/optee_os
    rt_rootfs=${topdir}/build/${distro}/tisdk-debian-${distro}-${bsp_version}-rootfs
    ta_glob=${optee_dir}/out/arm-plat-k3/export-ta_arm64/ta/*.ta
    rules_glob=${optee_dir}/optee_client/tee-supplicant/*.rules
    rules_tpl_glob=${optee_dir}/optee_client/tee-supplicant/*.rules.in
    supp_bin_rootfs=${rt_rootfs}/usr/sbin/tee-supplicant
    supp_bin_src=${optee_dir}/optee_client/tee-supplicant/tee-supplicant
    supp_unit_rootfs=${rt_rootfs}/usr/lib/systemd/system/tee-supplicant@.service
    supp_unit_src=${optee_dir}/optee_client/tee-supplicant/tee-supplicant@.service

    need_bsp_build=0
    if [ ! -f "$ubootfile" ]; then
        need_bsp_build=1
        echo "I: $0: build_bsp required - missing $ubootfile"
    fi
    if ! compgen -G "$ta_glob" > /dev/null; then
        need_bsp_build=1
        echo "I: $0: build_bsp required - missing TPM TA artifacts ($ta_glob)"
    fi
    if ! compgen -G "$rules_glob" > /dev/null && ! compgen -G "$rules_tpl_glob" > /dev/null; then
        need_bsp_build=1
        echo "I: $0: build_bsp required - missing tee-supplicant rules ($rules_glob or $rules_tpl_glob)"
    fi
    if [ ! -f "$supp_bin_rootfs" ] && [ ! -f "$supp_bin_src" ]; then
        need_bsp_build=1
        echo "I: $0: build_bsp required - missing tee-supplicant binary"
    fi
    if [ ! -f "$supp_unit_rootfs" ] && [ ! -f "$supp_unit_src" ]; then
        need_bsp_build=1
        echo "I: $0: build_bsp required - missing tee-supplicant service unit"
    fi

    if [ "$need_bsp_build" -eq 1 ]; then
        rm -rf "$uboot"
        echo "I: $0: running build_bsp ${distro} ${machine} ${bsp_version}"
        build_bsp ${distro} ${machine} ${bsp_version}
    else
        echo "I: $0: skipping build_bsp - uboot and TPM asset inputs already present"
    fi
    mkdeb $uboot
    mkdeb_tpm_assets

    if [ "$ubootonly" = 1 ]; then
        echo "I: $0: skipping package_and_clean because of --ubootonly"
    else
        FS=${topdir}/build/fs
        if [ -d "$FS" ]; then
            echo "I: $0: running package_and_clean ${distro} ${bsp_version}"
            # Note: this deletes the above $uboot
            package_and_clean ${distro} ${bsp_version}
        else
            echo "E: $0: $FS missing; cannot run package_and_clean"
            exit 2
        fi
    fi

done
