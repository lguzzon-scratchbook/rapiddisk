#!/bin/bash
#
# uRDInstall.sh - RapidDisk RAM disk cache installer for Ubuntu/Debian systems
# Usage: sudo ./uRDInstall.sh [--skip-reboot|--verify|--debug]
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

readonly CACHE_MODE="wb"
readonly MAX_RAMDISK_MB=2048
readonly RAMDISK_RATIO=5
readonly REPO_URL="https://github.com/lguzzon-scratchbook/rapiddisk"

# Git branch selection (empty means auto-detect latest between master/develop)
GIT_BRANCH=""
SKIP_BRANCH_DETECTION=false

readonly CONFIG_DIR="/etc/rapiddisk"
readonly HOOKS_DIR="/usr/share/initramfs-tools/hooks"
readonly SCRIPTS_DIR="/usr/share/initramfs-tools/scripts/local-bottom"
readonly LOCAL_BOTTOM_DIR="/usr/share/initramfs-tools/scripts/local-bottom"
# shellcheck disable=SC2034
readonly DEBUG_LOG="/var/log/rapiddisk-install.log"

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

# Log levels
readonly LOG_ERROR=0
readonly LOG_WARN=1
readonly LOG_INFO=2
readonly LOG_DEBUG=3
LOG_LEVEL=$LOG_INFO

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
	local level=$1 color=$2 label=$3
	shift 3
	local msg="$*"
	local timestamp
	timestamp=$(log_timestamp)

	if [[ $level -le $LOG_LEVEL ]]; then
		if use_colors; then
			printf "${color}[%s] %s:${COLOR_RESET} %s\n" "$timestamp" "$label" "$msg" >&2
		else
			printf "[%s] %s: %s\n" "$timestamp" "$label" "$msg" >&2
		fi
	fi
}

# Public logging functions
log_error() { log_msg $LOG_ERROR "$COLOR_RED" "ERROR" "$@"; }
log_warn() { log_msg $LOG_WARN "$COLOR_YELLOW" "WARN" "$@"; }
log_info() { log_msg $LOG_INFO "$COLOR_GREEN" "INFO" "$@"; }
log_debug() { log_msg $LOG_DEBUG "$COLOR_CYAN" "DEBUG" "$@"; }

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

# Subsection header
log_subsection() {
	if use_colors; then
		printf "${COLOR_CYAN}  → %s${COLOR_RESET}\n" "$*" >&2
	else
		printf "  → %s\n" "$*" >&2
	fi
}

# Result status indicators
show_ok() { printf "  ${COLOR_GREEN}[✓]${COLOR_RESET} %s\n" "$*" >&2; }
show_warn() { printf "  ${COLOR_YELLOW}[!]${COLOR_RESET} %s\n" "$*" >&2; }
show_fail() { printf "  ${COLOR_RED}[✗]${COLOR_RESET} %s\n" "$*" >&2; }
show_skip() { printf "  ${COLOR_BLUE}[-]${COLOR_RESET} %s\n" "$*" >&2; }
show_info() { printf "  ${COLOR_CYAN}[i]${COLOR_RESET} %s\n" "$*" >&2; }

# Non-color versions for plain output
show_ok_nc() { printf "  [OK] %s\n" "$*" >&2; }
show_warn_nc() { printf "  [WARN] %s\n" "$*" >&2; }
show_fail_nc() { printf "  [FAIL] %s\n" "$*" >&2; }
show_skip_nc() { printf "  [SKIP] %s\n" "$*" >&2; }
show_info_nc() { printf "  [INFO] %s\n" "$*" >&2; }

# Conditional status display
status_ok() { if use_colors; then show_ok "$@"; else show_ok_nc "$@"; fi; }
status_warn() { if use_colors; then show_warn "$@"; else show_warn_nc "$@"; fi; }
status_fail() { if use_colors; then show_fail "$@"; else show_fail_nc "$@"; fi; }
status_skip() { if use_colors; then show_skip "$@"; else show_skip_nc "$@"; fi; }
status_info() { if use_colors; then show_info "$@"; else show_info_nc "$@"; fi; }

# ==============================================================================
# Debug Helpers
# ==============================================================================

debug_var() {
	local name=$1
	local value
	value=$(eval "echo \$$name" 2>/dev/null || echo "<unset>")
	log_debug "$name='$value'"
}

debug_exec() {
	local cmd="$*"
	log_debug "Executing: $cmd"
	local output
	local exit_code=0
	output=$($cmd 2>&1) || exit_code=$?
	if [[ $exit_code -ne 0 ]]; then
		log_debug "Command failed with exit code $exit_code"
	fi
	if [[ -n "$output" ]]; then
		log_debug "Output: $output"
	fi
	return $exit_code
}

# ==============================================================================
# Embedded Script Templates
# ==============================================================================

# shellcheck disable=SC2016
readonly HOOK_TEMPLATE='#!/bin/sh
# Debug: rapiddisk initramfs hook script
# This runs during initramfs creation
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac

