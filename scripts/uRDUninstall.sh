#!/bin/bash
#
# uRDUninstall.sh - RapidDisk RAM disk cache uninstaller for Ubuntu/Debian systems
# Usage: sudo ./uRDUninstall.sh [DEVICE_TO_CACHE]
#
# Arguments:
#   DEVICE_TO_CACHE - Optional. The root device name (e.g., sda1, nvme0n1p1)
#                     If provided, /etc/fstab will be restored to use this device.
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

readonly REPO_URL="https://github.com/pkoutoupis/rapiddisk.git"
readonly RAPIDDISK_DIR="$HOME/rapiddisk"

# ==============================================================================
# Logging & Output Helpers
# ==============================================================================

# Colors for terminal output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'

# Check if we should use colors
use_colors() {
	[[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]
}

# Timestamp for logs
log_timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

# Core logging function
log_msg() {
	local color=$1 label=$2
	shift 2
	local msg="$*"
	local timestamp
	timestamp=$(log_timestamp)

	if use_colors; then
		printf "${color}[%s] %s:${COLOR_RESET} %s\n" "$timestamp" "$label" "$msg" >&2
	else
		printf "[%s] %s: %s\n" "$timestamp" "$label" "$msg" >&2
	fi
}

# Public logging functions
log_error() { log_msg "$COLOR_RED" "ERROR" "$@"; }
log_warn() { log_msg "$COLOR_YELLOW" "WARN" "$@"; }
log_info() { log_msg "$COLOR_GREEN" "INFO" "$@"; }
log_debug() { log_msg "$COLOR_CYAN" "DEBUG" "$@"; }

# Section header with progress indicator
log_section() {
	local current=$1 total=$2 title=$3
	if use_colors; then
		# shellcheck disable=SC2059
		printf "\n${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
		printf "${COLOR_BLUE}  [%d/%d] %s${COLOR_RESET}\n" "$current" "$total" "$title" >&2
		# shellcheck disable=SC2059
		printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
	else
		printf "\n================================================================================\n" >&2
		printf "  [%d/%d] %s\n" "$current" "$total" "$title" >&2
		printf "================================================================================\n" >&2
	fi
}

# Result status indicators
show_ok() { printf "  ${COLOR_GREEN}[✓]${COLOR_RESET} %s\n" "$*" >&2; }
show_warn() { printf "  ${COLOR_YELLOW}[!]${COLOR_RESET} %s\n" "$*" >&2; }
# shellcheck disable=SC2329
show_fail() { printf "  ${COLOR_RED}[✗]${COLOR_RESET} %s\n" "$*" >&2; }
show_skip() { printf "  ${COLOR_BLUE}[-]${COLOR_RESET} %s\n" "$*" >&2; }

# ==============================================================================
# Uninstall Steps
# ==============================================================================

step_fix_dpkg() {
	log_info "Checking dpkg state..."

	# Clean up any lock files from interrupted operations
	rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
	rm -f /var/lib/dpkg/lock 2>/dev/null || true
	rm -f /var/cache/apt/archives/lock 2>/dev/null || true

	# Reconfigure any pending packages
	if dpkg --configure -a 2>/dev/null; then
		show_ok "Dpkg state is clean"
	else
		log_warn "Dpkg had issues, continuing anyway..."
	fi

	# Fix any broken dependencies
	DEBIAN_FRONTEND=noninteractive \
		apt-get -y -qq -o Dpkg::Options::=--force-all -f install 2>/dev/null || {
		log_warn "apt-get fix had issues, continuing anyway..."
	}
}

step_ensure_git() {
	if ! command -v git >/dev/null 2>&1; then
		log_info "Installing git..."
		if apt-get -y -qq install git; then
			show_ok "Git installed"
		else
			log_error "Failed to install git"
			return 1
		fi
	else
		show_ok "Git is already installed"
	fi
}

step_cleanup_previous() {
	log_info "Cleaning up previous rapiddisk directory..."
	if [[ -d "$RAPIDDISK_DIR" ]]; then
		rm -rf "$RAPIDDISK_DIR"
		show_ok "Previous directory removed"
	else
		show_skip "No previous directory to clean"
	fi
}

step_clone_repo() {
	log_info "Cloning rapiddisk repository..."
	log_debug "Repository: $REPO_URL"
	log_debug "Target directory: $RAPIDDISK_DIR"

	cd "$HOME" || {
		log_error "Failed to change to home directory"
		return 1
	}

	if git clone --depth=1 "$REPO_URL" "$RAPIDDISK_DIR" 2>/dev/null; then
		show_ok "Repository cloned successfully"
	else
		log_error "Failed to clone repository from $REPO_URL"
		return 1
	fi
}

step_uninstall_rapiddisk() {
	log_info "Running rapiddisk uninstaller..."

	local script_path="$RAPIDDISK_DIR/scripts/rapiddisk-rootdev/rapiddisk-on-boot"

	if [[ ! -f "$script_path" ]]; then
		log_error "Uninstaller script not found at: $script_path"
		return 1
	fi

	chmod +x "$script_path"

	if "$script_path" --global-uninstall --force; then
		show_ok "Rapiddisk uninstalled from initramfs"
	else
		log_warn "Uninstaller had issues, continuing..."
	fi
}

step_cleanup_repo() {
	log_info "Removing temporary files..."

	cd "$HOME" || true

	if [[ -d "$RAPIDDISK_DIR" ]]; then
		rm -rf "$RAPIDDISK_DIR"
		show_ok "Repository cleaned up"
	else
		show_skip "No cleanup needed"
	fi
}

step_restore_fstab() {
	local primary_dev="${1-}"

	if [[ -z "$primary_dev" ]]; then
		log_info "No device specified - skipping fstab restoration"
		show_skip "No fstab changes (no device specified)"
		return 0
	fi

	local dev_to_cache="/dev/${primary_dev}"
	local mapper_path="/dev/mapper/rc-wb_${primary_dev}"

	log_info "Restoring /etc/fstab for device: $dev_to_cache"
	log_debug "Replacing '$mapper_path' with '$dev_to_cache' in /etc/fstab"

	if grep -q "$mapper_path" /etc/fstab 2>/dev/null; then
		# Create a backup first
		cp /etc/fstab "/etc/fstab.backup.rapiddisk-$(date +%Y%m%d-%H%M%S)"

		# Replace the mapper path with the actual device
		sed -i "s,${mapper_path},${dev_to_cache},g" /etc/fstab
		show_ok "fstab restored to use $dev_to_cache"
		log_warn "Original fstab backed up"
	else
		show_skip "No rapiddisk entries found in fstab"
	fi
}

step_flush_cache() {
	log_info "Flushing and removing cache mappings..."

	local flushed=0
	local failed=0
	local removed=0

	for dmrc in /dev/mapper/rc-*; do
		[[ -e "$dmrc" ]] || continue

		local name
		name=$(basename "$dmrc")
		log_info "Processing: $name"

		# Flush the cache
		if ! dmsetup message "$dmrc" 0 flush 2>/dev/null; then
			log_error "Failed to flush $name - cache data may be at risk"
			((failed++)) || true
			continue
		fi
		log_debug "Flushed $name"

		# Suspend and resume to ensure clean state
		if ! dmsetup suspend "$dmrc" 2>/dev/null; then
			log_warn "Failed to suspend $name"
		fi
		if ! dmsetup resume "$dmrc" 2>/dev/null; then
			log_warn "Failed to resume $name"
		fi

		# Check if device is still in use before attempting removal
		if dmsetup info "$dmrc" 2>/dev/null | grep -q "open.*[1-9]"; then
			log_warn "Device $name is still in use (mounted or open), skipping removal"
			((failed++)) || true
			continue
		fi

		# Remove the device mapper device
		if dmsetup remove "$dmrc" 2>/dev/null; then
			log_debug "Removed device mapper device: $name"
			((removed++)) || true
		else
			log_warn "Failed to remove device mapper device: $name"
			((failed++)) || true
		fi

		((flushed++)) || true
	done

	if [[ $flushed -gt 0 ]] && [[ $failed -eq 0 ]]; then
		show_ok "$flushed cache mapping(s) flushed and $removed device(s) removed"
	elif [[ $flushed -gt 0 ]] || [[ $removed -gt 0 ]]; then
		show_warn "$flushed cache mapping(s) flushed, $removed device(s) removed, $failed operation(s) failed"
	elif [[ $failed -gt 0 ]]; then
		show_warn "Some cache mappings could not be flushed or removed"
	else
		show_skip "No active cache mappings found"
	fi
}

step_remove_modules() {
	log_info "Removing kernel modules from /etc/modules..."

	local modules_removed=0
	for module in rapiddisk rapiddisk-cache dm-writecache; do
		if grep -q "^${module}$" /etc/modules 2>/dev/null; then
			sed -i "/^${module}$/d" /etc/modules
			log_debug "Removed $module from /etc/modules"
			((modules_removed++))
		fi
		# Also try to unload the module if it's loaded
		local mod_underscore=${module//-/_}
		if lsmod | grep -q "^${mod_underscore} " 2>/dev/null; then
			if ! timeout 5 rmmod "$mod_underscore" 2>/dev/null; then
				log_warn "Module $mod_underscore could not be unloaded (may still be in use)"
			else
				log_debug "Unloaded module: $mod_underscore"
			fi
		fi
	done

	if [[ $modules_removed -gt 0 ]]; then
		show_ok "$modules_removed module(s) removed from /etc/modules"
	else
		show_skip "No rapiddisk modules found in /etc/modules"
	fi
}

step_remove_binary() {
	log_info "Removing rapiddisk binary..."

	local binary_removed=0
	for binary_path in /sbin/rapiddisk /usr/local/sbin/rapiddisk /usr/sbin/rapiddisk; do
		if [[ -f "$binary_path" ]]; then
			rm -f "$binary_path"
			log_debug "Removed: $binary_path"
			((binary_removed++))
		fi
	done

	# Also remove rapiddiskd if present (the daemon binary)
	for daemon_path in /sbin/rapiddiskd /usr/local/sbin/rapiddiskd /usr/sbin/rapiddiskd; do
		if [[ -f "$daemon_path" ]]; then
			rm -f "$daemon_path"
			log_debug "Removed: $daemon_path"
			((binary_removed++))
		fi
	done

	if [[ $binary_removed -gt 0 ]]; then
		show_ok "$binary_removed binary(s) removed"
	else
		show_skip "No rapiddisk binaries found"
	fi
}

step_reboot() {
	log_info "Scheduling system reboot..."
	log_warn "System will reboot in 3 seconds to complete uninstallation"

	# Use nohup to ensure reboot continues even if SSH session drops
	(sleep 3 && nohup reboot &) >/dev/null 2>&1

	show_ok "Reboot scheduled"
	log_info "You can disconnect now - reboot will proceed automatically"
}

# ==============================================================================
# Main Uninstall Flow
# ==============================================================================

do_uninstall() {
	local primary_dev="${1-}"
	local total_steps=11
	local current_step=0

	log_info "Starting RapidDisk uninstallation..."

	if [[ -n "$primary_dev" ]]; then
		log_info "Device to restore in fstab: /dev/${primary_dev}"
	fi

	# Step 1: Fix dpkg state
	((current_step++))
	log_section "$current_step" "$total_steps" "Fixing Package Manager State"
	step_fix_dpkg

	# Step 2: Ensure git is available
	((current_step++))
	log_section "$current_step" "$total_steps" "Checking Prerequisites"
	step_ensure_git || {
		log_error "Prerequisites check failed"
		exit 1
	}

	# Step 3: Cleanup previous attempts
	((current_step++))
	log_section "$current_step" "$total_steps" "Cleaning Up Previous Attempts"
	step_cleanup_previous

	# Step 4: Clone repository
	((current_step++))
	log_section "$current_step" "$total_steps" "Cloning Repository"
	step_clone_repo || {
		log_error "Repository cloning failed"
		exit 1
	}

	# Step 5: Uninstall rapiddisk from initramfs
	((current_step++))
	log_section "$current_step" "$total_steps" "Removing from Initramfs"
	step_uninstall_rapiddisk || {
		log_error "Uninstallation failed"
		exit 1
	}

	# Step 6: Remove kernel modules from /etc/modules
	((current_step++))
	log_section "$current_step" "$total_steps" "Removing Kernel Module Configuration"
	step_remove_modules

	# Step 7: Remove rapiddisk binaries
	((current_step++))
	log_section "$current_step" "$total_steps" "Removing RapidDisk Binaries"
	step_remove_binary

	# Step 8: Cleanup repo
	((current_step++))
	log_section "$current_step" "$total_steps" "Cleaning Up Repository"
	step_cleanup_repo

	# Step 9: Restore fstab
	((current_step++))
	log_section "$current_step" "$total_steps" "Restoring /etc/fstab"
	step_restore_fstab "$primary_dev"

	# Step 10: Flush cache
	((current_step++))
	log_section "$current_step" "$total_steps" "Flushing Cache"
	step_flush_cache

	# Step 11: Reboot
	((current_step++))
	log_section "$current_step" "$total_steps" "Scheduling Reboot"

	echo ""
	if use_colors; then
		# shellcheck disable=SC2059
		printf "${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
		# shellcheck disable=SC2059
		printf "${COLOR_GREEN}  Uninstallation Complete!${COLOR_RESET}\n" >&2
		# shellcheck disable=SC2059
		printf "${COLOR_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
	else
		printf "================================================================================\n" >&2
		printf "  Uninstallation Complete!\n" >&2
		printf "================================================================================\n" >&2
	fi

	log_info "RapidDisk has been successfully uninstalled"
	log_info "A reboot is required to complete the process"

	step_reboot

	# Exit cleanly - reboot will happen in background
	exit 0
}

show_help() {
	cat <<EOF
Usage: sudo $0 [DEVICE_TO_CACHE]

RapidDisk RAM disk cache uninstaller for Ubuntu/Debian systems.

ARGUMENTS:
    DEVICE_TO_CACHE   Optional device name to restore in /etc/fstab
                      (e.g., sda1, nvme0n1p1)
                      If provided, replaces /dev/mapper/rc-wb_* with /dev/DEVICE

OPTIONS:
    --help, -h        Show this help message

EXAMPLES:
    sudo $0                    # Uninstall rapiddisk
    sudo $0 sda1               # Uninstall and restore /dev/sda1 in fstab
    sudo $0 nvme0n1p1          # Uninstall and restore /dev/nvme0n1p1 in fstab

WHAT THIS DOES:
    1. Fixes any interrupted package manager states
    2. Ensures git is installed
    3. Clones the rapiddisk repository
    4. Removes rapiddisk from the initramfs
    5. Removes kernel modules from /etc/modules
    6. Removes rapiddisk binaries from the system
    7. Optionally restores original device in /etc/fstab
    8. Flushes and removes any active cache mappings
    9. Reboots the system

WARNING:
    This will reboot your system automatically after uninstallation.
    The reboot will proceed even if your SSH session disconnects.

EOF
}

# ==============================================================================
# Entry Point
# ==============================================================================

main() {
	# Check for help flag
	case "${1:-}" in
	--help | -h)
		show_help
		exit 0
		;;
	esac

	# Check root privileges
	if [[ "$(id -u)" -ne 0 ]]; then
		log_error "This script must be run as root (use: sudo $0)"
		exit 1
	fi

	# Execute uninstall
	do_uninstall "$@"
}

main "$@"
