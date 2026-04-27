#!/bin/bash
# install-rapiddisk-root.sh - Install rapiddisk cache on root device
# Cache size = 1/5 of system memory (capped at 2GB maximum)
# Cache mode: write-back (wb) if 4k-aligned, otherwise write-through (wt)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAPIDDISK_BOOT="${RAPIDDISK_BOOT:-${SCRIPT_DIR}/rapiddisk-rootdev/rapiddisk-on-boot}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
DETECTED_ALIGNMENT_VALUE=""

log() {
    local level=$1
    local msg=$2
    case $level in
        ERR) echo -e "${RED}ERROR: $msg${NC}" >&2; exit 1 ;;
        INF) echo -e "${GREEN}INFO: $msg${NC}" >&2 ;;
        WRN) echo -e "${YELLOW}WARN: $msg${NC}" >&2 ;;
    esac
}

check_root() {
    if (( EUID != 0 )); then
        if sudo -n true 2>/dev/null; then
            exec sudo "$0" "$@"
        else
            log ERR "This script must be run as root"
        fi
    fi
}

get_system_memory() {
    echo $(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
}

calculate_cache_size() {
    local total_mem=$(get_system_memory)
    local cache_size=$((total_mem / 5))
    (( cache_size > 2048 )) && { cache_size=2048; log INF "Cache size limited to 2048MB (2GB maximum)"; }
    (( cache_size < 100 )) && { cache_size=100; log WRN "Cache size increased to minimum 100MB"; }
    echo "$cache_size"
}

resolve_device() {
    local dev="$1"
    if [[ "$dev" == UUID=* ]]; then
        local uuid="${dev#UUID=}"
        dev=$(readlink -f "/dev/disk/by-uuid/$uuid" 2>/dev/null) || log ERR "Could not resolve UUID '$uuid'"
    elif [[ "$dev" == LABEL=* ]]; then
        local label="${dev#LABEL=}"
        dev=$(readlink -f "/dev/disk/by-label/$label" 2>/dev/null) || log ERR "Could not resolve LABEL '$label'"
    elif [[ "$dev" == /dev/disk/by-uuid/* ]]; then
        dev=$(readlink -f "$dev" 2>/dev/null) || log ERR "Could not resolve device '$dev'"
    elif [[ "$dev" == /dev/disk/by-label/* ]]; then
        dev=$(readlink -f "$dev" 2>/dev/null) || log ERR "Could not resolve device '$dev'"
    fi
    [[ -b "$dev" ]] || log ERR "Device '$dev' does not exist or is not a block device"
    echo "$dev"
}

detect_root_device() {
    local root_dev
    root_dev=$(grep -vE '^[[:space:]]*#' /etc/fstab 2>/dev/null | grep -E '[[:space:]]+/[[:space:]]' | awk '{print $1}')
    [[ -z "$root_dev" ]] && root_dev=$(awk '$2 == "/" {print $1}' /proc/mounts | head -1)
    [[ -z "$root_dev" ]] && log ERR "Could not detect root device automatically"
    resolve_device "$root_dev"
}

check_alignment() {
    local dev="$1"

    # Method 1: Use sysfs (most reliable) - check /sys/block/DEVICE/PARTITION/start
    local dev_name="${dev#/dev/}"
    local sysfs_start="/sys/block/${dev_name%%[0-9]*}/${dev_name}/start"

    if [[ -f "$sysfs_start" ]]; then
        local start_sector=$(< "$sysfs_start")
        local logical_size=512
        local start_byte=$((start_sector * logical_size))

        DETECTED_ALIGNMENT_VALUE="sysfs:start:$start_sector:byte:$start_byte"

        if (( start_byte % 4096 == 0 )); then
            log INF "Partition starts at sector $start_sector (byte $start_byte) - 4k-aligned"
            return 0
        else
            local offset=$((start_byte % 4096))
            log WRN "Partition starts at sector $start_sector (byte $start_byte) - offset ${offset} from 4k boundary"
            return 1
        fi
    fi

    # Method 2: Fallback to lsblk
    local start_sector=$(lsblk -no START "$dev" 2>/dev/null | head -1 || echo "")
    if [[ -n "$start_sector" && "$start_sector" =~ ^[0-9]+$ ]]; then
        DETECTED_ALIGNMENT_VALUE="lsblk:$start_sector"
        if (( start_sector % 8 == 0 )); then
            log INF "Partition starts at sector $start_sector (4k-aligned)"
            return 0
        else
            log WRN "Partition starts at sector $start_sector (not 4k-aligned)"
            return 1
        fi
    fi

    # Method 3: Fallback to blockdev sector size
    local sector_size=$(blockdev --getss "$dev" 2>/dev/null || echo "")
    if [[ -n "$sector_size" && "$sector_size" =~ ^[0-9]+$ ]]; then
        DETECTED_ALIGNMENT_VALUE="blockdev:$sector_size"
        if (( sector_size == 4096 )); then
            log INF "Detected 4096-byte sectors (4k-aligned)"
            return 0
        elif (( sector_size == 512 )); then
            log WRN "Detected 512-byte sectors (not 4k-aligned)"
            return 1
        fi
    fi

    DETECTED_ALIGNMENT_VALUE=""
    log WRN "Could not determine alignment for $dev"
    return 2
}

get_cache_mode() {
    local dev="$1"
    check_alignment "$dev"
    case $? in
        0) log INF "✓ 4k-aligned - using write-back (wb)"; echo "wb" ;;
        1) log WRN "✗ Not 4k-aligned - using write-through (wt)"; echo "wt" ;;
        2) log WRN "⚠ Alignment unknown - using write-through (wt)"; echo "wt" ;;
    esac
}

check_rapiddisk_built() {
    if command -v rapiddisk &>/dev/null; then
        # Verify system-wide binary exists (required for initramfs hook)
        local system_binary=false
        for binary_path in /usr/sbin/rapiddisk /usr/local/sbin/rapiddisk /sbin/rapiddisk /usr/bin/rapiddisk; do
            if [[ -x "$binary_path" ]]; then
                system_binary=true
                break
            fi
        done

        if [[ "$system_binary" == "true" ]]; then
            log INF "rapiddisk command found in system location"
            return 0
        else
            log WRN "rapiddisk command found via PATH but not in system directory"
            log WRN "System installation needed for initramfs hook"
        fi
    fi

    local project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    local rapiddisk_bin="$project_root/src/rapiddisk"

    if [[ -x "$rapiddisk_bin" ]]; then
        export PATH="$project_root/src:$PATH"
        log INF "Local rapiddisk binary found, but system installation required for boot"
        log INF "Will trigger rebuild/install to ensure system-wide availability"
        return 1  # Return 1 to trigger build/install
    fi

    return 1
}

install_dependencies() {
    local pkg_manager=""
    local packages=()

    # Detect package manager
    if command -v apt-get &>/dev/null; then
        pkg_manager="apt"
        packages+=("build-essential" "libpcre2-dev" "pcre2-utils" "libjansson-dev" "libdevmapper-dev" "libmicrohttpd-dev")
        [[ ! -d "/lib/modules/$(uname -r)/build" ]] && packages+=("linux-headers-$(uname -r)")
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        packages+=("gcc" "make" "pcre2-devel" "pcre2-tools" "jansson-devel" "device-mapper-devel" "libmicrohttpd-devel")
        [[ ! -d "/lib/modules/$(uname -r)/build" ]] && packages+=("kernel-devel")
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
        packages+=("gcc" "make" "pcre2-devel" "pcre2-tools" "jansson-devel" "device-mapper-devel" "libmicrohttpd-devel")
        [[ ! -d "/lib/modules/$(uname -r)/build" ]] && packages+=("kernel-devel")
    else
        log WRN "No supported package manager found (apt/dnf/yum)"
        return 1
    fi

    if [[ ${#packages[@]} -eq 0 ]]; then
        log INF "All dependencies already installed"
        return 0
    fi

    log INF "Installing dependencies: ${packages[*]}"
    case "$pkg_manager" in
        apt)
            if ! apt-get update -qq; then
                log WRN "apt-get update failed, continuing..."
            fi
            apt-get install -y "${packages[@]}"
            ;;
        dnf|yum)
            "$pkg_manager" install -y "${packages[@]}"
            ;;
    esac
}

build_rapiddisk() {
    local project_root="$(cd "$SCRIPT_DIR/.." && pwd)"

    log INF "rapiddisk not found - building from source..."
    log INF "Project root: $project_root"

    cd "$project_root" || log ERR "Cannot change to project root"

    log INF "Installing build dependencies..."
    install_dependencies

    local make_targets=("install")
    local dependencies_missing=()

    # Check for module build dependencies
    [[ ! -d "/lib/modules/$(uname -r)/build" ]] && dependencies_missing+=("kernel headers for $(uname -r)")

    if [[ ${#dependencies_missing[@]} -gt 0 ]]; then
        log WRN "Missing dependencies: ${dependencies_missing[*]}"
        log WRN "Falling back to tools-only build (rapiddisk command only)"
        make_targets=("tools-install")
    fi

    for target in "${make_targets[@]}"; do
        log INF "Running: make $target"
        if ! make "$target"; then
            log ERR "Build failed. Install dependencies manually or use package manager."
        fi
    done

    # Verify binary installed to system location (needed for initramfs hook)
    local binary_found=false
    for binary_path in /usr/sbin/rapiddisk /usr/local/sbin/rapiddisk /sbin/rapiddisk; do
        if [[ -x "$binary_path" ]]; then
            binary_found=true
            log INF "rapiddisk binary installed to: $binary_path"
            break
        fi
    done

    if [[ "$binary_found" == "false" ]]; then
        log ERR "rapiddisk binary not found in system directory after 'make install'."
        log ERR "The initramfs hook requires rapiddisk in /sbin or /usr/sbin."
        log ERR "Check Makefile installation paths and try again."
    fi

    # Re-check if rapiddisk command is now available system-wide
    if ! command -v rapiddisk &>/dev/null; then
        # Update PATH to include common locations
        export PATH="/usr/sbin:/usr/local/sbin:/sbin:$PATH"
        if ! command -v rapiddisk &>/dev/null; then
            log ERR "rapiddisk command still not available after install. Check installation."
        fi
    fi

    cd - >/dev/null || true
    log INF "rapiddisk built successfully"
}

check_prerequisites() {
    log INF "Checking prerequisites..."

    check_rapiddisk_built || build_rapiddisk
    command -v rapiddisk &>/dev/null || log ERR "rapiddisk command not available after build"

    [[ -x "$RAPIDDISK_BOOT" ]] || log ERR "rapiddisk-on-boot not found at: $RAPIDDISK_BOOT"
    [[ -f /etc/os-release ]] || log ERR "Rapiddisk-on-boot requires /etc/os-release for OS detection"

    local os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    case "$os_id" in
        ubuntu|debian|centos|rhel|fedora|almalinux|rocky) log INF "Detected OS: $os_id" ;;
        *) log WRN "OS '$os_id' may not be fully supported. Continuing..." ;;
    esac
    log INF "Prerequisites check passed"
}

check_uninstall_prerequisites() {
    log INF "Checking uninstall prerequisites..."

    [[ -x "$RAPIDDISK_BOOT" ]] || log ERR "rapiddisk-on-boot not found at: $RAPIDDISK_BOOT"
    log INF "Uninstall prerequisites check passed"
}

show_disk_info() {
    local root_device="$1"
    local root_fs_size
    local root_fs_type

    root_fs_size=$(df -h / | awk 'NR==2 {print $2}')
    root_fs_type=$(df -T / | awk 'NR==2 {print $2}')

    cat << EOF

========================================
Disk Information:
========================================
Root Device:    $root_device
Root Size:      $root_fs_size
Root Type:      $root_fs_type

Other Disks:
EOF

    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -rn | while read -r name size type mountpoint; do
        if [[ "$mountpoint" == "/" ]]; then
            continue
        fi
        if [[ -n "$mountpoint" && "$type" != "rom" && "$type" != "part" ]]; then
            local fs_type
            fs_type=$(df -T "$mountpoint" 2>/dev/null | awk 'NR==2 {print $2}' || echo "-")
            printf "  %-15s %-10s %-12s %s\n" "$name" "$size" "$fs_type" "$mountpoint"
        fi
    done

    echo "========================================"
}

install_rapiddisk() {
    log INF "Starting rapiddisk installation on root device..."

    local cache_size=$(calculate_cache_size)
    local kernel_version=$(uname -r)
    local root_device=$(detect_root_device)
    local cache_mode=$(get_cache_mode "$root_device")

    show_disk_info "$root_device"

    cat << EOF

========================================
Cache Configuration:
========================================
Cache Size:     ${cache_size}MB
Cache Mode:     ${cache_mode}
Kernel Version: $kernel_version
========================================

EOF

    read -rp "Proceed with installation? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log INF "Installation cancelled"; exit 0; }

    log INF "Running rapiddisk-on-boot installation..."
    local args=(--install --root="$root_device" --size="$cache_size" --cache-mode="$cache_mode" --kernel="$kernel_version")
    [[ "${FORCE:-false}" == "true" ]] && args+=(--force)
    "$RAPIDDISK_BOOT" "${args[@]}"

    cat << EOF
${GREEN}Installation completed successfully!
A REBOOT IS REQUIRED to activate rapiddisk.

After reboot, verify with:
  sudo $(basename "$0") --verify
  rapiddisk -l
  rapiddisk -s

To uninstall:
  sudo $(basename "$0") --uninstall
EOF
}

uninstall_rapiddisk() {
    local kernel_version=$(uname -r)
    log INF "Uninstalling rapiddisk for kernel $kernel_version..."
    local args=(--uninstall --kernel="$kernel_version")
    [[ "${FORCE:-false}" == "true" ]] && args+=(--force)
    "$RAPIDDISK_BOOT" "${args[@]}"
    log INF "Uninstall completed. A reboot is recommended."
}

global_uninstall() {
    log INF "Global uninstall of rapiddisk-on-boot..."
    local args=(--global-uninstall)
    [[ "${FORCE:-false}" == "true" ]] && args+=(--force)
    "$RAPIDDISK_BOOT" "${args[@]}"
    log INF "Global uninstall completed. A reboot is recommended."
}

show_alignment_info() {
    cat << EOF

========================================
Root Filesystem Alignment Check
========================================

EOF
    local root_dev
    root_dev=$(grep -vE '^[[:space:]]*#' /etc/fstab 2>/dev/null | grep -E '[[:space:]]+/[[:space:]]' | awk '{print $1}')
    [[ -z "$root_dev" ]] && root_dev=$(awk '$2 == "/" {print $1}' /proc/mounts | head -1)
    [[ -z "$root_dev" ]] && log ERR "Could not detect root device"
    root_dev=$(resolve_device "$root_dev")

    echo "Root device: $root_dev"
    echo ""

    check_alignment "$root_dev"
    local alignment_result=$?

    if [[ "$DETECTED_ALIGNMENT_VALUE" == sysfs:start:* ]]; then
        local info="${DETECTED_ALIGNMENT_VALUE#sysfs:}"
        local temp="${info#start:}"
        local start_sector="${temp%%:*}"
        local rest="${temp#*:}"
        local start_byte="${rest#byte:}"
        echo "Detection method: sysfs /sys/block/.../start"
        echo "Partition start sector: $start_sector"
        echo "Partition start byte: $start_byte"
    elif [[ "$DETECTED_ALIGNMENT_VALUE" == lsblk:* ]]; then
        local start_sector="${DETECTED_ALIGNMENT_VALUE#lsblk:}"
        echo "Detection method: lsblk -no START"
        echo "Partition start sector: $start_sector"
    elif [[ "$DETECTED_ALIGNMENT_VALUE" == blockdev:* ]]; then
        local sector_size="${DETECTED_ALIGNMENT_VALUE#blockdev:}"
        echo "Detection method: blockdev --getss"
        echo "Sector size: ${sector_size} bytes"
    fi
    echo ""

    case $alignment_result in
        0)
            echo -e "${GREEN}✓ 4k-aligned${NC}"
            echo ""
            echo "This filesystem is 4k-aligned and supports:"
            echo "  - Write-back (wb) cache mode for best performance"
            echo "  - Write-through (wt) cache mode for safety"
            ;;
        1)
            echo -e "${YELLOW}✗ Not 4k-aligned${NC}"
            echo ""
            echo "This filesystem is NOT 4k-aligned and supports:"
            echo "  - Write-through (wt) cache mode only"
            echo "  - Write-back (wb) is NOT supported"
            ;;
        2)
            echo -e "${YELLOW}⚠ Could not determine alignment${NC}"
            echo ""
            echo "Detection failed using available methods."
            echo "For safety, the script will use write-through (wt) mode."
            ;;
    esac

    cat << EOF

========================================

To proceed with installation, run:
  sudo $(basename "$0")

EOF
}

verify_rapiddisk() {
    local exit_code=0

    cat << EOF

========================================
Rapiddisk Post-Reboot Verification
========================================

EOF

    echo "[1/6] Checking rapiddisk kernel modules..."
    lsmod | grep -q "^rapiddisk_cache" && echo "      ✓ rapiddisk-cache module loaded" || { echo "      ✗ rapiddisk-cache module NOT loaded"; exit_code=1; }
    lsmod | grep -q "^rapiddisk" && echo "      ✓ rapidded module loaded" || { echo "      ✗ rapiddisk module NOT loaded"; exit_code=1; }

    echo ""
    echo "[2/6] Checking rapiddisk command..."
    command -v rapiddisk &>/dev/null && echo "      ✓ rapiddisk command available" || { echo "      ✗ rapiddisk command NOT available"; exit_code=1; }

    echo ""
    echo "[3/6] Checking rapiddisk devices..."
    local rapiddisk_devs=$(rapiddisk -l 2>/dev/null | grep -E "^rd[0-9]+" || true)
    if [[ -n "$rapiddisk_devs" ]]; then
        echo "      ✓ Rapiddisk devices found:"
        echo "$rapiddisk_devs" | while read -r line; do echo "        - $line"; done
    else
        echo "      ✗ No rapiddisk devices found"
        exit_code=1
    fi

    echo ""
    echo "[4/6] Checking cache mappings..."
    local cache_maps=$(rapiddisk -l 2>/dev/null | grep -E "^rc-[wb][0-9]+" || true)
    if [[ -n "$cache_maps" ]]; then
        echo "      ✓ Cache mappings found:"
        echo "$cache_maps" | while read -r line; do echo "        - $line"; done
    else
        echo "      ✗ No cache mappings found"
        exit_code=1
    fi

    echo ""
    echo "[5/6] Checking root filesystem mount..."
    local root_mount=$(mount | grep -E "^/dev/rc-" | grep "on / " || true)
    if [[ -n "$root_mount" ]]; then
        echo "      ✓ Root filesystem mounted on rapiddisk cached device:"
        echo "        $root_mount"
    else
        local orig_root=$(mount | grep "on / " | grep -v "^/dev/rc-" || true)
        if [[ -n "$orig_root" ]]; then
            echo "      ✗ Root filesystem NOT on rapiddisk cached device:"
            echo "        $orig_root"
            echo "        (Cache may not be active - did you reboot?)"
        else
            echo "      ✗ Could not determine root filesystem mount"
        fi
        exit_code=1
    fi

    echo ""
    echo "[6/6] Checking cache statistics..."
    local cache_stats=$(rapiddisk -s 2>/dev/null || true)
    if [[ -n "$cache_stats" ]]; then
        echo "      ✓ Cache statistics:"
        echo ""
        printf '%s\n' "$cache_stats" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    else
        echo "      ! Cache statistics not available"
    fi

    cat << EOF

========================================
EOF

    if (( exit_code == 0 )); then
        echo -e "${GREEN}✓ Verification PASSED - Rapiddisk is active!${NC}"
    else
        echo -e "${YELLOW}✗ Verification FAILED - Issues detected${NC}"
        echo ""
        echo "Troubleshooting tips:"
        echo "  1. Did you reboot after installation?"
        echo "  2. Check dmesg: dmesg | grep -i rapiddisk"
        echo "  3. Verify initramfs: ls -la /boot/initrd* or /boot/initramfs*"
        echo "  4. Check boot logs: journalctl | grep rapiddisk"
    fi
    echo "========================================"
    return "$exit_code"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Install rapiddisk cache on root device:
  - Cache size: 1/5 of system RAM (capped at 2GB)
  - Cache mode: write-back if 4k-aligned, otherwise write-through

Options:
  -h, --help           Show this help
  -f, --force          Force operation (overwrite existing config)
  -u, --uninstall       Uninstall for current kernel
  -g, --global-uninstall Complete removal (all kernels)
  -v, --verify         Verify rapiddisk is running (after reboot)
  -c, --check-alignment Check filesystem alignment

Examples:
  sudo $0                      # Install with defaults
  sudo $0 --force              # Force reinstall
  sudo $0 --uninstall           # Uninstall
  sudo $0 --global-uninstall    # Complete removal
  sudo $0 --verify              # Verify after reboot
  sudo $0 --check-alignment     # Check alignment

Note: Reboot required after installation.
EOF
}

main() {
    local action="install"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -f|--force) FORCE=true ;;
            -u|--uninstall) action="uninstall" ;;
            -g|--global-uninstall) action="global-uninstall" ;;
            -v|--verify) action="verify" ;;
            -c|--check-alignment) action="check-alignment" ;;
            *) log ERR "Unknown option: $1. Use -h for help." ;;
        esac
        shift
    done

    export FORCE

    case "$action" in
        install)  check_prerequisites; install_rapiddisk ;;
        uninstall)  check_uninstall_prerequisites; uninstall_rapiddisk ;;
        global-uninstall)  check_uninstall_prerequisites; global_uninstall ;;
        verify) verify_rapiddisk ;;
        check-alignment) show_alignment_info ;;
    esac
}

check_root "$@"

main "$@"
