#!/bin/bash
#
# install-rapiddisk-root.sh - Install RapidDisk RAM disk cache for root device
# Usage: sudo ./install-rapiddisk-root.sh [OPTIONS]
#
# This script builds rapiddisk from local source and configures it to cache
# the root filesystem at boot time.
#

set -euo pipefail

# Auto-escalate if not root but sudoer
if [[ "$(id -u)" -ne 0 ]]; then
    if sudo -v 2>/dev/null; then
        exec sudo "$0" "$@"
    else
        echo "Error: This script must be run as root (use: sudo $0)" >&2
        exit 1
    fi
fi

# ==============================================================================
# Configuration
# ==============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="${SCRIPT_DIR}"
readonly CACHE_MODE="${CACHE_MODE:-wb}"      # Default: write-back (wb), alternatives: wt, wa
readonly MAX_RAMDISK_MB="${MAX_RAMDISK_MB:-2048}"
readonly RAMDISK_RATIO="${RAMDISK_RATIO:-5}"  # Use 1/5 of available memory

# Paths
readonly CONFIG_DIR="/etc/rapiddisk"
readonly HOOKS_DIR="/usr/share/initramfs-tools/hooks"
readonly SCRIPTS_DIR="/usr/share/initramfs-tools/scripts/init-premount"
readonly LOCAL_BOTTOM_DIR="/usr/share/initramfs-tools/scripts/local-bottom"

# Colors for terminal output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'

# Log levels
readonly LOG_ERROR=0
readonly LOG_WARN=1
readonly LOG_INFO=2
readonly LOG_DEBUG=3
LOG_LEVEL=${LOG_LEVEL:-$LOG_INFO}

# ==============================================================================
# Logging Functions
# ==============================================================================

use_colors() {
    [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]
}

log_msg() {
    local level=$1 color=$2 label=$3
    shift 3
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ $level -le $LOG_LEVEL ]]; then
        if use_colors; then
            printf "${color}[%s] %s:${COLOR_RESET} %s\n" "$timestamp" "$label" "$msg" >&2
        else
            printf "[%s] %s: %s\n" "$timestamp" "$label" "$msg" >&2
        fi
    fi
}

log_error() { log_msg $LOG_ERROR "$COLOR_RED" "ERROR" "$@"; }
log_warn() { log_msg $LOG_WARN "$COLOR_YELLOW" "WARN" "$@"; }
log_info() { log_msg $LOG_INFO "$COLOR_GREEN" "INFO" "$@"; }
log_debug() { log_msg $LOG_DEBUG "$COLOR_CYAN" "DEBUG" "$@"; }

log_section() {
    local title=$1
    if use_colors; then
        printf "\n${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
        printf "${COLOR_BLUE}  %s${COLOR_RESET}\n" "$title" >&2
        printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
    else
        printf "\n================================================================================\n" >&2
        printf "  %s\n" "$title" >&2
        printf "================================================================================\n" >&2
    fi
}

status_ok() { printf "  ${COLOR_GREEN}[✓]${COLOR_RESET} %s\n" "$*" >&2; }
status_warn() { printf "  ${COLOR_YELLOW}[!]${COLOR_RESET} %s\n" "$*" >&2; }
status_fail() { printf "  ${COLOR_RED}[✗]${COLOR_RESET} %s\n" "$*" >&2; }
status_info() { printf "  ${COLOR_CYAN}[i]${COLOR_RESET} %s\n" "$*" >&2; }

# ==============================================================================
# Helper Functions
# ==============================================================================

get_kernel_version() {
    uname -r
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

calculate_ramdisk_size() {
    local host_mem_kb ramdisk_kb size_mb
    host_mem_kb=$(free -k | awk '/^Mem:/ {print $2}')
    ramdisk_kb=$((host_mem_kb / RAMDISK_RATIO))
    size_mb=$((ramdisk_kb / 1024))
    [[ "$size_mb" -lt 64 ]] && size_mb=64
    [[ "$size_mb" -gt "$MAX_RAMDISK_MB" ]] && size_mb=$MAX_RAMDISK_MB
    echo "$size_mb"
}

get_root_device() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null) || root_dev=$(df / | awk 'NR==2 {print $1}')
    
    # Resolve UUID/LABEL to device path
    if [[ "$root_dev" == UUID=* ]]; then
        local uuid="${root_dev#UUID=}"
        root_dev="/dev/disk/by-uuid/$uuid"
    elif [[ "$root_dev" == LABEL=* ]]; then
        local label="${root_dev#LABEL=}"
        root_dev="/dev/disk/by-label/$label"
    fi
    
    # Get the real device path
    if [[ -L "$root_dev" ]]; then
        root_dev=$(readlink -f "$root_dev")
    fi
    
    echo "$root_dev"
}

