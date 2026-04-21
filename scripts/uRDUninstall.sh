#!/bin/bash

rapiddisk_Install() {
    local -r HOST_MEMORY=$(free -k | grep 'Mem:' | awk '{print $2}')
    echo "HOST_MEMORY ${HOST_MEMORY} KB"

    local -r RAMDISK_MEMORY=$((HOST_MEMORY / 5))
    echo "RAMDISK_MEMORY ${RAMDISK_MEMORY} KB"

    local -r RAMDISK_MAX_MEMORY=$((1024 * 1024 * 2))
    echo "RAMDISK_MAX_MEMORY ${RAMDISK_MAX_MEMORY} KB"

    local -r RAMDISK_SIZE=$((RAMDISK_MEMORY > RAMDISK_MAX_MEMORY ? RAMDISK_MAX_MEMORY : RAMDISK_MEMORY))
    local -r RAMDISK_SIZE_MB=$((RAMDISK_SIZE / 1024))
    echo "RAMDISK_SIZE ${RAMDISK_SIZE_MB} MB"

    local -r ROOT_DEV=$(df / | grep '/$' | awk '{print $1}')
    echo "ROOT_DEV ${ROOT_DEV}"

    local -r ROOT_DEV_NAME=$(basename "$ROOT_DEV")
    echo "ROOT_DEV_NAME ${ROOT_DEV_NAME}"

    local -r KERNEL_VERSION=$(uname -r)
    echo "KERNEL_VERSION ${KERNEL_VERSION}"

    local -r CACHE_MODE="wb"

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
        && git clone https://github.com/lguzzon-scratchbook/rapiddisk.git \
        && cd rapiddisk \
        && make \
        && make install

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to install rapiddisk"
        return 1
    fi

    local -r SOURCE_DIR="/home/suser/rapiddisk/scripts/rapiddisk-rootdev"
    local -r CONFIG_DIR="/etc/rapiddisk"
    local -r HOOKS_DIR="/usr/share/initramfs-tools/hooks"
    local -r SCRIPTS_DIR="/usr/share/initramfs-tools"
    local -r ALT_SCRIPTS_DIR="/usr/share/initramfs-tools/scripts/local-bottom"

    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi

    echo " - Installing initramfs hooks..."
    cp -f "${SOURCE_DIR}/ubuntu/rapiddisk_hook" "${HOOKS_DIR}/rapiddisk_hook"
    chmod +x "${HOOKS_DIR}/rapiddisk_hook"

    cp -f "${SOURCE_DIR}/ubuntu/rapiddisk_boot" "${SCRIPTS_DIR}/rapiddisk_boot"
    chmod +x "${SCRIPTS_DIR}/rapiddisk_boot"

    cp -f "${SOURCE_DIR}/ubuntu/rapiddisk_sub.orig" "${CONFIG_DIR}/rapiddisk_sub.orig"
    chmod -x "${CONFIG_DIR}/rapiddisk_sub.orig"

    cp -f "${SOURCE_DIR}/ubuntu/rapiddisk_clean" "${ALT_SCRIPTS_DIR}/rapiddisk_clean"
    chmod +x "${ALT_SCRIPTS_DIR}/rapiddisk_clean"

    local -r KERNEL_VERSION_FILE="rapiddisk_kernel_${KERNEL_VERSION}"
    echo "${RAMDISK_SIZE_MB}" > "${CONFIG_DIR}/${KERNEL_VERSION_FILE}"
    echo "${ROOT_DEV}" >> "${CONFIG_DIR}/${KERNEL_VERSION_FILE}"
    echo "${CACHE_MODE}" >> "${CONFIG_DIR}/${KERNEL_VERSION_FILE}"

    sed -i 's,RAMDISKSIZE,'"$RAMDISK_SIZE_MB"',g' "${CONFIG_DIR}/rapiddisk_sub.orig"
    sed -i 's,BOOTDEVICE,'"$ROOT_DEV"',g' "${CONFIG_DIR}/rapiddisk_sub.orig"
    sed -i 's,CACHEMODE,'"$CACHE_MODE"',g' "${CONFIG_DIR}/rapiddisk_sub.orig"

    echo " - Updating initramfs for kernel version ${KERNEL_VERSION}..."
    update-initramfs -u -k "$KERNEL_VERSION"

    echo "Installation complete. A reboot is required."
    echo "After reboot, run: sudo rapiddisk --verify"

    echo ""
    echo "Configuration summary:"
    echo "  RAM disk size: ${RAMDISK_SIZE_MB} MB"
    echo "  Root device: ${ROOT_DEV}"
    echo "  Cache mode: ${CACHE_MODE}"
    echo "  Kernel: ${KERNEL_VERSION}"

    (
        nohup shutdown -r now &
        exit 0
    )
}

