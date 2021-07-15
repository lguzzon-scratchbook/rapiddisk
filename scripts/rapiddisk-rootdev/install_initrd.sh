#!/bin/bash

ihelp()  {

	echo "Usage:"
	echo "$(basename "$0") --help"
	echo "$(basename "$0") --install --root=<root_partition> --size=<ramdisk_size> --kernel=<kernel_version> [--force]"
	echo "$(basename "$0") --uninstall --kernel=<kernel_version> [--force]"
	echo "$(basename "$0") --global-uninstall"
	echo ""
	echo "Where:"
	echo ""
	echo "--help           prints this help and exit"
	echo ""
	echo "in '--install' mode:"
	echo "<root_partition> is the device mounted as '/' as in /etc/fstab, in the /dev/xxxn format"
	echo "                 if not provided, /etc/fstab will be parsed to determine it automatically"
	echo "                 and you'll be asked to confirm"
	echo "<ramdisk_size>   is the size in MB of the ramdisk to be used as cache"
	echo "<kernel_version> is needed to determine which initrd file to alter"
	echo "--force		   even if everything is already in place, force reinstalling."
	echo "                 Can be useful to change the ramdisk size without perform an uninstall"
	echo ""
	echo "in '--uninstall' mode:"
	echo "<kernel_version> is needed to determine which initrd file to alter. Other initrd files are left intact"
	echo "--force          perform the uninstall actions even if there is nothing to remove"
	echo ""
	echo "in '--global-uninstall' mode:"
	echo "                 everything ever installed by the script will be removed once and for all"
	echo "                 all the initrd files will be rebuild"
	echo ""
	echo "Note: kernel_version is really important: if you end up with a system that"
	echo "cannot boot, you can choose another kernel version from the grub menu,"
	echo "boot successfully, and use the --uninstall command with the <kernel_version> of"
	echo "the non-booting kernel to restore it."
	echo ""
	echo "You can usually try 'uname -r' to obtain the current kernel version."
	echo ""

}

is_num()  {

	[ "$1" ] && [ -z "${1//[0-9]/}" ]

} # Credits: https://stackoverflow.com/questions/806906/how-do-i-test-if-a-variable-is-a-number-in-bash

myerror()  {

	echo "**** Error: $1 Exiting..."
	exit 1

}

centos_install () {

	echo " - Creating module's dir..."
	mkdir -p "${module_destination}/${module_name}"
	echo " - Copying module's files in place..."
	cp -f "${cwd}/${os_name}/${module_name}/run_rapiddisk.sh.orig" "${module_destination}/${module_name}/"
	cp -f "${cwd}/${os_name}/${module_name}/module-setup.sh" "${module_destination}/${module_name}/"
	echo " - chmod module's files..."
	chmod +x "${module_destination}/${module_name}/module-setup.sh"
	chmod -x "${module_destination}/${module_name}/run_rapiddisk.sh.orig"
	echo " - Activating rapiddisk for kernel version ${kernel_version}."
	echo >"${module_destination}/${module_name}/${kernel_version_file}" "${ramdisk_size}"
	echo >>"${module_destination}/${module_name}/${kernel_version_file}" "${root_device}"

}

centos_end () {

	echo " - Running 'dracut --kver $kernel_version -f'"
	dracut --kver "$kernel_version" -f
	echo " - Done under CentOS. A reboot is needed."

}

ubuntu_install () {

	echo " - Creating kernel options file ..."
	echo >"${hooks_dir}/${kernel_version_file}" "${ramdisk_size}"
	echo >>"${hooks_dir}/${kernel_version_file}" "${root_device}"
	
	echo " - Copying ${cwd}/ubuntu/rapiddisk_hook to ${hook_dest}..."
	if ! cp -f "${cwd}/ubuntu/rapiddisk_hook" "${hook_dest}" ; then
		myerror "could not copy rapiddisk_hook to ${hook_dest}."
	fi
	chmod +x "${hook_dest}" 2>/dev/null

	echo " - Copying ${cwd}/ubuntu/rapiddisk_boot to ${bootscript_dest}..."
	if ! cp -f "${cwd}/ubuntu/rapiddisk_boot" "${bootscript_dest}" ; then
		myerror "could not copy rapiddisk_boot to ${bootscript_dest}."
	fi
	chmod +x "${bootscript_dest}" 2>/dev/null

	echo " - Copying ${cwd}/ubuntu/rapiddisk_sub.orig to ${subscript_dest_orig}..."
	if ! cp -f "${cwd}/ubuntu/rapiddisk_sub.orig" "${subscript_dest_orig}"; then
		myerror "could not copy rapiddisk_sub.orig to ${subscript_dest_orig}."
	fi
	chmod -x "${subscript_dest_orig}" 2>/dev/null

}