validate_environment() {
    local ramdisk_size=$1
    local avail_mem_kb
    avail_mem_kb=$(free -k | awk '/^Mem:/ {print $7}')

    log_debug "Available memory: ${avail_mem_kb}KB"
    log_debug "Requested RAM disk: ${ramdisk_size}MB ($((ramdisk_size * 1024))KB)"

    if [[ $((ramdisk_size * 1024)) -gt "$avail_mem_kb" ]]; then
        log_warn "Available memory (${avail_mem_kb}KB) may be insufficient for ${ramdisk_size}MB RAM disk"
        log_info "Proceeding anyway, but monitor system performance after reboot"
    else
        log_debug "Memory validation passed"
    fi
}

# ==============================================================================
# Build and Install Functions
# ==============================================================================

install_dependencies() {
    local distro
    distro=$(detect_distro)
    
    log_info "Detected distribution: $distro"
    log_info "Installing build dependencies..."
    
    case "$distro" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || {
                log_error "Failed to update package lists"
                return 1
            }
            
            local pkgs="libpcre2-dev libdevmapper-dev libjansson-dev libmicrohttpd-dev build-essential"
            local kernel_ver
            kernel_ver=$(get_kernel_version)
            
            # shellcheck disable=SC2086
            apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install $pkgs || {
                log_error "Failed to install dependencies"
                return 1
            }
            
            # Install kernel headers
            log_info "Installing kernel headers for $kernel_ver..."
            apt-get -y -qq install "linux-headers-${kernel_ver}" 2>/dev/null || {
                log_warn "Could not install kernel headers. You may need to install them manually."
            }
            ;;
            
        centos|rhel|fedora|rocky|almalinux)
            log_info "Installing dependencies for RHEL-based system..."
            # shellcheck disable=SC2086
            yum -y install pcre2-devel device-mapper-devel jansson-devel libmicrohttpd-devel make gcc || {
                log_error "Failed to install dependencies"
                return 1
            }
            
            local kernel_ver
            kernel_ver=$(get_kernel_version)
            yum -y install "kernel-headers-${kernel_ver}" "kernel-devel-${kernel_ver}" 2>/dev/null || {
                log_warn "Could not install kernel headers. You may need to install them manually."
            }
            ;;
            
        *)
            log_warn "Unknown distribution. Please install dependencies manually:"
            log_warn "  - libpcre2-dev (pcre2-devel)"
            log_warn "  - libdevmapper-dev (device-mapper-devel)"
            log_warn "  - libjansson-dev (jansson-devel)"
            log_warn "  - libmicrohttpd-dev (libmicrohttpd-devel)"
            log_warn "  - build tools (gcc, make)"
            ;;
    esac
}

build_rapiddisk() {
    log_info "Building rapiddisk from local source..."
    log_info "Build directory: $PROJECT_ROOT"
    
    cd "$PROJECT_ROOT"
    
    # Clean previous builds
    make clean 2>/dev/null || true
    
    # Build the project
    log_debug "Running make..."
    if ! make; then
        log_error "Build failed - check compiler output above"
        return 1
    fi
    
    log_info "Installing rapiddisk..."
    if ! make install; then
        log_error "Install failed"
        return 1
    fi
    
    # Verify installation
    if ! command -v rapiddisk >/dev/null 2>&1; then
        log_error "rapiddisk binary not found in PATH after install"
        return 1
    fi
    
    local version
    version=$(rapiddisk -v 2>&1 | head -1)
    log_info "Installed: $version"
    
    cd - >/dev/null || true
}

# ==============================================================================
# Initramfs Functions
# ==============================================================================

create_hook_script() {
    local kernel_version=$1
    
    log_info "Creating initramfs hook script..."
    
    cat > "${HOOKS_DIR}/rapiddisk_hook" << 'EOF'
#!/bin/sh
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}

case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /usr/share/initramfs-tools/hook-functions

