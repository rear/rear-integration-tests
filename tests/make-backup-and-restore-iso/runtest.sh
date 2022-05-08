#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-bios
#   Description: Test basic functionality of ReaR on systems with BIOS.
#   Author: Lukáš Zaoral <lzaoral@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 - 2022 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGES="rear syslinux-extlinux"
REAR_LABEL="${REAR_LABEL:-REAR-000}"
REAR_LABEL_PATH="/dev/disk/by-label/$REAR_LABEL"
HOSTNAME_SHORT="$(hostname --short)"

check_and_submit_rear_log() {
    local path="/var/log/rear/rear-$HOSTNAME_SHORT.log"
    if [ "$1" = "recover" ]; then
        # recover log is only in /root and has a similar name like
        # rear-2022-05-18T01:03:48-04:00.log
        path="/root/rear-*.log"
    fi

    local log_prefix='\d{4}(-\d{2}){2} (\d{2}:){2}\d{2}\.\d{9}'

    local warnings errors
    warnings="$(grep -C 10 -P "$log_prefix WARNING:" $path)"
    errors="$(grep -C 10 -P "$log_prefix ERROR:" $path)"

    if [ -n "$warnings" ]; then
        rlFail "rear-$1.log contains some warnings"
        rlLog "$warnings"
    fi

    if [ -n "$errors" ]; then
        rlFail "rear-$1.log contains some errors"
        rlLog "$errors"
    fi

    rlFileSubmit $path "rear-$1.log"
}

REAR_BIN="/usr/sbin/rear"
REAR_CONFIG="/etc/rear/local.conf"
REAR_HOME_DIRECTORY="/root"

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup "Assert that all required RPMs are installed"
            rlAssertRpm --all
        rlPhaseEnd

        rlPhaseStartSetup "Create $REAR_CONFIG"
            rlFileBackup "$REAR_CONFIG"
            rlRun -l "echo 'OUTPUT=ISO
BACKUP=NETFS
BACKUP_URL=iso:///backup
OUTPUT_URL=null
USER_INPUT_TIMEOUT=10
# 4gb backup limit
PRE_RECOVERY_SCRIPT=(\"mkdir /tmp/mnt;\" \"mount /dev/vda2 /tmp/mnt/;\" \"modprobe loop;\" \"dd if=/tmp/mnt/root/rear/var/lib/rear/output/rear-fedora.iso of=/dev/cdrom;\" \"umount /tmp/mnt/;\")
ISO_FILE_SIZE_LIMIT=4294967296
ISO_DEFAULT=automatic
ISO_RECOVER_MODE=unattended' | tee $REAR_CONFIG" \
                0 "Creating basic configuration file"
            rlAssertExists "$REAR_CONFIG"
        rlPhaseEnd

        rlPhaseStartTest
            rlRun -l "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.old" 0 "Store lsblk output in recovery image"
            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest "Run rear mkbackup"
            rlRun -l "$REAR_BIN -d mkbackup" \
                0 "Creating backup to $REAR_LABEL_PATH"
            check_and_submit_rear_log mkbackup
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_BIN -d mkbackup failed. See rear-mkbackup.log for details."
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Create dummy file"
            rlRun "touch $REAR_HOME_DIRECTORY/recovery_will_remove_me" \
                0 "Create dummy file to be removed by recovery"
            rlAssertExists $REAR_HOME_DIRECTORY/recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartSetup "Force the machine to autoboot the ReaR rescue system"
            rlLog "Setup GRUB"
            rlRun "echo 'menuentry \"ReaR-recover\" {
  loopback loop (hd0,msdos2)/root/rear/var/lib/rear/output/rear-fedora.iso
  linux (loop)/isolinux/kernel rw selinux=0 console=ttyS0,9600 console=tty0 auto_recover unattended
  initrd (loop)/isolinux/initrd.cgz
}
set default=\"ReaR-recover\"' >> /boot/grub2/grub.cfg"
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # ReaR hopefully recovered the OS
        rlPhaseStartTest "Assert that the recovery was successful"
            rlAssertNotExists $REAR_HOME_DIRECTORY/recovery_will_remove_me

            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
            rlAssertExists /root/rear*.log

            rlRun -l "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.new" \
                0 "Get current lsblk output"
            if ! rlAssertNotDiffer $REAR_HOME_DIRECTORY/drive_layout.{old,new}; then
                rlRun -l "diff -u $REAR_HOME_DIRECTORY/drive_layout.{old,new}" \
                    1 "Diff drive layout changes"
            fi

            check_and_submit_rear_log recover
        rlPhaseEnd

        rlPhaseStartCleanup
            rlFileRestore
            rlRun "rm -f $REAR_HOME_DIRECTORY/drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -rf /root/rear*.log /var/log/rear/*" 0 "Remove ReaR logs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