rapiddisk_Verify() {
    echo "=== Verifying rapiddisk installation ==="

    echo ""
    echo "1. Checking kernel modules..."
    local MODULES_LOADED=0
    if lsmod | grep -q "^rapiddisk "; then
        echo "   [OK] rapiddisk module loaded"
        MODULES_LOADED=$((MODULES_LOADED + 1))
    else
        echo "   [FAIL] rapiddisk module not loaded"
    fi

    if lsmod | grep -q "^rapiddisk_cache "; then
        echo "   [OK] rapiddisk_cache module loaded"
        MODULES_LOADED=$((MODULES_LOADED + 1))
    else
        echo "   [FAIL] rapiddisk_cache module not loaded"
    fi

    if lsmod | grep -q "^dm_writecache "; then
        echo "   [OK] dm-writecache module loaded"
        MODULES_LOADED=$((MODULES_LOADED + 1))
    else
        echo "   [FAIL] dm-writecache module not loaded"
    fi

    if [ $MODULES_LOADED -ne 3 ]; then
        echo "   [WARN] Not all required modules are loaded"
    fi

    echo ""
    echo "2. Checking /etc/modules configuration..."
    if grep -q "rapiddisk" /etc/modules && grep -q "rapiddisk-cache" /etc/modules && grep -q "dm-writecache" /etc/modules; then
        echo "   [OK] All modules configured in /etc/modules"
    else
        echo "   [WARN] Not all modules configured in /etc/modules"
    fi

    echo ""
    echo "3. Checking rapiddisk binary..."
    if which rapiddisk >/dev/null 2>&1; then
        local RD_VERSION=$(rapiddisk -v 2>&1 | head -n 1)
        echo "   [OK] rapiddisk installed: $RD_VERSION"
    else
        echo "   [FAIL] rapiddisk binary not found"
        return 1
    fi

    echo ""
    echo "4. Checking RAM disk devices..."
    local RD_DEVICES=$(sudo rapiddisk -l -g 2>&1 | grep -c "rd[0-9]" || true)
    RD_DEVICES=${RD_DEVICES:-0}
    if [ "$RD_DEVICES" -gt 0 ] 2>/dev/null; then
        echo "   [OK] $RD_DEVICES RAM disk device(s) attached"
        sudo rapiddisk -l -g
    else
        echo "   [WARN] No RAM disk devices attached"
    fi

    echo ""
    echo "5. Checking cache mappings..."
    local CACHE_MAPPINGS
    CACHE_MAPPINGS=$(sudo ls -la /dev/mapper/ 2>/dev/null | grep -c "rc-" || true)
    CACHE_MAPPINGS=${CACHE_MAPPINGS:-0}
    if [ "$CACHE_MAPPINGS" -gt 0 ] 2>/dev/null; then
        echo "   [OK] $CACHE_MAPPINGS cache mapping(s) active"
        sudo ls -la /dev/mapper/ | grep "rc-"
    else
        echo "   [WARN] No cache mappings found in /dev/mapper/"
    fi

    echo ""
    echo "6. Checking initramfs configuration..."
    local KERNEL_VERSION=$(uname -r)
    local CONFIG_DIR="/etc/rapiddisk"
    local KERNEL_VERSION_FILE="${CONFIG_DIR}/rapiddisk_kernel_${KERNEL_VERSION}"

    if [ -f "$KERNEL_VERSION_FILE" ]; then
        echo "   [OK] Kernel config found for ${KERNEL_VERSION}"
        echo "   Configuration:"
        cat "$KERNEL_VERSION_FILE" | while read -r line; do
            echo "      $line"
        done
    else
        echo "   [WARN] No kernel config found for ${KERNEL_VERSION}"
    fi

    echo ""
    echo "=== Verification complete ==="

    RD_DEVICES=${RD_DEVICES:-0}
    CACHE_MAPPINGS=$(sudo ls -la /dev/mapper/ 2>/dev/null | grep -c "rc-" || true)
    CACHE_MAPPINGS=${CACHE_MAPPINGS:-0}

    if [ "$RD_DEVICES" -gt 0 ] 2>/dev/null && [ "$CACHE_MAPPINGS" -gt 0 ] 2>/dev/null; then
        echo "Status: FULLY CONFIGURED"
        return 0
    elif [ "$RD_DEVICES" -gt 0 ] 2>/dev/null; then
        echo "Status: PARTIALLY CONFIGURED (RAM disk present, but no cache mapping)"
        return 0
    else
        echo "Status: NOT CONFIGURED (reboot required or installation failed)"
        return 1
    fi
}

case "${1:-}" in
    --verify)
        rapiddisk_Verify
        ;;
    *)
        rapiddisk_Install "$@"
        ;;
