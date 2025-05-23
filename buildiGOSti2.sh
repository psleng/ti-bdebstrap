#!/bin/bash
# Filename: build.sh
# Author: "Sai Sree Kartheek Adivi <s-adivi@ti.com>"
# Description: Script to build a Debian SD card image for TI Platforms
###############################################################################

# set -x

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
    DST=${topdir}/ti-bdebstrap/$DEBPKG
    mv -f $PKG.deb $DST
    echo "I: $0: Made $(realpath $DST) from $dir"
    # lintian $DEBPKG

    rm -rf "$PKG"
}

export topdir=$(git rev-parse --show-toplevel)

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
    if [ -d $uboot ]; then
        echo "I: $0: skipping build_bsp since $uboot present"
    else
        echo "I: $0: running build_bsp ${distro} ${machine} ${bsp_version}"
        build_bsp ${distro} ${machine} ${bsp_version}
    fi
    mkdeb $uboot

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