ubuntu_end () {

	echo " - Updating initramfs for kernel version ${kernel_version}..."
	echo ""
	update-initramfs -u -k "$kernel_version"
	echo ""
	echo " - Updating grub..."
	echo ""
	update-grub
	echo ""
	echo " - Done under Ubuntu. A reboot is needed."

}

install_options_checks () {

	[ -n "$ramdisk_size" ] || myerror "missing argument '--size'."
	is_num "$ramdisk_size" || myerror "the ramdisk size must be a positive integer."

	if [ -z "$root_device" ] ; then
		echo " - No root device was specified, we start looking for it in /etc/fstab..."
	
		root_line="$(grep -vE '^[ #]+' /etc/fstab | grep -m 1 -oP '^.*?[^\s]+\s+/\s+')"
		root_first_char="$(echo $root_line | grep -o '^.')"

		case $root_first_char in
			U)
				uuid="$(echo $root_line | grep -oP '[\w\d]{8}-([\w\d]{4}-){3}[\w\d]{12}')"
				root_device=/dev/"$(ls 2>/dev/null -l /dev/disk/by-uuid/ | grep $uuid | grep -oE '[^/]+$')"
				;;
			L)
				label="$(echo $root_line | grep -oP '=[^\s]+' | tr -d '=')"
				root_device=/dev/"$(ls 2>/dev/null -l /dev/disk/by-label/ | grep $label | grep -oE '[^/]+$')"
				;;
			/)
				device="$(echo $root_line | grep -oP '^[^\s]+')"
				root_device=/dev/"$(ls 2>/dev/null -l $device | grep -oP '[^/]+$')"
				;;
			*)
				myerror "could not find the root device from /etc/fstab. Use the '--root' option."
				;;
		esac

		# TODO this check must be improved
		if ! echo "$root_device" | grep -P '^/dev/\w{1,4}\d{0,99}$' >/dev/null 2>/dev/null ; then
			myerror "root_device '$root_device' must be in the form '/dev/xxx' or '/dev/xxxn with n as a positive integer."
		fi

		echo " - Root device '$root_device' was found!"
		echo ' - Is it ok to use it? [yN]'
		read -r yn

		if [ ! "$yn" = "y" ] && [ ! "$yn" = "Y" ] ; then
			ihelp
			myerror "the root device we found was not ok. Use the '--root' option."
		fi
	fi

}

# checks for current user == root
whoami | grep '^root$' 2>/dev/null 1>/dev/null || myerror "sorry, this must be run as root."

# looks for the OS name
if hostnamectl | grep "CentOS Linux" >/dev/null 2>/dev/null; then
	os_name="centos"
	kernel_installed="$(rpm -qa kernel-*| sed -E 's/^kernel-[^[:digit:]]+//'|sort -u)"
elif hostnamectl | grep "Ubuntu" >/dev/null 2>/dev/null; then
	os_name="ubuntu"
	kernel_installed="$(dpkg-query --list | grep -P 'linux-image-\d' |grep '^.i'| awk '{ print $2 }'| sed 's,linux-image-,,')"
else
	myerror "operating system not supported."
fi

# parsing arguments
for i in "$@"; do
	case $i in
		--kernel=*)
			kernel_version="${i#*=}"
			shift # past argument=value
			;;
		--uninstall)
			install_mode=simple_uninstall
			shift # past argument with no value
			;;
		--global-uninstall)
			if [ ! -z "$install_mode" ] ; then
				ihelp
				myerror "only one betweeen '--install, '--uninstall' and --global-uninstall can be specified."
			fi
			install_mode=global_uninstall
			shift # past argument with no value
			;;
		--install)
			if [ ! -z "$install_mode" ] ; then
				ihelp
				myerror "only one betweeen '--install, '--uninstall' and --global-uninstall can be specified."
			fi
			install_mode=simple_install
			shift # past argument with no value
			;;
		--root=*)
			root_device="${i#*=}"
			shift # past argument=value
			;;
		--size=*)
			ramdisk_size="${i#*=}"
			shift # past argument=value
			;;
		--force)
			force=1
			shift # past argument with no value
			;;
		--help)
			ihelp
			exit 1
			;;
		-h)
			ihelp
			exit 1
			;;
		*)
			ihelp
			myerror "unknown argument."
			# unknown argument
			;;
	esac
done # Credits https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash

# what to do must always be specified
if [ -z "$install_mode" ] ; then
	ihelp
	myerror "one betweeen '--install, '--uninstall' and '--global-uninstall' must be specified."
fi

# --kernel option is mandatory, except when --global-uninstall is specified
if [ -z "$kernel_version" ] && [ ! "$install_mode" = "global_uninstall" ] ; then
	ihelp
	myerror "missing argument '--kernel'."
fi