config_dir="/etc/rapiddisk"
for i in "${config_dir}"/rapiddisk_kernel_*
    do
        if [ "${config_dir}/rapiddisk_kernel_${version}" = "$i" ] ; then
            size="$(head -n 1 "$i")"
            device="$(head -n 2 "$i" | tail -n 1)"
            cache_mode="$(tail -n 1 "$i")"
            cwd="$(dirname "$0")"
            cp "${config_dir}/rapiddisk_sub.orig" "${cwd}/rapiddisk_sub"
            sed -i "s,RAMDISKSIZE,${size},g" "${cwd}/rapiddisk_sub"
            sed -i "s,BOOTDEVICE,${device},g" "${cwd}/rapiddisk_sub"
            sed -i "s,CACHEMODE,${cache_mode},g" "${cwd}/rapiddisk_sub"
            chmod +x "${cwd}/rapiddisk_sub"
            manual_add_modules rapiddisk
            manual_add_modules rapiddisk-cache
            if [ "$cache_mode" = "wb" ] ; then
                manual_add_modules dm-writecache
            fi
            copy_exec /sbin/rapiddisk /sbin/rapiddisk
            copy_file binary "${cwd}/rapiddisk_sub" /sbin/
            rm "${cwd}/rapiddisk_sub"
            break 2
        fi
    done

exit 0
EOF
    chmod +x "${HOOKS_DIR}/rapiddisk_hook"
    status_ok "Hook script installed"
}

create_sub_script() {
    log_info "Creating rapiddisk boot script template..."
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "${CONFIG_DIR}/rapiddisk_sub.orig" << 'EOF'
#!/bin/sh

. /scripts/functions

FAILUREMSG="rapiddisk: failed."
log_begin_msg "rapiddisk: starting, ramdisk size: RAMDISKSIZE, boot device: BOOTDEVICE, caching mode: CACHEMODE."

# Load dm-writecache if writeback mode
if [ "CACHEMODE" = "wb" ] ; then
    modprobe -q dm-writecache
    if [ ! -d /sys/module/dm_writecache ] ; then
        log_failure_msg "rapiddisk: unable to load dm-writecache module"
        log_failure_msg "$FAILUREMSG"
        exit 0
    fi
fi

# Load rapiddisk modules
modprobe -q rapiddisk
modprobe -q rapiddisk-cache

if { [ ! -d /sys/module/rapiddisk ] || [ ! -d /sys/module/rapiddisk_cache ] ; } ; then
    log_failure_msg "rapiddisk: unable to load rapiddisk modules"
    log_failure_msg "$FAILUREMSG"
    exit 0
fi

# Create ramdisk
rapiddisk >/dev/null 2>&1 -a RAMDISKSIZE

# Map cache to root device
if ! rapiddisk >/dev/null 2>&1 -m rd0 -b BOOTDEVICE -p CACHEMODE ; then
    log_failure_msg "rapiddisk: attaching of the ramdisk failed, trying with a workaround"
    
    # Workaround: create/delete ramdisks to reset state
    rapiddisk >/dev/null 2>&1 -a 5 || true
    rapiddisk >/dev/null 2>&1 -d rd0 || true
    rapiddisk >/dev/null 2>&1 -a RAMDISKSIZE || true
    rapiddisk >/dev/null 2>&1 -a 5 || true
    rapiddisk >/dev/null 2>&1 -d rd1 || true
    
    if ! rapiddisk >/dev/null 2>&1 -m rd0 -b BOOTDEVICE -p CACHEMODE ; then
        rapiddisk >/dev/null 2>&1 -d rd0 || true
        rapiddisk >/dev/null 2>&1 -d rd1 || true
        rapiddisk >/dev/null 2>&1 -d rd2 || true
        log_failure_msg "rapiddisk: attaching of the ramdisk failed"
        exit 0
    fi
fi

result="$(rapiddisk 2>&1 -l)"
log_success_msg "$result"
log_end_msg "rapiddisk: RAMDISKSIZE MB ramdisk attached to BOOTDEVICE successfully."
exit 0
EOF
    chmod -x "${CONFIG_DIR}/rapiddisk_sub.orig"
    status_ok "Sub script template installed"
}

create_boot_script() {
    log_info "Creating boot script..."
    
    mkdir -p "$SCRIPTS_DIR"
    
    cat > "${SCRIPTS_DIR}/rapiddisk_boot" << 'EOF'
#!/bin/sh
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}

case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /scripts/functions

# Begin real processing below this line
if [ -x /sbin/rapiddisk_sub ] ; then
    /sbin/rapiddisk_sub
