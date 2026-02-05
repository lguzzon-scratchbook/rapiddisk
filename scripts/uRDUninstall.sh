#!/bin/bash

rapiddisk_Uninstall() {
  local -r PRIMARY_DEV_TO_CACHE="${1-}"
  local -r DEV_TO_CACHE="/dev/${PRIMARY_DEV_TO_CACHE}"
  (
    sudo dpkg --configure -a
    DEBIAN_FRONTEND=noninteractive sudo apt-get -y -qq -o Dpkg::Options::=--force-all -f install
    sudo rm -rf /var/lib/dpkg/lock-frontend
    sudo rm -rf /var/lib/dpkg/lock
    sudo rm -rf /var/cache/apt/archives/lock
    true
  ) \
    && ( (which git >/dev/null 2>&1) || sudo apt -y install git) \
    && cd "$HOME" \
    && (rm -Rf rapiddisk || true) \
    && git clone -b lastWorking https://github.com/lguzzon-scratchbook/rapiddisk.git \
    && cd rapiddisk \
    && cd scripts/rapiddisk-rootdev \
    && ./rapiddisk-on-boot --global-uninstall --force \
    && cd "$HOME" \
    && (rm -Rf rapiddisk || true) \
    && (
      (
        [[ -n ${PRIMARY_DEV_TO_CACHE} ]] \
          && sed -i 's,/dev/mapper/rc-wb_'"${PRIMARY_DEV_TO_CACHE}"','"${DEV_TO_CACHE}"',' /etc/fstab
      ) \
        || true
    ) \
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

rapiddisk_Uninstall "$@"