# check if the kernel version specified is installed
if [ ! "$install_mode" = "global_uninstall" ] ; then
	for v in $kernel_installed
	do
		if [ $v = "$kernel_version" ] ; then
			kernel_found=1
			break
		fi
	done

	if [ -z $kernel_found ] ; then
		myerror "the kernel version you specified is not installed."
	fi
fi

cwd="$(dirname $0)"

if [ "$os_name" = "centos" ] ; then
	echo " - CentOS detected!"

	# prepare some vars
	module_destination="/usr/lib/dracut/modules.d"
	module_name="96rapiddisk"
	kernel_version_file="$kernel_version"

	# check what to do
	if [ "$install_mode" = "simple_install" ] ; then
		# installing on CentOS

		# now we can perform some parameters'checks which would be senseless before
		install_options_checks

		# without --force, we do some checks
		if [ -z "$force" ] ; then
			if [ -d "${module_destination}/${module_name}" ] ; then
				# module installed, check for kernel activation file
				if [ -f "${module_destination}/${module_name}/${kernel_version_file}" ] ; then
					# everything is already installed
					myerror "module already installed and already active for kernel version $kernel_version. Use '--force' to reinstall."
				fi
			fi
		fi
		centos_install
		centos_end
	elif [ "$install_mode" = "simple_uninstall" ] ; then
		echo " - Uninstalling for kernel ${kernel_version}..."
		if [ -z "$force" ] ; then
			if [ ! -f "${module_destination}/${module_name}/${kernel_version_file}" ] ; then
				 myerror "module not active for kernel version ${kernel_version}. Use '--force' to remove it anyway."
			fi
		fi
		echo " - Removing rapiddisk from ${kernel_version} initrd file..."
		rm -f "${module_destination}/${module_name}/${kernel_version_file}"
		centos_end
	elif [ "$install_mode" = "global_uninstall" ] ; then
		echo " - Global uninstalling and rebuilding initrd for kernel ${kernel_version}..."
		rm -rf "${module_destination:?}/${module_name:?}"

		echo " - Rebuilding all the initrd files.."
		for k in $kernel_installed
		do
			echo " - dracut --kver $k -f"
			dracut --kver "$k" -f
		done
	fi
elif [ "$os_name" = "ubuntu" ] ; then
	echo " - Ubuntu detected!"

	# prepare some vars
	etc_dir_hooks="/etc/initramfs-tools/hooks"
	etc_dir_scripts="/etc/initramfs-tools/scripts/init-premount"
	usr_dir_hooks="/usr/share/initramfs-tools/hooks"
	usr_dir_scripts="/usr/share/initramfs-tools/scripts/init-premount"
	kernel_version_file="rapiddisk_kernel_${kernel_version}"

	# These checks aim to find the best place to put the scripts under Ubuntu
	if [ -d "$etc_dir_hooks" ] && [ -d "$etc_dir_scripts" ] ; then
		hooks_dir="$etc_dir_hooks"
		scripts_dir="$etc_dir_scripts"
	elif [ -d "$usr_dir_hooks" ] && [ -d "$usr_dir_scripts" ] ; then
		hooks_dir="$usr_dir_hooks"
		scripts_dir="$usr_dir_scripts"
	else
		myerror "I can't find any suitable place for initramfs scripts."
	fi

	hook_dest="${hooks_dir}/rapiddisk_hook"
	bootscript_dest="${scripts_dir}/rapiddisk_boot"
	subscript_dest_orig="${hooks_dir}/rapiddisk_sub.orig"

	if [ "$install_mode" = "simple_install" ] ; then
		# installing on Ubuntu
		if [ -f "${hooks_dir}/${kernel_version_file}" ] && [ -z $force ] ; then
			myerror "the config file for kernel version ${kernel_version} is already installed. Use '--force' to reinstall it."
		fi

		# now we can perform some parameters'checks which would be senseless before
		install_options_checks
		ubuntu_install
	elif [ "$install_mode" = "simple_uninstall" ] ; then
		if ( [ ! -x "$hook_dest" ] || [ ! -f "$subscript_dest_orig" ] || [ ! -f "${hooks_dir}/${kernel_version_file}" ] || [ ! -f "$bootscript_dest" ] ) && [ -z "$force" ] ; then
			myerror "it seems there is not a valid installation for kernel version ${kernel_version}. You should use the '--force' option."
		fi
		echo " - Uninstalling for kernel $kernel_version..."
		rm -f "${hooks_dir:?}/${kernel_version_file:?}" 2>/dev/null
	elif [ "$install_mode" = "global_uninstall" ] ; then
		echo " - Global uninstalling for all kernel versions.."
		echo " - Deleting all files and rebuilding all the initrd files.."
		rm -f "${hooks_dir:?}"/rapiddisk* "${scripts_dir:?}"/rapiddisk*
		kernel_version=all
	fi
	ubuntu_end
fi

exit 0