fi

exit 0
EOF
    chmod +x "${SCRIPTS_DIR}/rapiddisk_boot"
    status_ok "Boot script installed"
}

create_clean_script() {
    log_info "Creating cleanup script..."
    
    mkdir -p "$LOCAL_BOTTOM_DIR"
    
    cat > "${LOCAL_BOTTOM_DIR}/rapiddisk_clean" << 'EOF'
#!/bin/sh
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}

case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /scripts/functions

# Cleanup unmapped ramdisks after boot
if command -v rapiddisk >/dev/null 2>&1; then
    cache="$(rapiddisk -l 2>&1)"
    ramdisks="$(echo "$cache" | grep -oE "rd[0-9]+" | sort -u)"
    mapped="$(echo "$cache" | grep -oE "rc-[a-z]+[0-9]*_rd[0-9]+" | grep -oE "rd[0-9]+" | sort -u)"
    
    for rd in $ramdisks; do
        if ! echo "$mapped" | grep -qx "$rd"; then
            rapiddisk -d "$rd" 2>/dev/null || true
        fi
    done
fi

exit 0
EOF
    chmod +x "${LOCAL_BOTTOM_DIR}/rapiddisk_clean"
    status_ok "Cleanup script installed"
}

create_kernel_config() {
    local kernel_version=$1
    local ramdisk_size=$2
    local root_device=$3
    local cache_mode=$4
    
    log_info "Creating kernel config for ${kernel_version}..."
    
    mkdir -p "$CONFIG_DIR"
    local config_file="${CONFIG_DIR}/rapiddisk_kernel_${kernel_version}"
    
    printf '%s\n%s\n%s\n' "$ramdisk_size" "$root_device" "$cache_mode" > "$config_file"
    status_ok "Kernel config: $config_file"
    log_info "  RAM disk size: ${ramdisk_size} MB"
    log_info "  Root device: ${root_device}"
    log_info "  Cache mode: ${cache_mode}"
}

backup_initramfs() {
    local kernel=$1
    local backup_suffix
    backup_suffix=".backup.rapiddisk-$(date +%Y%m%d-%H%M%S)"
    
    # Handle both Ubuntu and CentOS initramfs naming
    local initramfs_paths=(
        "/boot/initrd.img-${kernel}"
        "/boot/initramfs-${kernel}.img"
    )
    
    for initramfs_path in "${initramfs_paths[@]}"; do
        if [[ -f "$initramfs_path" ]]; then
            log_info "Creating initramfs backup..."
            if cp "$initramfs_path" "${initramfs_path}${backup_suffix}"; then
                status_ok "Backup created: ${initramfs_path}${backup_suffix}"
                return 0
            fi
        fi
    done
    
    log_warn "Could not find initramfs to backup"
}

update_initramfs() {
    local kernel_version=$1
    local distro
    distro=$(detect_distro)
    
    log_info "Regenerating initramfs for kernel ${kernel_version}..."
    
    case "$distro" in
        ubuntu|debian)
            if update-initramfs -u -k "$kernel_version"; then
                status_ok "Initramfs updated successfully"
            else
                log_error "Failed to update initramfs"
                return 1
            fi
            ;;
            
        centos|rhel|fedora|rocky|almalinux)
            if dracut --kver "$kernel_version" -f; then
                status_ok "Initramfs updated successfully"
            else
                log_error "Failed to update initramfs"
                return 1
            fi
            ;;
            
        *)
            # Try both methods
            if command -v update-initramfs >/dev/null 2>&1; then
                update-initramfs -u -k "$kernel_version" && status_ok "Initramfs updated"
            elif command -v dracut >/dev/null 2>&1; then
                dracut --kver "$kernel_version" -f && status_ok "Initramfs updated"
            else
                log_error "No initramfs tool found"
                return 1
            fi
            ;;
    esac
}

# ==============================================================================
# Module Functions
# ==============================================================================

load_modules_now() {
    log_info "Loading kernel modules..."
    
    # Try to load modules if they're available
    modprobe rapiddisk 2>/dev/null || log_warn "Could not load rapiddisk module (will be loaded at boot)"
    modprobe rapiddisk-cache 2>/dev/null || log_warn "Could not load rapiddisk-cache module (will be loaded at boot)"
    
    if [[ "$CACHE_MODE" == "wb" ]]; then
        modprobe dm-writecache 2>/dev/null || log_warn "Could not load dm-writecache module (will be loaded at boot)"
    fi
}

