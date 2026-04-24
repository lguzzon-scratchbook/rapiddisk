#!/bin/bash
#
# install-rapiddisk-root.sh - Install rapiddisk cache on root device
#
# This script automatically configures rapiddisk to cache the root device with:
# - Cache size = 1/5 of system memory (capped at 2GB maximum)
# - Write-back cache mode for best performance
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAPIDDISK_BOOT="${RAPIDDISK_BOOT:-${SCRIPT_DIR}/rapiddisk-rootdev/rapiddisk-on-boot}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error_exit() {
	echo -e "${RED}ERROR: $1${NC}" >&2
	exit 1
}

info() {
	echo -e "${GREEN}INFO: $1${NC}"
}

warn() {
	echo -e "${YELLOW}WARN: $1${NC}"
}

# Check if running as root
check_root() {
	if [[ $EUID -ne 0 ]]; then
		error_exit "This script must be run as root"
	fi
}

# Get total system memory in MB
get_system_memory() {
	local mem_kb
	mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	echo $((mem_kb / 1024))
}

# Calculate cache size: 1/5 of memory, max 2GB (2048MB)
calculate_cache_size() {
	local total_mem
	total_mem=$(get_system_memory)

	# Calculate 1/5 of memory
	local cache_size=$((total_mem / 5))

	# Cap at 2GB (2048MB)
	if [[ $cache_size -gt 2048 ]]; then
		cache_size=2048
		info "Cache size limited to 2048MB (2GB maximum)"
	fi

	# Ensure minimum size of 100MB
	if [[ $cache_size -lt 100 ]]; then
		cache_size=100
		warn "Cache size increased to minimum 100MB"
	fi

	echo "$cache_size"
}

# Get current kernel version
get_kernel_version() {
	uname -r
}

