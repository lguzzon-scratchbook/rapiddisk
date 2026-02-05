#!/bin/bash

rapiddisk_Install() {
    local -r PRIMARY_DEV_TO_CACHE="${1-}"
    local -r DEV_TO_CACHE="/dev/${PRIMARY_DEV_TO_CACHE}"
    local -r HOST_MEMORY=$(free -k | grep 'Mem:' | awk '{print $2}')
    echo "HOST_MEMORY ${HOST_MEMORY} KB"
    # shellcheck disable=SC2017
    local -r RAMDISK_MEMORY=$((HOST_MEMORY / 5))
    echo "RAMDISK_MEMORY ${RAMDISK_MEMORY} KB"
    local -r RAMDISK_MAX_MEMORY=$((1024 * 1024 * 4))
    echo "RAMDISK_MAX_MEMORY ${RAMDISK_MAX_MEMORY} KB"
    RAMDISK_MEMORY_RAPIDDISK=$(((RAMDISK_MEMORY > RAMDISK_MAX_MEMORY ? RAMDISK_MAX_MEMORY : RAMDISK_MEMORY) / 1024))
    echo "RAMDISK_MEMORY_RAPIDDISK ${RAMDISK_MEMORY_RAPIDDISK} MB"
    (
        sudo dpkg --configure -a
        DEBIAN_FRONTEND=noninteractive sudo apt-get -y -qq -o Dpkg::Options::=--force-all -f install
        sudo rm -rf /var/lib/dpkg/lock-frontend
        sudo rm -rf /var/lib/dpkg/lock
        sudo rm -rf /var/cache/apt/archives/lock
        true
    ) \
        && sudo apt update \
        && (sudo apt -y install libpcre2-dev libdevmapper-dev libjansson-dev libmicrohttpd-dev || (sudo apt update && sudo apt -y install libpcre2-dev libdevmapper-dev libjansson-dev libmicrohttpd-dev)) \
        && ( (which git >/dev/null 2>&1) || sudo apt -y install git) \
        && ( (which make >/dev/null 2>&1) || sudo apt -y install binutils build-essential) \
        && sudo apt-mark unhold linux-image-* linux-headers-* linux-modules-* linux-modules-extra-* >/dev/null 2>&1 \
        && sudo apt -y install --reinstall "linux-image-$(uname -r)" "linux-headers-$(uname -r)" "linux-modules-$(uname -r)" "linux-modules-extra-$(uname -r)" \
        && sudo apt-mark hold linux-image-* linux-headers-* linux-modules-* linux-modules-extra-* >/dev/null 2>&1 \
        && ( ( ! (grep -q "dm-writecache" "/etc/modules") && echo "dm-writecache" >>"/etc/modules") || true) \
        && ( ( ! (grep -q "rapiddisk" "/etc/modules") && echo "rapiddisk" >>"/etc/modules") || true) \
        && ( ( ! (grep -q "rapiddisk-cache" "/etc/modules") && echo "rapiddisk-cache" >>"/etc/modules") || true) \
        && cd "$HOME" \
        && (rm -Rf rapiddisk || true) \
        && git clone -b lastWorking https://github.com/lguzzon-scratchbook/rapiddisk.git \
        && cd rapiddisk \
        && make \
        && make install \
        && cd scripts/rapiddisk-rootdev \
        && ( (
            [[ -n ${PRIMARY_DEV_TO_CACHE} ]] \
                && sed -i 's,PRIMARYDEVICE,'"${DEV_TO_CACHE}"',g' "./ubuntu/rapiddisk_sub_dev.orig" \
                && sed -i 's,rapiddisk_sub.orig,rapiddisk_sub_dev.orig,g' "./rapiddisk-on-boot" \
                && sed -i 's,rapiddisk_sub.orig,rapiddisk_sub_dev.orig,g' "./ubuntu/rapiddisk_hook"
        ) \
            || true) \
        && ./rapiddisk-on-boot --install --root="$(df | grep "/$" | sed 's/\([^ \t]\+\).*/\1/')" --size=${RAMDISK_MEMORY_RAPIDDISK} --kernel="$(uname -r)" --cache-mode=wb --force \
        && ( (
            [[ -n ${PRIMARY_DEV_TO_CACHE} ]] \
                && sed -i 's,'"${DEV_TO_CACHE}"',/dev/mapper/rc-wb_'"${PRIMARY_DEV_TO_CACHE}"',' /etc/fstab
        ) \
            || true) \
        && (for dmrc in /dev/mapper/rc-*; do
            echo "Flushing ${dmrc}"
            dmsetup message "${dmrc}" 0 flush
            dmsetup suspend "${dmrc}"
            dmsetup resume "${dmrc}"
            true
        done || true) \
        && (
            (nohup shutdown -r now &)
            exit 0
        )
}

rapiddisk_Install "$@"