DEBUG_LOG="/var/log/rapiddisk-hook.log"
mkdir -p /var/log/rapiddisk 2>/dev/null || true

log_hook() {
    echo "$(date +%H:%M:%S) [HOOK] $1" | tee -a "$DEBUG_LOG" 2>/dev/null || true
}

. /usr/share/initramfs-tools/hook-functions

config_dir="CONFIG_DIR"
config_file="${config_dir}/rapiddisk_kernel_${version}"

log_hook "Starting hook for kernel: $version"
log_hook "Config file: $config_file"

if [ ! -f "$config_file" ]; then
    log_hook "ERROR: Config file not found: $config_file"
    exit 0
fi

log_hook "Reading config from $config_file"
size="$(head -n 1 "$config_file")" || { log_hook "ERROR: Failed to read size"; exit 0; }
device="$(sed -n "2p" "$config_file")" || { log_hook "ERROR: Failed to read device"; exit 0; }
cache_mode="$(tail -n 1 "$config_file")" || { log_hook "ERROR: Failed to read cache_mode"; exit 0; }

log_hook "Config: size=$size device=$device mode=$cache_mode"

cwd="$(dirname "$0")"
log_hook "Creating boot script in $cwd"

sed "s|%%SIZE%%|${size}|g; s|%%DEVICE%%|${device}|g; s|%%MODE%%|${cache_mode}|g" \
    "${config_dir}/rapiddisk_sub.orig" > "${cwd}/rapiddisk_sub" || { log_hook "ERROR: sed failed"; exit 0; }

chmod +x "${cwd}/rapiddisk_sub" || { log_hook "ERROR: chmod failed"; exit 0; }

log_hook "Adding modules: rapiddisk rapiddisk-cache"
manual_add_modules rapiddisk rapiddisk-cache || log_hook "WARNING: manual_add_modules rapiddisk failed"
[ "$cache_mode" = "wb" ] && { log_hook "Adding dm-writecache for wb mode"; manual_add_modules dm-writecache || log_hook "WARNING: manual_add_modules dm-writecache failed"; }

log_hook "Copying rapiddisk binary"
copy_exec /sbin/rapiddisk /sbin/rapiddisk || log_hook "WARNING: copy_exec rapiddisk failed"

log_hook "Copying boot script"
copy_file binary "${cwd}/rapiddisk_sub" /sbin/ || { log_hook "ERROR: copy_file failed"; exit 0; }

rm -f "${cwd}/rapiddisk_sub" || log_hook "WARNING: cleanup failed"

log_hook "Hook completed successfully"
exit 0'

# shellcheck disable=SC2016
readonly BOOT_TEMPLATE='#!/bin/sh
# Debug: rapiddisk boot script
# This runs during early boot (local-bottom)
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac

DEBUG_LOG="/var/log/rapiddisk-boot.log"
mkdir -p /var/log/rapiddisk 2>/dev/null || true

log_boot() {
    echo "$(date +%H:%M:%S) [BOOT] $1" | tee -a "$DEBUG_LOG" 2>/dev/null || true
    log_warning_msg "[rapiddisk] $1"
}

. /scripts/functions

log_boot "Starting boot script"

if [ -x /sbin/rapiddisk_sub ]; then
    log_boot "Executing /sbin/rapiddisk_sub"
    _tmpfile="/tmp/rapiddisk_boot_output_$$"
    if /sbin/rapiddisk_sub >"$_tmpfile" 2>&1; then
        RESULT=0
    else
        RESULT=$?
    fi
    while read -r line || [ -n "$line" ]; do
        log_boot "$line"
    done < "$_tmpfile"
    rm -f "$_tmpfile"
    if [ $RESULT -eq 0 ]; then
        log_boot "rapiddisk_sub completed successfully"
    else
        log_boot "ERROR: rapiddisk_sub failed with code $RESULT"
    fi
else
    log_boot "ERROR: /sbin/rapiddisk_sub not found or not executable"
    log_boot "Run: ls -la /sbin/rapiddisk* 2>&1"
    ls -la /sbin/rapiddisk* 2>&1 | while read line; do log_boot "$line"; done
fi

log_boot "Boot script finished"
exit 0'

readonly CLEAN_TEMPLATE='#!/bin/sh
# Debug: rapiddisk cleanup script
# This runs during late boot (local-bottom) to clean up unmapped ramdisks
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0 ;; esac

DEBUG_LOG="/var/log/rapiddisk-clean.log"
mkdir -p /var/log/rapiddisk 2>/dev/null || true

log_clean() {
    echo "$(date +%H:%M:%S) [CLEAN] $1" | tee -a "$DEBUG_LOG" 2>/dev/null || true
    log_warning_msg "[rapiddisk-clean] $1"
}

. /scripts/functions

log_clean "Starting cleanup"

if ! command -v rapiddisk >/dev/null 2>&1; then
    log_clean "ERROR: rapiddisk command not found"
    exit 0