# Detect root device from /etc/fstab or /proc/mounts
detect_root_device() {
	local root_dev

	# Parse /etc/fstab to find root device
	root_dev=$(grep -vE '^[[:space:]]*#' /etc/fstab 2>/dev/null | grep -E '[[:space:]]+/[[:space:]]' | awk '{print $1}')

	# Fallback to /proc/mounts if not found in fstab (LiveCDs, containers, etc.)
	if [[ -z "$root_dev" ]]; then
		root_dev=$(awk '$2 == "/" {print $1}' /proc/mounts | head -1)
	fi

	# If UUID= or LABEL=, resolve to device
	if [[ "$root_dev" == UUID=* ]]; then
		local uuid=${root_dev#UUID=}
		local resolved
		resolved=$(readlink -f "/dev/disk/by-uuid/$uuid" 2>/dev/null || echo "")
		if [[ -z "$resolved" ]]; then
			error_exit "Could not resolve UUID '$uuid' to a device. Check /etc/fstab configuration."
		fi
		if [[ ! -b "$resolved" ]]; then
			error_exit "Resolved device '$resolved' does not exist or is not a block device"
		fi
		root_dev="$resolved"
	elif [[ "$root_dev" == LABEL=* ]]; then
		local label=${root_dev#LABEL=}
		local resolved
		resolved=$(readlink -f "/dev/disk/by-label/$label" 2>/dev/null || echo "")
		if [[ -z "$resolved" ]]; then
			error_exit "Could not resolve LABEL '$label' to a device. Check /etc/fstab configuration."
		fi
		if [[ ! -b "$resolved" ]]; then
			error_exit "Resolved device '$resolved' does not exist or is not a block device"
		fi
		root_dev="$resolved"
	elif [[ "$root_dev" == /dev/* ]]; then
		# Plain device path - validate it exists
		if [[ ! -b "$root_dev" ]]; then
			error_exit "Root device '$root_dev' does not exist or is not a block device"
		fi
	fi

	echo "$root_dev"
}

# Check prerequisites
check_prerequisites() {
	info "Checking prerequisites..."

	# Check for rapiddisk command
	if ! command -v rapiddisk &>/dev/null; then
		error_exit "rapiddisk command not found. Please install rapiddisk first."
	fi

	# Check for rapiddisk-on-boot script
	if [[ ! -x "$RAPIDDISK_BOOT" ]]; then
		error_exit "rapiddisk-on-boot script not found or not executable at: $RAPIDDISK_BOOT"
	fi

	# Check OS compatibility
	if [[ ! -f /etc/os-release ]]; then
		error_exit "Cannot detect OS. /etc/os-release not found."
	fi

	local os_id
	os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

	case "$os_id" in
	ubuntu | debian | centos | rhel | fedora | almalinux | rocky)
		info "Detected OS: $os_id"
		;;
	*)
		warn "OS '$os_id' may not be fully supported. Continuing anyway..."
		;;
	esac

	info "Prerequisites check passed"
}

# Main installation function
install_rapiddisk() {
	info "Starting rapiddisk installation on root device..."

	# Calculate cache size
	local cache_size
	cache_size=$(calculate_cache_size)
	info "Calculated cache size: ${cache_size}MB (1/5 of RAM, max 2GB)"

	# Get kernel version
	local kernel_version
	kernel_version=$(get_kernel_version)
	info "Kernel version: $kernel_version"

	# Detect root device
	local root_device
	root_device=$(detect_root_device)

	if [[ -z "$root_device" ]]; then
		error_exit "Could not detect root device automatically"
	fi

	info "Detected root device: $root_device"

	# Cache mode: write-back
	local cache_mode="wb"
	info "Cache mode: write-back ($cache_mode)"

	# Show summary
	echo ""
	echo "========================================"
	echo "Installation Summary:"
	echo "========================================"
	echo "Root Device:    $root_device"
	echo "Cache Size:     ${cache_size}MB"
	echo "Cache Mode:     write-back ($cache_mode)"
	echo "Kernel Version: $kernel_version"
	echo "========================================"
	echo ""

	# Confirm installation
	read -rp "Proceed with installation? [y/N]: " confirm
	if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
		info "Installation cancelled by user"
		exit 0
	fi

	# Run rapiddisk-on-boot
	info "Running rapiddisk-on-boot installation..."

	local rapiddisk_args=(
		--install
		--root="$root_device"
		--size="$cache_size"
		--cache-mode="$cache_mode"
		--kernel="$kernel_version"
	)
	[[ -n "$force_flag" ]] && rapiddisk_args+=(--force)

	"$RAPIDDISK_BOOT" "${rapiddisk_args[@]}"

	echo ""
	info "Installation completed successfully!"
	echo ""
	warn "A REBOOT IS REQUIRED to activate rapiddisk on root device."
	echo ""
	echo "After reboot, verify with:"
	echo "  sudo $(basename "$0") --verify    # Full verification script"
	echo "  rapiddisk -l                      # List rapiddisk devices"
	echo "  rapiddisk -s                      # Show cache statistics"
	echo ""
	echo "To uninstall, run:"
	echo "  sudo $(basename "$0") --uninstall"
}

# Show help
show_help() {
	cat <<EOF
Usage: $0 [OPTIONS]

Install rapiddisk cache on the root device with optimized settings:
  - Cache size: 1/5 of system RAM (capped at 2GB)
  - Cache mode: write-back (best performance)

Options:
  -h, --help      Show this help message
  -f, --force     Force operation (overwrite existing config)
  -u, --uninstall Uninstall rapiddisk from root device
  -g, --global-uninstall  Global uninstall for all kernels
  -v, --verify    Verify rapiddisk is properly running after reboot

Examples:
  sudo $0                    # Install with default settings
  sudo $0 --force            # Force reinstall
  sudo $0 --uninstall        # Uninstall for current kernel
  sudo $0 --uninstall --force # Force uninstall
  sudo $0 --global-uninstall # Complete removal
  sudo $0 --global-uninstall --force # Force global uninstall
  sudo $0 --verify           # Verify rapiddisk is active (run after reboot)

Note: A reboot is required after installation for changes to take effect.
EOF
}

# Uninstall function
uninstall_rapiddisk() {
	local kernel_version
	kernel_version=$(get_kernel_version)

	info "Uninstalling rapiddisk for kernel $kernel_version..."

	local rapiddisk_args=(--uninstall --kernel="$kernel_version")
	[[ -n "$force_flag" ]] && rapiddisk_args+=(--force)

	"$RAPIDDISK_BOOT" "${rapiddisk_args[@]}"

	info "Uninstall completed. A reboot is recommended."
}

# Global uninstall function
global_uninstall() {
	info "Global uninstall of rapiddisk-on-boot..."

	local rapiddisk_args=(--global-uninstall)
	[[ -n "$force_flag" ]] && rapiddisk_args+=(--force)

	"$RAPIDDISK_BOOT" "${rapiddisk_args[@]}"

	info "Global uninstall completed. A reboot is recommended."
}

# Verify rapiddisk is properly set up and running after reboot
verify_rapiddisk() {
	local exit_code=0

	echo ""
	echo "========================================"
	echo "Rapiddisk Post-Reboot Verification"
	echo "========================================"
	echo ""

	# 1. Check if rapiddisk modules are loaded
	echo "[1/6] Checking rapiddisk kernel modules..."
	if lsmod | grep -q "^rapiddisk_cache"; then
		echo "      ✓ rapiddisk-cache module is loaded"
	else
		echo "      ✗ rapiddisk-cache module is NOT loaded"
		exit_code=1
	fi

	if lsmod | grep -q "^rapiddisk"; then
		echo "      ✓ rapiddisk module is loaded"
	else
		echo "      ✗ rapiddisk module is NOT loaded"
		exit_code=1
	fi

	# 2. Check if rapiddisk command is available
	echo ""
	echo "[2/6] Checking rapiddisk command..."
	if command -v rapiddisk &>/dev/null; then
		echo "      ✓ rapiddisk command is available"
	else
		echo "      ✗ rapiddisk command is NOT available"
		exit_code=1
	fi

	# 3. Check for rapiddisk devices
	echo ""
	echo "[3/6] Checking rapiddisk devices..."
	local rapiddisk_devs
	rapiddisk_devs=$(rapiddisk -l 2>/dev/null | grep -E "^rd[0-9]+" || true)
	if [[ -n "$rapiddisk_devs" ]]; then
		echo "      ✓ Rapiddisk devices found:"
		echo "$rapiddisk_devs" | while read -r line; do
			echo "        - $line"
		done
	else
		echo "      ✗ No rapiddisk devices found"
		exit_code=1
	fi

	# 4. Check for cache mappings
	echo ""
	echo "[4/6] Checking cache mappings..."
	local cache_maps
	cache_maps=$(rapiddisk -l 2>/dev/null | grep -E "^rc-w[tab][0-9]+" || true)
	if [[ -n "$cache_maps" ]]; then
		echo "      ✓ Cache mappings found:"
		echo "$cache_maps" | while read -r line; do
			echo "        - $line"
		done
	else
		echo "      ✗ No cache mappings found"
		exit_code=1
	fi

	# 5. Verify root is mounted on cached device
	echo ""
	echo "[5/6] Checking root filesystem mount..."
	local root_mount
	root_mount=$(mount | grep -E "^/dev/rc-" | grep "on / " || true)
	if [[ -n "$root_mount" ]]; then
		echo "      ✓ Root filesystem is mounted on rapiddisk cached device:"
		echo "        $root_mount"
	else
		# Check if root is still on original device (cache not active)
		local orig_root
		orig_root=$(mount | grep "on / " | grep -v "^/dev/rc-" || true)
		if [[ -n "$orig_root" ]]; then
			echo "      ✗ Root filesystem is NOT on rapiddisk cached device:"
			echo "        $orig_root"
			echo "        (Cache may not be active yet - did you reboot after installation?)"
		else
			echo "      ✗ Could not determine root filesystem mount"
		fi
		exit_code=1
	fi

	# 6. Show cache statistics if available
	echo ""
	echo "[6/6] Checking cache statistics..."
	local cache_stats
	cache_stats=$(rapiddisk -s 2>/dev/null || true)
	if [[ -n "$cache_stats" ]]; then
		echo "      ✓ Cache statistics:"
		echo ""
		printf '%s\n' "$cache_stats" | while IFS= read -r line; do
			printf '        %s\n' "$line"
		done
	else
		echo "      ! Cache statistics not available (may need more time to populate)"
	fi

	# Summary
	echo ""
	echo "========================================"
	if [[ $exit_code -eq 0 ]]; then
		echo -e "${GREEN}✓ Verification PASSED - Rapiddisk is active!${NC}"
	else
		echo -e "${YELLOW}✗ Verification FAILED - Issues detected${NC}"
		echo ""
		echo "Troubleshooting tips:"
		echo "  1. Did you reboot after installation?"
		echo "  2. Check dmesg for rapiddisk errors: dmesg | grep -i rapiddisk"
		echo "  3. Verify initramfs was rebuilt: ls -la /boot/initrd* or /boot/initramfs*"
		echo "  4. Check rapiddisk logs during boot: journalctl | grep rapiddisk"
	fi
	echo "========================================"

	return "$exit_code"
}

# Main entry point
main() {
	local action="install"
	local force_flag=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			show_help
			exit 0
			;;
		-f | --force)
			force_flag="--force"
			;;
		-u | --uninstall)
			action="uninstall"
			;;
		-g | --global-uninstall)
			action="global-uninstall"
			;;
		-v | --verify)
			action="verify"
			;;
		*)
			error_exit "Unknown option: $1. Use -h or --help for usage."
			;;
		esac
		shift
	done

	# Export force flag for functions to use
	[[ -n "$force_flag" ]] && export force_flag

	# Execute action
	case "$action" in
	install)
		check_root
		check_prerequisites
		install_rapiddisk
		;;
	uninstall)
		check_root
		check_prerequisites
		uninstall_rapiddisk
		;;
	global-uninstall)
		check_root
		check_prerequisites
		global_uninstall
		;;
	verify)
		verify_rapiddisk
		;;
	esac
}

main "$@"