ensure_module_loading() {
    log_info "Configuring modules to load at boot..."
    
    # Add to /etc/modules for Debian/Ubuntu
    if [[ -f /etc/modules ]]; then
        for module in rapiddisk rapiddisk-cache; do
            if ! grep -qx "$module" /etc/modules 2>/dev/null; then
                echo "$module" >> /etc/modules
                log_debug "Added $module to /etc/modules"
            fi
        done
        
        if [[ "$CACHE_MODE" == "wb" ]]; then
            if ! grep -qx "dm-writecache" /etc/modules 2>/dev/null; then
                echo "dm-writecache" >> /etc/modules
            fi
        fi
    fi
    
    # Add to modules-load.d for systemd systems
    if [[ -d /etc/modules-load.d ]]; then
        cat > /etc/modules-load.d/rapiddisk.conf << EOF
# Load rapiddisk modules at boot
rapiddisk
rapiddisk-cache
EOF
        if [[ "$CACHE_MODE" == "wb" ]]; then
            echo "dm-writecache" >> /etc/modules-load.d/rapiddisk.conf
        fi
        status_ok "Created /etc/modules-load.d/rapiddisk.conf"
    fi
}

# ==============================================================================
# Verification Functions
# ==============================================================================

do_verify() {
    local issues=0
    local rd_count=0
    local cache_count=0
    
    log_section "Verifying RapidDisk Installation"
    
    # Check kernel modules
    log_info "Checking kernel modules..."
    for mod in rapiddisk rapiddisk-cache; do
        local mod_underscore=${mod//-/_}
        if lsmod 2>/dev/null | grep -q "^${mod_underscore} "; then
            status_ok "${mod} - loaded"
        else
            status_warn "${mod} - not loaded (will be loaded at boot)"
        fi
    done
    
    # Check binary
    log_info "Checking rapiddisk binary..."
    if command -v rapiddisk >/dev/null 2>&1; then
        local version
        version=$(rapiddisk -v 2>&1 | head -1)
        status_ok "rapiddisk installed: $version"
    else
        status_fail "rapiddisk binary not found"
        ((issues++))
    fi
    
    # Check initramfs scripts
    log_info "Checking initramfs scripts..."
    if [[ -x "${HOOKS_DIR}/rapiddisk_hook" ]]; then
        status_ok "Hook script installed"
    else
        status_warn "Hook script not installed"
        ((issues++))
    fi
    
    if [[ -x "${SCRIPTS_DIR}/rapiddisk_boot" ]]; then
        status_ok "Boot script installed"
    else
        status_warn "Boot script not installed"
        ((issues++))
    fi
    
    if [[ -f "${CONFIG_DIR}/rapiddisk_sub.orig" ]]; then
        status_ok "Sub script template installed"
    else
        status_warn "Sub script template not installed"
        ((issues++))
    fi
    
    # Check kernel config
    local kernel_version
    kernel_version=$(get_kernel_version)
    local config_file="${CONFIG_DIR}/rapiddisk_kernel_${kernel_version}"
    
    log_info "Checking kernel config..."
    if [[ -f "$config_file" ]]; then
        local size device mode
        size=$(head -1 "$config_file")
        device=$(head -2 "$config_file" | tail -1)
        mode=$(tail -1 "$config_file")
        status_ok "Config exists for ${kernel_version}"
        log_info "  Size: ${size} MB"
        log_info "  Device: ${device}"
        log_info "  Mode: ${mode}"
    else
        status_warn "No config found for ${kernel_version}"
        ((issues++))
    fi
    
    # Summary
    echo ""
    if [[ $issues -eq 0 ]]; then
        log_info "Status: Installation looks complete. A reboot is required to activate caching."
        return 0
    else
        log_warn "Status: Some components may be missing. Review the warnings above."
        return 1
    fi
}

# ==============================================================================
# Uninstall Functions
# ==============================================================================

do_uninstall() {
    log_section "Uninstalling RapidDisk Root Cache"
    
    local kernel_version
    kernel_version=$(get_kernel_version)
    local distro
    distro=$(detect_distro)
    
    log_info "Removing initramfs scripts..."
    rm -f "${HOOKS_DIR}/rapiddisk_hook"
    rm -f "${SCRIPTS_DIR}/rapiddisk_boot"
    rm -f "${LOCAL_BOTTOM_DIR}/rapiddisk_clean"
    status_ok "Initramfs scripts removed"
    
    log_info "Removing configuration..."
    rm -f "${CONFIG_DIR}/rapiddisk_kernel_${kernel_version}"
    rm -f "${CONFIG_DIR}/rapiddisk_sub.orig"
    rmdir "$CONFIG_DIR" 2>/dev/null || true
    status_ok "Configuration removed"
    
    log_info "Removing module load configuration..."
    rm -f /etc/modules-load.d/rapiddisk.conf
    
    # Remove from /etc/modules
    if [[ -f /etc/modules ]]; then
        sed -i '/^rapiddisk$/d; /^rapiddisk-cache$/d; /^dm-writecache$/d' /etc/modules
    fi
    status_ok "Module configuration removed"
    
    log_info "Regenerating initramfs..."
    case "$distro" in
        ubuntu|debian)
            update-initramfs -u -k "$kernel_version" || log_warn "Failed to update initramfs"
            ;;
        centos|rhel|fedora)
            dracut --kver "$kernel_version" -f || log_warn "Failed to update initramfs"
            ;;
    esac
    
    log_info "RapidDisk root cache has been uninstalled."
    log_info "A reboot is required to complete the uninstallation."
}