fi

log_clean "Querying rapiddisk devices..."
cache="$(rapiddisk -l 2>&1)" || { log_clean "ERROR: rapiddisk -l failed: $cache"; exit 0; }
log_clean "Output: $cache"

ramdisks="$(echo "$cache" | grep -oE "rd[0-9]+" | sort -u)" || true
mapped="$(echo "$cache" | grep -oE "rc-[a-z]+[0-9]*_rd[0-9]+" | grep -oE "rd[0-9]+" | sort -u)" || true

log_clean "Found ramdisks: $ramdisks"
log_clean "Found mapped: $mapped"

for rd in $ramdisks; do
    if ! echo "$mapped" | grep -qx "$rd"; then
        log_clean "Deleting unmapped ramdisk: $rd"
        rapiddisk -d "$rd" 2>&1 | while read line; do log_clean "  $line"; done
    else
        log_clean "Keeping mapped ramdisk: $rd"
    fi
done

log_clean "Cleanup completed"
exit 0'

readonly SUB_TEMPLATE='#!/bin/sh
# Debug: rapiddisk startup script
# This creates the ramdisk and cache mapping
DEBUG_LOG="/var/log/rapiddisk-sub.log"
mkdir -p /var/log/rapiddisk 2>/dev/null || true

log_sub() {
    echo "$(date +%H:%M:%S) [SUB] $1" | tee -a "$DEBUG_LOG" 2>/dev/null || true
}

. /scripts/functions

log_sub "========================================="
log_sub "rapiddisk: Starting (size: %%SIZE%% MB, device: %%DEVICE%%, mode: %%MODE%%)"
log_sub "========================================="

# Step 1: Load dm-writecache if writeback mode
if [ "%%MODE%%" = "wb" ]; then
    log_sub "Step 1: Loading dm-writecache module..."
    if ! modprobe -q dm-writecache 2>&1; then
        log_sub "ERROR: dm-writecache module load failed"
        log_failure_msg "rapiddisk: dm-writecache unavailable"
        exit 1
    fi
    log_sub "SUCCESS: dm-writecache loaded"
fi

# Step 2: Load rapiddisk module
log_sub "Step 2: Loading rapiddisk module..."
if ! modprobe -q rapiddisk 2>&1; then
    log_sub "ERROR: rapiddisk module load failed"
    log_failure_msg "rapiddisk: module load failed"
    exit 1
fi
log_sub "SUCCESS: rapiddisk loaded"

# Step 3: Load rapiddisk-cache module
log_sub "Step 3: Loading rapiddisk-cache module..."
if ! modprobe -q rapiddisk-cache 2>&1; then
    log_sub "ERROR: rapiddisk-cache module load failed"
    log_failure_msg "rapiddisk: cache module failed"
    exit 1
fi
log_sub "SUCCESS: rapiddisk-cache loaded"

# Step 4: Verify /sys/kernel/rapiddisk/mgmt exists
log_sub "Step 4: Verifying rapiddisk sysfs..."
if [ ! -w /sys/kernel/rapiddisk/mgmt ]; then
    log_sub "ERROR: /sys/kernel/rapiddisk/mgmt not available or not writable"
    log_failure_msg "rapiddisk: sysfs not available"
    exit 1
fi
log_sub "SUCCESS: sysfs available"

# Step 5: Create ramdisk
log_sub "Step 5: Creating ramdisk (%%SIZE%% MB)..."
attach_output="$(rapiddisk -a %%SIZE%% 2>&1)" || {
    log_sub "ERROR: rapiddisk attach failed: $attach_output"
    log_failure_msg "rapiddisk: ramdisk creation failed"
    exit 1
}
log_sub "SUCCESS: $attach_output"

# Step 6: Map to block device
log_sub "Step 6: Mapping rd0 to %%DEVICE%% (mode: %%MODE%%)..."
map_output="$(rapiddisk -m rd0 -b %%DEVICE%% -p %%MODE%% 2>&1)" || {
    log_sub "WARNING: First mapping attempt failed: $map_output"
    log_sub "Step 6b: Retry with workaround..."

    log_sub "  Creating small temp ramdisk..."
    rapiddisk -a 5 2>&1 || true

    log_sub "  Deleting rd0..."
    rapiddisk -d rd0 2>&1 || true

    log_sub "  Recreating %%SIZE%% MB ramdisk..."
    attach_output2="$(rapiddisk -a %%SIZE%% 2>&1)" || {
        log_sub "ERROR: Retry ramdisk creation failed: $attach_output2"
        log_failure_msg "rapiddisk: retry ramdisk failed"
        exit 1
    }

    log_sub "  Retrying mapping..."
    map_output="$(rapiddisk -m rd0 -b %%DEVICE%% -p %%MODE%% 2>&1)" || {
        log_sub "ERROR: Mapping retry failed: $map_output"
        rapiddisk -d rd0 2>/dev/null || true
        rapiddisk -d rd1 2>/dev/null || true
        log_failure_msg "rapiddisk: mapping failed"
        exit 1
    }
}

