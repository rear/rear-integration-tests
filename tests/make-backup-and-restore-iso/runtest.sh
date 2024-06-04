#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-iso
#   Description: Test basic functionality of ReaR on systems with BIOS using bootable ISO image
#   Authors: Lukáš Zaoral <lzaoral@redhat.com>
#            Anton Voznia <antoncty@gmail.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 - 2023 Red Hat, Inc.
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

PACKAGES="rear syslinux-extlinux syslinux-nonlinux xorriso"
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
REAR_ISO_FHSDIR="/var/lib"
REAR_ISO_SUBDIR="rear/output"
REAR_ISO_OUTPUT="$REAR_ISO_FHSDIR/$REAR_ISO_SUBDIR"

OUTPUT_PATH=$(grub2-mkrelpath "$REAR_ISO_FHSDIR")/$REAR_ISO_SUBDIR
BOOT_PATH=$(grub2-mkrelpath /boot)
BOOT_FS_UUID=$(grub2-probe --target=fs_uuid /boot)
OUTPUT_FS_UUID=$(grub2-probe --target=fs_uuid "$REAR_ISO_FHSDIR")
OUTPUT_DISK=$(findmnt -v -o source -n --target "$REAR_ISO_FHSDIR" || grub2-probe --target=device "$REAR_ISO_FHSDIR")
OUTPUT_SUBVOL=$(findmnt -n -o fsroot --target "$REAR_ISO_FHSDIR")
if [ "$OUTPUT_SUBVOL" == / ] ; then
    OUTPUT_SUBVOL=""
fi
OUTPUT_FS_PATH=${REAR_ISO_FHSDIR##$(findmnt -n -o target --target "$REAR_ISO_FHSDIR")}/$REAR_ISO_SUBDIR

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup "Assert that all required RPMs are installed"
            rlAssertRpm --all
        rlPhaseEnd

        # Configure ReaR for ISO output.
        # Backup will be embedded in the ISO. Since the ISO is not written/burned
        # to any disk, but merely loaded into RAM by the bootloader (memdisk - see below),
        # it will not be accessible in the rescue system after it boots. We need it
        # for restoring the backup which is located there, though.
        # For this reason we load it into a RAM disk from the original system's root
        # filesystem, before ReaR starts wiping the disk. The backup content then survives
        # in the RAM disk.
        # Creation of the RAM disk, mounting of the root filesystem
        # and populating the RAM disk with the ISO image is achieved by the
        # PRE_RECOVERY_SCRIPT.
        rlPhaseStartSetup "Create $REAR_CONFIG"
            rlFileBackup "$REAR_CONFIG"
            rlRun -l "echo 'OUTPUT=ISO
SSH_FILES=no
FIRMWARE_FILES=( no )
BACKUP=NETFS
BACKUP_URL=iso:///backup
OUTPUT_URL=null
USER_INPUT_TIMEOUT=10
# 4gb backup limit
PRE_RECOVERY_SCRIPT=(\"mkdir /tmp/mnt;\" \"mount $OUTPUT_DISK ${OUTPUT_SUBVOL:+-o subvol=${OUTPUT_SUBVOL}} /tmp/mnt/;\" \"modprobe brd rd_nr=1 rd_size=2097152;\" \"dd if=/tmp/mnt/$OUTPUT_FS_PATH/rear-$HOSTNAME_SHORT.iso of=/dev/ram0;\" \"umount /tmp/mnt/;\")
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
            rlRun "export TMPDIR='/var/tmp'"
            rlRun -l "$REAR_BIN -d mkbackup" \
                0 "Creating backup to $REAR_ISO_OUTPUT"
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

        # We want to boot the resulting ISO by loading it into RAM by a bootloader
        # (memdisk) and chainloading its bootloader. This will test proper boot
        # functionality of the ISO image, in addition to testing the rescue ramdisk.
        # The iso is rather big, however. Let's make a smaller copy that excludes the backup
        # (backup.tar.gz). This will reduce memory usage by memdisk and prevent
        # possible boot issues where the complete ISO would not fit into RAM.
        rlPhaseStartSetup "Make small iso file that is bootable by memdisk"
            rlRun "xorriso -as mkisofs -r -V 'REAR-ISO' -J -J -joliet-long -cache-inodes -b isolinux/isolinux.bin -c isolinux/boot.cat -boot-load-size 4 -boot-info-table -no-emul-boot -eltorito-alt-boot -dev $REAR_ISO_OUTPUT/rear-$HOSTNAME_SHORT.iso -o $REAR_ISO_OUTPUT/rear-rescue-only.iso -- -rm_r backup"
        rlPhaseEnd

        # memdisk is a special bootloader, part of Syslinux. It is booted
        # using the Linux kernel protocol, with itself as the kernel and a disk image
        # as the initrd. It then chainloads the disk image (hands off control
        # to the bootloader in the disk image). This way we can test a bootable disk
        # by emulating it - without having a second disk drive.
        rlPhaseStartSetup "Force the machine to autoboot the ReaR rescue system"
            rlRun "cp /usr/share/syslinux/memdisk /boot/" 0 "Copying memdisk"
            # memdisk itself will be booted from our system's GRUB - we change grub.cfg
            # to load memdisk on reboot.
            # The complete boot sequence is thus:
            # GRUB -> memdisk -> bootloader of the ReaR ISO image
            rlRun "echo '
terminal_input serial
terminal_output serial
menuentry \"ReaR-recover\" {
search --no-floppy --fs-uuid --set=bootfs $BOOT_FS_UUID
search --no-floppy --fs-uuid --set=outputfs $OUTPUT_FS_UUID
linux16 (\$bootfs)$BOOT_PATH/memdisk iso raw
initrd16 (\$outputfs)$OUTPUT_PATH/rear-rescue-only.iso
}
set default=\"ReaR-recover\"' >> /boot/grub2/grub.cfg" 0 "Setup GRUB"
        rlPhaseEnd

        if test "$TMT_REBOOT_COUNT"; then
            rlRun "tmt-reboot -t 1200" 0 "Reboot the machine"
        else
            # not running from TMT
            rhts-reboot
        fi
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