# ==============================================================================
# Main Installation
# ==============================================================================

show_configuration() {
    local ramdisk_size=$1
    local root_device=$2
    local kernel_version=$3
    local cache_mode=$4
    
    echo ""
    if use_colors; then
        printf "${COLOR_BLUE}┌────────────────────────────────────────────────────────────────────────────┐${COLOR_RESET}\n" >&2
        printf "${COLOR_BLUE}│ Configuration Summary                                                      │${COLOR_RESET}\n" >&2
        printf "${COLOR_BLUE}├────────────────────────────────────────────────────────────────────────────┤${COLOR_RESET}\n" >&2
        printf "${COLOR_BLUE}│${COLOR_RESET}  RAM disk size: ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${ramdisk_size} MB" >&2
        printf "${COLOR_BLUE}│${COLOR_RESET}  Root device:   ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${root_device}" >&2
        printf "${COLOR_BLUE}│${COLOR_RESET}  Cache mode:    ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${cache_mode}" >&2
        printf "${COLOR_BLUE}│${COLOR_RESET}  Kernel:        ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${kernel_version}" >&2
        printf "${COLOR_BLUE}└────────────────────────────────────────────────────────────────────────────┘${COLOR_RESET}\n" >&2
    else
        printf "================================================================================\n" >&2
        printf "Configuration Summary\n" >&2
        printf "================================================================================\n" >&2
        printf "  RAM disk size: %s MB\n" "$ramdisk_size" >&2
        printf "  Root device:   %s\n" "$root_device" >&2
        printf "  Cache mode:    %s\n" "$cache_mode" >&2
        printf "  Kernel:        %s\n" "$kernel_version" >&2
        printf "================================================================================\n" >&2
    fi
    echo ""
}