log_sub "SUCCESS: $map_output"

# Step 7: Verify mapping exists
log_sub "Step 7: Verifying cache mapping..."
if [ -e /dev/mapper/rc-wt_%%DEVICE%% ] || [ -e /dev/mapper/rc-wb_%%DEVICE%% ] || [ -e /dev/mapper/rc-wa_%%DEVICE%% ]; then
    log_sub "SUCCESS: Cache device created"
    ls -la /dev/mapper/rc-* 2>&1 | while read line; do log_sub "  $line"; done
else
    log_sub "WARNING: No cache device found in /dev/mapper"
    ls -la /dev/mapper/ 2>&1 | while read line; do log_sub "  $line"; done
fi

log_sub "========================================="
log_sub "rapiddisk: Startup completed successfully"
log_sub "========================================="

log_end_msg 0
exit 0'

# ==============================================================================
# Helper Functions
# ==============================================================================

check_root() {
	log_debug "Checking root privileges..."
	if [[ "$(id -u)" -ne 0 ]]; then
		log_error "This script must be run as root (use: sudo $0)"
		exit 1
	fi
	log_debug "Root check passed"
}

get_kernel_version() {
	uname -r
}

# Detect the most recently updated branch between master and develop
get_latest_branch() {
	local repo_url=$1
	local latest_branch="master"
	local master_sha develop_sha

	log_debug "Detecting latest branch from $repo_url..."

	# Fetch commit SHAs for both branches using git ls-remote
	master_sha=$(git ls-remote --heads "$repo_url" refs/heads/master 2>/dev/null | awk '{print $1}' | head -1) || master_sha=""
	develop_sha=$(git ls-remote --heads "$repo_url" refs/heads/develop 2>/dev/null | awk '{print $1}' | head -1) || develop_sha=""

	# Fallback to main if master doesn't exist
	if [[ -z "$master_sha" ]]; then
		log_debug "master branch not found, trying main..."
		master_sha=$(git ls-remote --heads "$repo_url" refs/heads/main 2>/dev/null | awk '{print $1}' | head -1) || master_sha=""
		if [[ -n "$master_sha" ]]; then
			latest_branch="main"
		fi
	fi

	# Handle cases where develop doesn't exist
	if [[ -z "$develop_sha" ]]; then
		log_debug "develop branch not found"
		[[ -n "$master_sha" ]] && {
			echo "$latest_branch"
			return 0
		}
		echo "master"
		return 1
	fi

	# If only develop exists
	if [[ -z "$master_sha" && -n "$develop_sha" ]]; then
		echo "develop"
		return 0
	fi

	# If neither branch exists, fail early with clear message
	if [[ -z "$master_sha" && -z "$develop_sha" ]]; then
		log_error "Could not detect any valid branches (master/main/develop) in $repo_url"
		log_info "Please check the repository URL or use --branch to specify explicitly"
		return 1
	fi

	log_debug "Latest $latest_branch commit: ${master_sha:0:8}"
	log_debug "Latest develop commit: ${develop_sha:0:8}"

	# Use GitHub API to get commit dates for comparison (works for GitHub repos)
	if [[ "$repo_url" == *"github.com"* ]]; then
		local api_base repo_path
		repo_path=$(echo "$repo_url" | sed 's/.*github.com[:/]//; s/\.git$//')
		api_base="https://api.github.com/repos/${repo_path}"

		local master_date develop_date

		# Query commit details for master/main branch
		local master_api_response
		master_api_response=$(curl -sL --max-time 5 --connect-timeout 3 "${api_base}/commits/${latest_branch}" 2>/dev/null || true)
		if [[ -n "$master_api_response" ]]; then
			master_date=$(echo "$master_api_response" | grep '"date":' | head -1 | sed 's/.*"date": "\([^"]*\)".*/\1/')
		fi
		# Validate extracted date format (ISO 8601)
		if [[ -n "$master_date" && ! "$master_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
			log_debug "Invalid date format from API for ${latest_branch}: $master_date"
			master_date=""
		fi

		# Query commit details for develop branch
		local develop_api_response
		develop_api_response=$(curl -sL --max-time 5 --connect-timeout 3 "${api_base}/commits/develop" 2>/dev/null || true)
		if [[ -n "$develop_api_response" ]]; then
			develop_date=$(echo "$develop_api_response" | grep '"date":' | head -1 | sed 's/.*"date": "\([^"]*\)".*/\1/')
		fi
		# Validate extracted date format (ISO 8601)
		if [[ -n "$develop_date" && ! "$develop_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
			log_debug "Invalid date format from API for develop: $develop_date"
			develop_date=""
		fi

		log_debug "${latest_branch} commit date: ${master_date:-unknown}"
		log_debug "develop commit date: ${develop_date:-unknown}"

		# Check if we got any dates back from API
		if [[ -z "$master_date" && -z "$develop_date" ]]; then
			log_warn "Could not retrieve commit dates from GitHub API (rate limited or API error)"
			log_debug "Falling back to default branch: $latest_branch"
		fi

		# Compare dates if both are available (ISO 8601 format comparison works lexicographically)
		if [[ -n "$master_date" && -n "$develop_date" ]]; then
			if [[ "$develop_date" > "$master_date" ]]; then
				latest_branch="develop"
			fi
		fi
	else
		# For non-GitHub repos, fall back to a simple heuristic
		# This could be enhanced for other git hosting services
		log_debug "Non-GitHub repository - using default branch: $latest_branch"
	fi

	# Warn if auto-detection selected develop branch
	if [[ "$latest_branch" == "develop" ]]; then
		log_warn "Auto-detection selected 'develop' branch which may contain unstable code"
		log_info "Use --branch master to use the stable branch, or --no-branch-detect to skip detection"
	fi

	log_info "Using latest branch: $latest_branch"
	echo "$latest_branch"
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
	findmnt -n -o SOURCE / 2>/dev/null || df / | awk 'NR==2 {print $1}'
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

ensure_module() {
	local module=$1
	log_debug "Ensuring module '$module' is loaded..."
	if ! grep -qx "$module" /etc/modules 2>/dev/null; then
		log_debug "Adding $module to /etc/modules"
		echo "$module" >>/etc/modules
	fi
	if ! lsmod | grep -q "^${module//-/_} "; then
		log_debug "Loading module '$module'..."
		modprobe "$module" 2>/dev/null || log_warn "Could not load module '$module' (may need rebuild)"
	fi
}

install_dependencies() {
	log_info "Updating package lists..."
	export DEBIAN_FRONTEND=noninteractive
	export DEBIAN_PRIORITY=critical

	# Clean up any previous interrupted apt operations
	dpkg --configure -a 2>/dev/null || {
		log_warn "dpkg configure had issues, attempting cleanup..."
	}
	rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true

	log_debug "Running apt-get update..."
	if ! apt-get update -qq; then
		log_error "Failed to update package lists"
		return 1
	fi

	log_info "Installing build dependencies..."
	local pkgs="libpcre2-dev libdevmapper-dev libjansson-dev libmicrohttpd-dev git build-essential"
	log_debug "Packages to install: $pkgs"

	# shellcheck disable=SC2086
	if ! apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install $pkgs; then
		log_error "Failed to install dependencies"
		return 1
	fi

	log_info "Installing/verifying kernel headers..."
	local kernel
	kernel=$(get_kernel_version)
	apt-mark unhold linux-image-* linux-headers-* linux-modules-* 2>/dev/null || true

	if ! apt-get -y -qq install --reinstall "linux-image-${kernel}" "linux-headers-${kernel}" \
		"linux-modules-${kernel}" "linux-modules-extra-${kernel}" 2>/dev/null; then
		log_warn "Some kernel packages may not be available, continuing..."
	fi

	apt-mark hold linux-image-* linux-headers-* linux-modules-* 2>/dev/null || true
	log_debug "Dependencies installed successfully"
}

build_rapiddisk() {
	local build_dir="/tmp/rapiddisk-build-$$"
	local branch="$GIT_BRANCH"

	# Auto-detect latest branch if not explicitly specified
	if [[ -z "$branch" && "$SKIP_BRANCH_DETECTION" != true ]]; then
		log_info "Auto-detecting latest branch..."
		branch=$(get_latest_branch "$REPO_URL") || branch="master"
	elif [[ -z "$branch" ]]; then
		branch="master"
	fi

	log_info "Cloning rapiddisk repository (branch: $branch)..."
	log_debug "Build directory: $build_dir"
	log_debug "Target branch: $branch"

	rm -rf "$build_dir"
	mkdir -p "$build_dir"

	if ! git clone --depth=1 --branch="$branch" "$REPO_URL" "$build_dir" 2>/dev/null; then
		log_error "Failed to clone repository from $REPO_URL (branch: $branch)"
		rm -rf "$build_dir"
		return 1
	fi
	log_debug "Repository cloned successfully from $branch branch"

	log_info "Building rapiddisk from source..."
	cd "$build_dir"

	make clean 2>/dev/null || true

	log_debug "Running make..."
	if ! make; then
		log_error "Build failed - check compiler output above"
		cd - >/dev/null
		rm -rf "$build_dir"
		return 1
	fi
	log_debug "Build completed successfully"

	log_info "Installing rapiddisk binary..."
	if ! make install; then
		log_error "Install failed"
		cd - >/dev/null
		rm -rf "$build_dir"
		return 1
	fi

	cd - >/dev/null
	rm -rf "$build_dir"

	if ! command -v rapiddisk >/dev/null 2>&1; then
		log_error "rapiddisk binary not found in PATH after install"
		return 1
	fi

	local version
	version=$(rapiddisk -v 2>&1 | head -1)
	log_info "Installed: $version"
}

backup_initramfs() {
	local kernel=$1
	local backup_suffix
	backup_suffix=".backup.rapiddisk-$(date +%Y%m%d-%H%M%S)"
	local initramfs_path="/boot/initrd.img-${kernel}"

	if [[ -f "$initramfs_path" ]]; then
		log_info "Creating initramfs backup..."
		if cp "$initramfs_path" "${initramfs_path}${backup_suffix}"; then
			status_ok "Backup created: ${initramfs_path}${backup_suffix}"
		else
			log_warn "Failed to create backup of initramfs"
		fi
	else
		log_warn "Initramfs not found at $initramfs_path"
	fi
}

install_initramfs_scripts() {
	local kernel_version=$1 ramdisk_size=$2 root_device=$3

	log_debug "Creating config directory: $CONFIG_DIR"
	mkdir -p "$CONFIG_DIR" || {
		log_error "Cannot create $CONFIG_DIR"
		return 1
	}

	log_info "Installing initramfs hook script..."
	printf '%s\n' "$HOOK_TEMPLATE" | sed "s|CONFIG_DIR|$CONFIG_DIR|g" >"${HOOKS_DIR}/rapiddisk_hook"
	chmod +x "${HOOKS_DIR}/rapiddisk_hook"
	status_ok "Hook script installed"

	log_info "Installing boot script..."
	printf '%s\n' "$BOOT_TEMPLATE" >"${SCRIPTS_DIR}/rapiddisk_boot"
	chmod +x "${SCRIPTS_DIR}/rapiddisk_boot"
	status_ok "Boot script installed"

	log_info "Installing cleanup script..."
	mkdir -p "$LOCAL_BOTTOM_DIR" || true
	printf '%s\n' "$CLEAN_TEMPLATE" >"${LOCAL_BOTTOM_DIR}/rapiddisk_clean"
	chmod +x "${LOCAL_BOTTOM_DIR}/rapiddisk_clean"
	status_ok "Cleanup script installed"

	log_info "Installing template script..."
	printf '%s\n' "$SUB_TEMPLATE" >"${CONFIG_DIR}/rapiddisk_sub.orig"
	chmod -x "${CONFIG_DIR}/rapiddisk_sub.orig"
	status_ok "Template script installed"

	log_debug "Creating kernel config file..."
	local config_file="${CONFIG_DIR}/rapiddisk_kernel_${kernel_version}"
	printf '%s\n%s\n%s\n' "$ramdisk_size" "$root_device" "$CACHE_MODE" >"$config_file"
	status_ok "Kernel config: $config_file"

	log_debug "Config contents: size=$ramdisk_size, device=$root_device, mode=$CACHE_MODE"
}

update_initramfs() {
	local kernel_version=$1
	log_info "Regenerating initramfs for kernel ${kernel_version}..."

	if update-initramfs -u -k "$kernel_version"; then
		status_ok "Initramfs updated successfully"
	else
		log_error "Failed to update initramfs"
		return 1
	fi
}

# ==============================================================================
# Main Functions
# ==============================================================================

show_configuration() {
	local ramdisk_size=$1 root_device=$2 kernel_version=$3

	echo ""
	if use_colors; then
		# shellcheck disable=SC2059
		printf "${COLOR_BLUE}┌────────────────────────────────────────────────────────────────────────────┐${COLOR_RESET}\n" >&2
		# shellcheck disable=SC2059
		printf "${COLOR_BLUE}│ Configuration Summary                                                      │${COLOR_RESET}\n" >&2
		# shellcheck disable=SC2059
		printf "${COLOR_BLUE}├────────────────────────────────────────────────────────────────────────────┤${COLOR_RESET}\n" >&2
		printf "${COLOR_BLUE}│${COLOR_RESET}  RAM disk size: ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${ramdisk_size} MB" >&2
		printf "${COLOR_BLUE}│${COLOR_RESET}  Root device:   ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${root_device}" >&2
		printf "${COLOR_BLUE}│${COLOR_RESET}  Cache mode:    ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${CACHE_MODE}" >&2
		printf "${COLOR_BLUE}│${COLOR_RESET}  Kernel:        ${COLOR_GREEN}%-56s${COLOR_BLUE}│${COLOR_RESET}\n" "${kernel_version}" >&2
		# shellcheck disable=SC2059
		printf "${COLOR_BLUE}└────────────────────────────────────────────────────────────────────────────┘${COLOR_RESET}\n" >&2
	else
		printf "================================================================================\n" >&2
		printf "Configuration Summary\n" >&2
		printf "================================================================================\n" >&2
		printf "  RAM disk size: %s MB\n" "$ramdisk_size" >&2
		printf "  Root device:   %s\n" "$root_device" >&2
		printf "  Cache mode:    %s\n" "$CACHE_MODE" >&2
		printf "  Kernel:        %s\n" "$kernel_version" >&2
		printf "================================================================================\n" >&2
	fi
	echo ""
}

do_install() {
	local skip_reboot=${1:-false}
	local total_steps=7
	local current_step=0

	check_root

	# Gather configuration
	local ramdisk_size root_device kernel_version
	ramdisk_size=$(calculate_ramdisk_size)
	root_device=$(get_root_device)
	kernel_version=$(get_kernel_version)

	log_debug "Configuration gathered:"
	debug_var "ramdisk_size"
	debug_var "root_device"
	debug_var "kernel_version"

	show_configuration "$ramdisk_size" "$root_device" "$kernel_version"
	validate_environment "$ramdisk_size"

	# Step 1: Dependencies
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Installing Dependencies"
	install_dependencies || {
		log_error "Dependency installation failed"
		exit 1
	}

	# Step 2: Kernel modules
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Configuring Kernel Modules"
	log_info "Loading required kernel modules..."
	ensure_module "rapiddisk"
	ensure_module "rapiddisk-cache"
	ensure_module "dm-writecache"
	status_ok "Kernel modules configured"

	# Step 3: Build
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Building RapidDisk"
	build_rapiddisk || {
		log_error "Build failed"
		exit 1
	}

	# Step 4: Backup
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Backing Up Initramfs"
	backup_initramfs "$kernel_version"

	# Step 5: Install scripts
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Installing Initramfs Scripts"
	install_initramfs_scripts "$kernel_version" "$ramdisk_size" "$root_device" || {
		log_error "Script installation failed"
		exit 1
	}

	# Step 6: Update initramfs
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Updating Initramfs"
	update_initramfs "$kernel_version" || {
		log_error "Initramfs update failed"
		exit 1
	}

	# Step 7: Complete
	((current_step++)) || true
	log_section "$current_step" "$total_steps" "Installation Complete"

	log_info "RapidDisk has been successfully installed!"
	echo ""
	status_info "RAM disk size: ${ramdisk_size} MB"
	status_info "Root device: ${root_device}"
	status_info "Kernel: ${kernel_version}"
	echo ""

	if [[ "$skip_reboot" == true ]]; then
		log_warn "Skipping reboot as requested (--skip-reboot)"
		log_info "To activate the RAM disk cache, reboot manually with: sudo reboot"
		log_info "After reboot, verify with: sudo $0 --verify"
	else
		log_info "System will reboot in 3 seconds to activate the RAM disk cache..."
		log_info "After reboot, verify with: sudo $0 --verify"
		sleep 3
		reboot
	fi
}

do_verify() {
	local issues=0
	local rd_count=0 cache_count=0
	local total_checks=7

	log_section "1" "$total_checks" "Kernel Module Status"
	for mod in rapiddisk rapiddisk-cache dm-writecache; do
		local mod_underscore=${mod//-/_}
		if lsmod | grep -q "^${mod_underscore} "; then
			status_ok "${mod} - loaded"
		else
			status_warn "${mod} - not loaded"
			((issues++)) || true
		fi
	done

	log_section "2" "$total_checks" "Module Configuration (/etc/modules)"
	if grep -q "rapiddisk" /etc/modules &&
		grep -q "rapiddisk-cache" /etc/modules &&
		grep -q "dm-writecache" /etc/modules; then
		status_ok "All modules configured in /etc/modules"
	else
		status_warn "Modules not fully configured in /etc/modules"
		((issues++)) || true
	fi

	log_section "3" "$total_checks" "Binary Installation"
	if command -v rapiddisk >/dev/null 2>&1; then
		local version
		version=$(rapiddisk -v 2>&1 | head -1)
		status_ok "rapiddisk installed: $version"
	else
		status_fail "rapiddisk binary not found in PATH"
		((issues++)) || true
	fi

	log_section "4" "$total_checks" "RAM Disk Devices"
	if command -v rapiddisk >/dev/null 2>&1; then
		rd_count=$(rapiddisk -l 2>/dev/null | grep -cE "rd[0-9]+" || echo 0)
		if [[ "$rd_count" -gt 0 ]]; then
			status_ok "$rd_count RAM disk device(s) found"
			rapiddisk -l | grep -E "rd[0-9]+" | sed 's/^/       /' >&2
		else
			status_warn "No RAM disk devices found"
			((issues++)) || true
		fi
	else
		status_skip "Binary not available - check skipped"
	fi

	log_section "5" "$total_checks" "Cache Mappings"
	cache_count=0
	shopt -s nullglob
	for f in /dev/mapper/rc-*; do
		[[ -e "$f" ]] || continue
		((cache_count++)) || true
	done
	shopt -u nullglob
	if [[ "$cache_count" -gt 0 ]]; then
		status_ok "$cache_count cache mapping(s) active"
		for f in /dev/mapper/rc-*; do
			[[ -e "$f" ]] || continue
			printf '       %s\n' "${f##*/}" >&2
		done
	else
		status_warn "No active cache mappings"
		((issues++)) || true
	fi

	log_section "6" "$total_checks" "Kernel Configuration"
	local kernel_version
	kernel_version=$(get_kernel_version)
	local config_file="${CONFIG_DIR}/rapiddisk_kernel_${kernel_version}"
	if [[ -f "$config_file" ]]; then
		local size
		size=$(head -1 "$config_file")
		status_ok "Config exists for ${kernel_version}"
		status_info "Configured size: ${size} MB"
	else
		status_warn "No config found for ${kernel_version}"
		((issues++)) || true
	fi

	log_section "7" "7" "Debug Logs"
	local debug_logs=0
	local has_errors=0
	shopt -s nullglob
	for log in /var/log/rapiddisk*.log; do
		((debug_logs++)) || true
		if grep -qE "ERROR|FAILED|failed" "$log" 2>/dev/null; then
			((has_errors++)) || true
			status_warn "Errors found in: ${log##*/}"
		else
			status_ok "${log##*/} - OK"
		fi
	done
	shopt -u nullglob
	if [[ $debug_logs -eq 0 ]]; then
		status_warn "No debug logs found (scripts may not have run)"
	elif [[ $has_errors -gt 0 ]]; then
		status_info "View errors with: sudo cat /var/log/rapiddisk*.log"
		((issues++)) || true
	else
		status_info "All debug logs clean"
	fi

	# Summary
	echo ""
	if use_colors; then
		# shellcheck disable=SC2059
		printf "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n" >&2
	else
		printf "================================================================================\n" >&2
	fi

	if [[ "$rd_count" -gt 0 ]] && [[ "$cache_count" -gt 0 ]]; then
		log_info "Status: FULLY CONFIGURED - RAM disk cache is active"
		return 0
	elif [[ "$rd_count" -gt 0 ]]; then
		log_warn "Status: PARTIALLY CONFIGURED - RAM disk present but no cache mapping"
		log_info "A reboot may be needed to complete the configuration"
		return 0
	else
		log_error "Status: NOT CONFIGURED - Reboot required or installation failed"
		log_info "Run: sudo $0 --skip-reboot to install without reboot, then reboot manually"
		return 1
	fi
}

show_help() {
	cat <<EOF
Usage: sudo $0 [OPTIONS]

RapidDisk RAM disk cache installer for Ubuntu/Debian systems.

OPTIONS:
    (none)              Install rapiddisk and reboot automatically
    --skip-reboot       Install without rebooting (manual reboot required)
    --verify            Verify installation status and check configuration
    --logs              View debug logs from last boot
    --debug             Enable debug output for troubleshooting
    --branch, -b NAME   Explicitly specify git branch to use (opt-in)
    --no-branch-detect  Skip auto-detection and use default 'master' branch
    --help, -h          Show this help message

BRANCH SELECTION:
    By default, the script auto-detects the most recently updated branch
    between 'master' and 'develop' (or 'main' and 'develop'). Use --branch
    to explicitly specify a branch, or --no-branch-detect to always use
    the default 'master' branch.

EXAMPLES:
    sudo $0                       # Install with auto-detected branch
    sudo $0 --skip-reboot         # Install without rebooting
    sudo $0 --verify              # Check installation status
    sudo $0 --debug               # Install with verbose debug output
    sudo $0 --branch develop      # Use develop branch explicitly
    sudo $0 -b master             # Use master branch explicitly
    sudo $0 --no-branch-detect    # Always use default master branch

FILES:
    /etc/rapiddisk/             # Configuration directory
    /boot/initrd.img-*          # Initramfs images (backups created)

For more information, see: https://github.com/pkoutoupis/rapiddisk

EOF
}

# ==============================================================================
# Entry Point
# ==============================================================================

main() {
	local skip_reboot=false
	local do_verify_only=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--debug)
			LOG_LEVEL=$LOG_DEBUG
			log_warn "Debug mode enabled - command traces may contain sensitive information"
			set -x # Also enable shell trace
			shift
			;;
		--skip-reboot)
			skip_reboot=true
			log_debug "Skip reboot enabled"
			shift
			;;
		--verify)
			do_verify_only=true
			log_debug "Verify mode enabled"
			shift
			;;
		--logs)
			log_info "=== Debug Logs ==="
			shopt -s nullglob
			for log in /var/log/rapiddisk*.log; do
				echo ""
				echo "=== $log ==="
				cat "$log"
			done
			shopt -u nullglob
			if [[ $# -le 1 ]]; then
				exit 0
			fi
			shift
			;;
		--branch | -b)
			if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
				GIT_BRANCH="$2"
				log_debug "Explicit branch specified: $GIT_BRANCH"
				shift 2
			else
				log_error "Option --branch requires an argument"
				exit 1
			fi
			;;
		--no-branch-detect)
			SKIP_BRANCH_DETECTION=true
			log_debug "Branch auto-detection disabled"
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
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
	else
		do_install "$skip_reboot"
	fi
}

main "$@"
