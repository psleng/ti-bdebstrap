#!/bin/bash

ROOT_DIR=$(dirname $(dirname $0))
DEFS_FILE=".defs.mk"

. ${ROOT_DIR}/${DEFS_FILE}
if [ "$BUILDTYPE" = "bookworm-am64xx-evm" ]; then
    ARM_A_CORE=a53
elif [ "$BUILDTYPE" = "bookworm-j7200-evm" ]; then
    ARM_A_CORE=a72
elif [ "$BUILDTYPE" = "bookworm-am64xx-iolan" ]; then
    ARM_A_CORE=a53
else
    echo "=== E: $0: Undefined BUILDTARG:BUILDTYPE ($BUILDTARG:$BUILDTYPE)"
    exit 1
fi

function build_bsp() {
build=$1
machine=$2
bsp_version=$3

    setup_bsp_build ${build} ${machine} ${bsp_version}
    build_atf $machine ${bsp_version}
    build_optee $machine ${bsp_version}
    build_uboot $machine ${bsp_version}
}

function setup_bsp_build() {
build=$1
machine=$2
bsp_version=$3

    mkdir -p ${topdir}/build/${build}/bsp_sources; cd ${topdir}/build/${build}/bsp_sources

    log "> BSP sources: checking .."

    if [ ! -d trusted-firmware-a ]; then
        cd ${topdir}/build/${build}/bsp_sources
        log ">> atf: not found. cloning .."
        atf_srcrev=($(read_bsp_config ${bsp_version} atf_srcrev))

        git clone https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git &>>"${LOG_FILE}"

        cd trusted-firmware-a
        git checkout ${atf_srcrev} &>>"${LOG_FILE}"
        cd ..
        log ">> atf: cloned"
    else
        log ">> atf: available"
    fi
    TFA_DIR=${topdir}/build/${build}/bsp_sources/trusted-firmware-a

    if [ ! -d optee_os ]; then
        cd ${topdir}/build/${build}/bsp_sources
        log ">> optee_os: not found. cloning .."
        optee_srcrev=($(read_bsp_config ${bsp_version} optee_srcrev))
        # optee_srcrev=4.5.0

        git clone https://github.com/psleng/optee_os.git &>>"${LOG_FILE}"

        cd optee_os
        git checkout ${optee_srcrev} &>>"${LOG_FILE}"
        cd ..
        log ">> optee_os: cloned"
    else
        log ">> optee_os: already available"
    fi
    OPTEE_DIR=${topdir}/build/${build}/bsp_sources/optee_os

    cd ${OPTEE_DIR}
    if [ ! -d optee_client ]; then
        log ">> optee_client: not found. cloning .."
        client_srcrev=($(read_bsp_config ${bsp_version} client_srcrev))
        # client_srcrev=4.5.0

        git clone https://github.com/psleng/optee_client.git &>>"${LOG_FILE}"

        cd optee_client
        git checkout ${client_srcrev} &>>"${LOG_FILE}"
        log ">> optee_client: cloned"
    else
        log ">> optee_client: already available"
    fi
    # PERLE copy updates for our build
    # cp ${topdir}/updates/optee-os/optee_client/* ${OPTEE_DIR}/optee_client
    # cp ${topdir}/updates/optee-os/optee_client/tee-supplicant/* ${OPTEE_DIR}/optee_client/tee-supplicant
    OPTEE_CLIENT_DIR=${OPTEE_DIR}/optee_client

    cd ${OPTEE_DIR}/ta
    if [ ! -d optee_ftpm ]; then
        # cd ${topdir}/build/${build}/bsp_sources
        log ">> optee_ftpm: not found. cloning .."
        # ftpm_srcrev=6f99e783eb9bb57c314a881433d4ec970de87959
        ftpm_srcrev=($(read_bsp_config ${bsp_version} ftpm_srcrev))

        git clone https://github.com/psleng/optee_ftpm.git &>>"${LOG_FILE}"

        cd optee_ftpm
        git checkout ${ftpm_srcrev} &>>"${LOG_FILE}"
        log ">> optee_ftpm: cloned"
    else
        log ">> optee_ftpm: already available"
    fi
    # PERLE copy updates for our build
    # cp ${topdir}/updates/optee-os/ta/optee_ftpm/* ${OPTEE_DIR}/ta/optee_ftpm
    # cp ${topdir}/updates/optee-os/ta/optee_ftpm/platform/include/* ${OPTEE_DIR}/ta/optee_ftpm/platform/include
    # OPTEE_FTPM_DIR=${OPTEE_DIR}/ta/optee_ftpm

    cd ${OPTEE_DIR}/ta
    if [ ! -d ms-tpm-20-ref ]; then
        log ">> ms-tpm-20-ref: not found. cloning .."
        # ms_tpm_srcrev=98b60a44aba79b15fcce1c0d1e46cf5918400f6a
        ms_tpm_srcrev=($(read_bsp_config ${bsp_version} ms_tpm_srcrev))

        git clone https://github.com/psleng/ms-tpm-20-ref.git &>>"${LOG_FILE}"

        cd ms-tpm-20-ref
        git checkout ${ms_tpm_srcrev} &>>"${LOG_FILE}"
        log ">> ms-tpm-20-ref: cloned"
    else
        log ">> ms-tpm-20-ref: already available"
    fi
    # PERLE copy updates for our build
    # cp ${topdir}/updates/optee-os/ta/ms-tpm-20-ref/TPMCmd/tpm/include/* ${OPTEE_DIR}/ta/ms-tpm-20-ref/TPMCmd/tpm/include
    MS_TPM_20_DIR=${OPTEE_DIR}/ta/ms-tpm-20-ref

    cd ${topdir}/build/${build}/bsp_sources

    if [ ! -d ti-u-boot ]; then
        cd ${topdir}/build/${build}/bsp_sources
        log ">> ti-u-boot: not found. cloning .."
        uboot_srcrev=($(read_bsp_config ${bsp_version} uboot_srcrev))
        git clone \
            https://git.ti.com/git/ti-u-boot/ti-u-boot.git \
            -b ${uboot_srcrev} \
            --single-branch \
            --depth=1 &>>"${LOG_FILE}"
        log ">> ti-u-boot: cloned"
        if [ -d ${topdir}/ti-bdebstrap/patches/$BUILDTYPE/ti-u-boot ]; then
            log ">> ti-u-boot: patching .."
            cd ti-u-boot
            git apply ${topdir}/ti-bdebstrap/patches/$BUILDTYPE/ti-u-boot/* &>>"${LOG_FILE}"
            cd ..
        fi
    else
        log ">> ti-u-boot: available"
    fi
    UBOOT_DIR=${topdir}/build/${build}/bsp_sources/ti-u-boot

    if [ ! -d ti-linux-firmware ]; then
        cd ${topdir}/build/${build}/bsp_sources
        log ">> ti-linux-firmware: not found. cloning .."
        linux_fw_srcrev=($(read_bsp_config ${bsp_version} linux_fw_srcrev))
        git clone \
            https://git.ti.com/git/processor-firmware/ti-linux-firmware.git \
            -b ${linux_fw_srcrev} \
            --single-branch \
            --depth=1 &>>"${LOG_FILE}"
        log ">> ti-linux-firmware: cloned"
    else
        log ">> ti-linux-firmware: available"
    fi
    FW_DIR=${topdir}/build/${build}/bsp_sources/ti-linux-firmware

    log "> BSP sources: cloned"
    log "> BSP sources: creating backup .."
    cd ${topdir}/build/${build}
    tar --use-compress-program="pigz --best --recursive | pv" -cf bsp_sources.tar.xz bsp_sources &>>"${LOG_FILE}"
    log "> BSP sources: backup created .."

    mkdir -p tisdk-debian-${distro}-${bsp_version}-boot
}

function build_atf() {
machine=$1
bsp_version=$2

    cd $TFA_DIR
    target_board=($(read_machine_config ${machine} atf_target_board ${bsp_version}))
    make_args=($(read_machine_config ${machine} atf_make_args ${bsp_version}))

    log "> ATF: building .."
    make -j`nproc` ARCH=aarch64 CROSS_COMPILE=${cross_compile} PLAT=k3 TARGET_BOARD=${target_board} SPD=opteed ${make_args} &>>"${LOG_FILE}"
}

function build_optee() {
machine=$1
bsp_version=$2

    platform=($(read_machine_config ${machine} optee_platform ${bsp_version}))
    make_args=($(read_machine_config ${machine} optee_make_args ${bsp_version}))
    # Workaround for toml not supporting empty values
    if [ ${make_args} == "." ]; then
        make_args=""
    fi

# PERLE added
    cd ${OPTEE_CLIENT_DIR}
    log "> optee_client: building .."
    cmake -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_INSTALL_PREFIX=${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-rootfs/usr &>>"${LOG_FILE}"
    make -j`nproc` CROSS_COMPILE64=${cross_compile} PLATFORM=${platform} CFG_TEE_CLIENT_LOG_LEVEL=3 CFG_TEE_SUPP_LOG_LEVEL=3 CFG_TA_DEBUG=y CFG_ARM64_CORE=y \
    ${make_args[*]} &>>"${LOG_FILE}"
    make install &>>"${LOG_FILE}"

    cd ${OPTEE_DIR}
    log "> optee: building .."

# PERLE modified
#    make -j`nproc` CROSS_COMPILE64=${cross_compile} CROSS_COMPILE=arm-none-linux-gnueabihf- PLATFORM=${platform} CFG_ARM64_core=y ${make_args[*]} &>>"${LOG_FILE}"

    make -j`nproc` CROSS_COMPILE64=${cross_compile} CROSS_COMPILE=arm-none-linux-gnueabihf- PLATFORM=${platform} TA_DEV_KIT_DIR=${OPTEE_DIR} CFG_TEE_CORE_DEBUG=y \
         CFG_TEE_TA_LOG_LEVEL=2 CFG_TA_MBEDTLS=y CFG_CRYPTO_SHA512=y CFG_CRYPTO_ECC=n CFG_MS_TPM_20_REF=${MS_TPM_20_DIR} BINARY=optee_ftpm CFG_ARM64_core=y \
         CFG_RPMB_FS=n CFG_REE_FS=y ta-targets=ta_arm64 ${make_args[*]} &>>"${LOG_FILE}"

# working REE_FS only      CFG_RPMB_FS=n CFG_REE_FS=y CFG_TEE_CORE_LOG_LEVEL=3 ta-targets=ta_arm64 ${make_args[*]} &>>"${LOG_FILE}"
# working RPMB only        CFG_RPMB_FS=y CFG_REE_FS=n CFG_RPMB_TESTKEY=y CFG_RPMB_WRITE_KEY=y CFG_TEE_CORE_LOG_LEVEL=3 ta-targets=ta_arm64 ${make_args[*]} &>>"${LOG_FILE}"

# PERLE added
    log "> optee_ftpm: copying TA files to rootfs"
    mkdir -p ${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-rootfs/usr/lib/firmware/optee &>> ${LOG_FILE}
    cp ${OPTEE_DIR}/out/arm-plat-k3/export-ta_arm64/ta/*.ta ${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-rootfs/usr/lib/firmware/optee/ &>> ${LOG_FILE}
    mkdir -p ${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-rootfs/etc/udev/rules.d &>> ${LOG_FILE}
    cp ${OPTEE_DIR}/optee_client/tee-supplicant/*.rules ${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-rootfs/etc/udev/rules.d/ &>> ${LOG_FILE}
    sudo cp ${topdir}/updates/openssl.cnf ${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-rootfs/etc/ssl/openssl.cnf &>> ${LOG_FILE}
}

function build_uboot() {
machine=$1
bsp_version=$2

    echo "Building uboot for machine variant: ${machine}"

    uboot_r5_defconfig=($(read_machine_config ${machine} uboot_r5_defconfig ${bsp_version}))
    uboot_r5_defconfig=`echo $uboot_r5_defconfig | tr ',' ' '`
    uboot_acore_defconfig=($(read_machine_config ${machine} uboot_${ARM_A_CORE}_defconfig ${bsp_version}))
    platform=($(read_machine_config ${machine} atf_target_board ${bsp_version}))

    cd ${UBOOT_DIR}

    # set output for normal build
    OUTDIR="${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-boot"

    log "> uboot-r5: building .."
    make -j`nproc` ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- ${uboot_r5_defconfig} O=${UBOOT_DIR}/out/r5 &>>"${LOG_FILE}"
    make -j`nproc` ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- O=${UBOOT_DIR}/out/r5 BINMAN_INDIRS=${FW_DIR} &>>"${LOG_FILE}"
    cp ${UBOOT_DIR}/out/r5/tiboot3*.bin ${OUTDIR}/ &>> ${LOG_FILE}

    cd ${UBOOT_DIR}
    log "> uboot-${ARM_A_CORE}: building .."
    make -j`nproc` ARCH=arm CROSS_COMPILE=${cross_compile} ${uboot_acore_defconfig} O=${UBOOT_DIR}/out/${ARM_A_CORE} &>>"${LOG_FILE}"
    make -j`nproc` ARCH=arm CROSS_COMPILE=${cross_compile} BL31=${TFA_DIR}/build/k3/${platform}/release/bl31.bin TEE=${OPTEE_DIR}/out/arm-plat-k3/core/tee-pager_v2.bin BINMAN_INDIRS=${FW_DIR} O=${UBOOT_DIR}/out/${ARM_A_CORE} &>>"${LOG_FILE}"
    cp ${UBOOT_DIR}/out/${ARM_A_CORE}/tispl.bin ${OUTDIR}/ &>> ${LOG_FILE}
    cp ${UBOOT_DIR}/out/${ARM_A_CORE}/u-boot.img ${OUTDIR}/ &>> ${LOG_FILE}

	case ${machine} in
		am62pxx-evm | am62xx-evm | am62xx-lp-evm | am62xxsip-evm)
			cp ${UBOOT_DIR}/tools/logos/ti_logo_414x97_32bpp.bmp.gz ${OUTDIR}/ &>> ${LOG_FILE}
			;;
	esac

    # PERLE - For the 2 evms, we need separate emmc output suffix and modify env file to use mmcdev 0 and fix loadbootenv bug
    # PERLE - Patching would between bootloader builds would be more cumbersome. Our target would not need this cluge
    case "$machine" in
        am64xx-evm | j7200-evm)
        # if not j7200, default to am642evm
        if [ "$machine" = "j7200-evm" ]; then
            ENV_PATH="board/ti/j721e"
            ENV_NAME="j721e"
        else
            ENV_PATH="board/ti/am64x"
            ENV_NAME="am64x"
        fi

        # save original env file to restore later
        cp ${ENV_PATH}/${ENV_NAME}.env ${ENV_PATH}/${ENV_NAME}.env.orig

        echo "Building emmc uboot variant for machine type: ${machine}"
        sed -i \
          -e 's/^mmcdev=1$/mmcdev=0/' \
          -e '/^bootpart=1:2$/ {
                s//bootpart=0:2/
                a loadbootenv=fatload mmc ${bootpart} ${loadaddr} ${bootenvfile}
              }' \
          ${ENV_PATH}/${ENV_NAME}.env
        # save a copy of the change so we can compare .orig to .emmc, if debugging
        cp ${ENV_PATH}/${ENV_NAME}.env ${ENV_PATH}/${ENV_NAME}.env.emmc

        OUTDIR="${topdir}/build/${build}/tisdk-debian-${distro}-${bsp_version}-boot-emmc"

        mkdir -p ${OUTDIR}

        log "> uboot-r5: building .."
        make -j`nproc` ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- ${uboot_r5_defconfig} O=${UBOOT_DIR}/out/r5 &>>"${LOG_FILE}"
        make -j`nproc` ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- O=${UBOOT_DIR}/out/r5 BINMAN_INDIRS=${FW_DIR} &>>"${LOG_FILE}"
        cp ${UBOOT_DIR}/out/r5/tiboot3*.bin ${OUTDIR}/ &>> ${LOG_FILE}

        cd ${UBOOT_DIR}
        log "> uboot-${ARM_A_CORE}: building .."
        make -j`nproc` ARCH=arm CROSS_COMPILE=${cross_compile} ${uboot_acore_defconfig} O=${UBOOT_DIR}/out/${ARM_A_CORE} &>>"${LOG_FILE}"
        make -j`nproc` ARCH=arm CROSS_COMPILE=${cross_compile} BL31=${TFA_DIR}/build/k3/${platform}/release/bl31.bin TEE=${OPTEE_DIR}/out/arm-plat-k3/core/tee-pager_v2.bin BINMAN_INDIRS=${FW_DIR} O=${UBOOT_DIR}/out/${ARM_A_CORE} &>>"${LOG_FILE}"
        cp ${UBOOT_DIR}/out/${ARM_A_CORE}/tispl.bin ${OUTDIR}/ &>> ${LOG_FILE}
        cp ${UBOOT_DIR}/out/${ARM_A_CORE}/u-boot.img ${OUTDIR}/ &>> ${LOG_FILE}

        # restore original env file, if debugging.  Normally, the entire bsp_sources are removed
        cp ${ENV_PATH}/${ENV_NAME}.env.orig ${ENV_PATH}/${ENV_NAME}.env
        ;;
    esac
}