do_install() {
    local skip_reboot=${1:-false}
    local custom_size=${2:-}
    local custom_mode=${3:-}
    
    # Note: Root check already handled by auto-escalation at script start
    
    # Gather configuration
    local ramdisk_size root_device kernel_version cache_mode
    
    if [[ -n "$custom_size" ]]; then
        ramdisk_size=$custom_size
    else
        ramdisk_size=$(calculate_ramdisk_size)
    fi
    
    root_device=$(get_root_device)
    kernel_version=$(get_kernel_version)
    
    if [[ -n "$custom_mode" ]]; then
        cache_mode=$custom_mode
    else
        cache_mode=$CACHE_MODE
    fi
    
    # Validate cache mode
    cache_mode=$(echo "$cache_mode" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$cache_mode" =~ ^w[tab]$ ]]; then
        log_error "Invalid cache mode: $cache_mode. Must be one of: wt, wa, wb"
        exit 1
    fi
    
    show_configuration "$ramdisk_size" "$root_device" "$kernel_version" "$cache_mode"
    validate_environment "$ramdisk_size"
    
    log_section "Step 1/7: Installing Dependencies"
    install_dependencies || {
        log_warn "Some dependencies may have failed to install"
        log_info "Continuing anyway..."
    }
    
    log_section "Step 2/7: Building RapidDisk"
    build_rapiddisk || {
        log_error "Build failed"
        exit 1
    }
    
    log_section "Step 3/7: Configuring Kernel Modules"
    ensure_module_loading
    load_modules_now
    status_ok "Kernel modules configured"
    
    log_section "Step 4/7: Backing Up Initramfs"
    backup_initramfs "$kernel_version"
    
    log_section "Step 5/7: Installing Initramfs Scripts"
    create_hook_script "$kernel_version"
    create_sub_script
    create_boot_script
    create_clean_script
    create_kernel_config "$kernel_version" "$ramdisk_size" "$root_device" "$cache_mode"
    
    log_section "Step 6/7: Updating Initramfs"
    update_initramfs "$kernel_version" || {
        log_error "Initramfs update failed"
        exit 1
    }
    
    log_section "Step 7/7: Installation Complete"
    
    log_info "RapidDisk has been successfully installed!"
    echo ""
    status_info "RAM disk size: ${ramdisk_size} MB"
    status_info "Root device: ${root_device}"
    status_info "Cache mode: ${cache_mode}"
    status_info "Kernel: ${kernel_version}"
    echo ""
    
    if [[ "$skip_reboot" == true ]]; then
        log_warn "Skipping reboot as requested (--skip-reboot)"
        log_info "To activate the RAM disk cache, reboot manually with: sudo reboot"
        log_info "After reboot, verify with: sudo $0 --verify"
    else
        log_info "System will reboot in 5 seconds to activate the RAM disk cache..."
        log_info "Press Ctrl+C now to cancel the reboot"
        sleep 5
        reboot
    fi
}

# ==============================================================================
# Help and Main
# ==============================================================================

show_help() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

RapidDisk RAM disk cache installer for root filesystem.
Builds rapiddisk from local source and configures it to cache the root device.

OPTIONS:
    (none)              Install rapiddisk and reboot automatically
    --skip-reboot       Install without rebooting (manual reboot required)
    --verify            Verify installation status
    --uninstall         Remove rapiddisk root cache configuration
    --size=SIZE         Set RAM disk size in MB (default: auto-calculated)
    --mode=MODE         Set cache mode: wt, wa, or wb (default: $CACHE_MODE)
    --debug             Enable debug output
    --help, -h          Show this help message

CACHE MODES:
    wb = Write-Back (writes go to cache first, then disk - DEFAULT)
    wt = Write-Through (all writes go to cache and disk)
    wa = Write-Around (only reads are cached)

EXAMPLES:
    sudo $0                       # Install with auto-detected settings
    sudo $0 --skip-reboot         # Install without rebooting
    sudo $0 --size=1024           # Use 1GB RAM disk
    sudo $0 --mode=wb             # Use write-back mode
    sudo $0 --size=512 --mode=wt  # Use 512MB RAM disk with write-through
    sudo $0 --verify              # Check installation status
    sudo $0 --uninstall           # Remove rapiddisk from root device

FILES:
    /etc/rapiddisk/                 # Configuration directory
    /etc/rapiddisk/rapiddisk_kernel_* # Kernel-specific configs
    /boot/initrd.img-*              # Initramfs images (backups created)

For more information, see: https://github.com/pkoutoupis/rapiddisk
EOF
}

main() {
    local skip_reboot=false
    local do_verify_only=false
    local do_uninstall_flag=false
    local custom_size=""
    local custom_mode=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --debug)
            LOG_LEVEL=$LOG_DEBUG
            set -x
            shift
            ;;
        --skip-reboot)
            skip_reboot=true
            shift
            ;;
        --verify)
            do_verify_only=true
            shift
            ;;
        --uninstall)
            do_uninstall_flag=true
            shift
            ;;
        --size=*)
            custom_size="${1#*=}"
            shift
            ;;
        --mode=*)
            custom_mode="${1#*=}"
            shift
            ;;
    CACHE MODES:
    wt = Write-Through (all writes go to cache and disk)
    wa = Write-Around (only reads are cached)
    wb = Write-Back (writes go to cache first, then disk - requires dm-writecache)
                         ^
    DEFAULT: wb (write-back) using 1/5 of system memory, max 2GB
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        esac
    done
    
    # Execute requested action
    if [[ "$do_verify_only" == true ]]; then
        do_verify
    elif [[ "$do_uninstall_flag" == true ]]; then
        do_uninstall
    else
        do_install "$skip_reboot" "$custom_size" "$custom_mode"
    fi
}

main "$@"
