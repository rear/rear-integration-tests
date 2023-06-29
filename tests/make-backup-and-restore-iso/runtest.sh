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
. /usr/bin/rhts-environment.sh || exit 1
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

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup "Assert that all required RPMs are installed"
            rlAssertRpm --all
        rlPhaseEnd

        rlPhaseStartSetup "Create /etc/rear/local.conf"
            rlFileBackup "/etc/rear/local.conf"
            rlRun -l "echo 'OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb://$REAR_LABEL_PATH
USER_INPUT_TIMEOUT=10' | tee /etc/rear/local.conf" \
                0 "Creating basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartTest "Select and prepare (hd1) device"
            # TODO: does not work due to bug in anaconda (and would be unreliable either way)
            # for dev in $(lsblk -o name -lpn); do
            #     if [[ "$(grub2-probe --target=drive --device "$dev")" = "(hd1)" ]]; then
            #         REAR_ROOT="$dev"
            #     fi
            # done
            # if [[ -z "$REAR_ROOT" ]]; then
            #     rlDie "This machine does not have a usable disk"
            # else
            #     rlLog "Selected $REAR_ROOT"
            # fi
            if [ "$(systemd-detect-virt)" = "kvm" ]; then
                REAR_ROOT=/dev/vdb
            else
                REAR_ROOT=/dev/sdb
            fi

            rlLog "Selected $REAR_ROOT"
            rlAssertExists "$REAR_ROOT"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_ROOT does not exist."
            fi

            rlRun -l "rear -d format -- -y $REAR_ROOT" \
                0 "Partition and format $REAR_ROOT"

            rlAssertExists "$REAR_LABEL_PATH"
            check_and_submit_rear_log format

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -d format -- -y $REAR_ROOT failed. See rear-format.log for details."
            fi

            rlRun -l "lsblk | tee drive_layout.old" \
                0 "Store lsblk output in recovery image"
            rlAssertExists drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest "Run rear mkbackup"
            rlRun -l "rear -d mkbackup" \
                0 "Creating backup to $REAR_LABEL_PATH"
            check_and_submit_rear_log mkbackup
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -d mkbackup failed. See rear-mkbackup.log for details."
            fi
        rlPhaseEnd

        rlPhaseStartSetup "Create dummy file"
            rlRun "touch recovery_will_remove_me" \
                0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        # TODO: should be configurable in /etc/rear/local.conf!!!
        rlPhaseStartSetup "Force ReaR rescue system to run unattended"
            rlRun "mkdir /mnt/rear" 0 "Create /mnt/rear"
            rlRun "mount LABEL=$REAR_LABEL /mnt/rear" \
                0 "Mount $REAR_LABEL_PATH"

            rlRun "sed -i '/^ontimeout/d' \
                       /mnt/rear/boot/syslinux/extlinux.conf" \
                0 "Disable hd1 autoboot on timeout"
            rlRun "sed -i '/^menu begin/i default $HOSTNAME_SHORT' \
                       /mnt/rear/rear/syslinux.cfg" \
                0 "Set recovery menu as default boot target"
            rlRun "sed -i '1idefault rear-unattended' \
                       /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" \
                0 "Set latest backup as default boot target (1/2)"
            rlRun "sed -z -i 's/label[^\n]*\(\n[^\n]*AUTOMATIC\)/label rear-unattended\1/' \
                       /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" \
                0 "Set latest backup as default boot target (2/2)"
            rlRun "sed -i 's/auto_recover/unattended/' \
                       /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" \
                0 "Append 'unattended' to kernel command-line"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: failed to make the recovery unattended"
            fi
        rlPhaseEnd

        CONSOLE_DEVICE="$(cat /sys/class/tty/console/active)"
        rlPhaseStartSetup "Redirect ReaR output to $CONSOLE_DEVICE"
            KERNEL_CMDLINE="$(grubby --info="$(grubby --default-kernel)" | \
                              grep -Po '(?<=^args=").*(?="$)|^root=.*$' | \
                              tr '\n' ' ' | tr -d '"' )"
            CONSOLE_CMDLINE="$(grep -Eo "console=$CONSOLE_DEVICE(,\w+)?" \
                               <<< "$KERNEL_CMDLINE")"

            # Workaround for machines that have an unused serial device
            # attached because by default ReaR will still try to use it for
            # output.
            NEW_CONSOLE_CMDLINE="$CONSOLE_CMDLINE"
            if [ -z "$NEW_CONSOLE_CMDLINE" ]; then
                NEW_CONSOLE_CMDLINE="console=$CONSOLE_DEVICE"
            fi

            rlRun "sed -i '/unattended/s/$/ $NEW_CONSOLE_CMDLINE/' \
                       /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" \
                0 "Append '$NEW_CONSOLE_CMDLINE' to kernel command-line"

            rlRun "umount -R /mnt/rear" \
                0 "Unmount $REAR_LABEL_PATH"
        rlPhaseEnd

        # RHEL 7 has EXTLINUX that does not support /boot being on XFS.  Use
        # latest version from RHEL 8 instead.
        if rlIsRHEL 7; then
        rlPhaseStartSetup "[RHEL 7] Install newer EXTLINUX for chainloading"
            rlRun "TmpDir=\"\$(mktemp -d)\"" 0 "Creating tmp directory"
            rlRun "pushd '$TmpDir'" 0 "Change dir to $TmpDir"

            # rlRpmDownload fails to download noarch packages :(
            for pkg in syslinux syslinux-extlinux; do
                rlRun -s "rlRpmDownload $pkg 6.04 5.el8 x86_64"
                NO_ARCH_URL="$(grep -Po "(?<=trying download from ').*(?='$)" \
                                        "$rlRun_LOG" | \
                               sed 's/x86_64/noarch/g' | \
                               sed "s/$pkg-6.04/$pkg-nonlinux-6.04/")"
                rlRun "wget '$NO_ARCH_URL'" \
                    0 "Download $pkg-nonlinux-6.04-5.el8.noarch.rpm"
                rm "$rlRun_LOG"
            done

            rlRun "yum install -y ./syslinux*.rpm" 0 "Install EXTLINUX 6.04"

            rlRun "popd '$TmpDir'" 0 "Change dir back"
            rlRun "rm -rf $TmpDir" 0 "Removing tmp directory"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: failed to install EXTLINUX 6.04"
            fi
        rlPhaseEnd
        fi

        # Use EXTLINUX to chainload ReaR instead of GRUB as that did not work
        # on some systems.
        rlPhaseStartSetup "Force the machine to autoboot the ReaR rescue system"
            ROOT_DEVICE="$(lsblk -no pkname "$(df --output=source /boot | tail -n1)")"
            KERNEL_VERSION="$(uname -r)"
            SERIAL_DEVICE="$(grep -Eo '[0-9]+,.*' <<< "$CONSOLE_CMDLINE" \
                             | tr ',' ' ')"

            rlRun -l "extlinux --install /boot/extlinux" \
                 0 "Install EXTLINUX to chainload ReaR"
            rlRun -l "echo 'SERIAL $SERIAL_DEVICE
UI menu.c32
PROMPT 0

MENU TITLE ReaR Chainload Boot Menu
TIMEOUT 50

LABEL linux
    MENU LABEL $(grubby --default-title)
    LINUX ../vmlinuz-$KERNEL_VERSION
    APPEND $KERNEL_CMDLINE
    INITRD ../initramfs-$KERNEL_VERSION.img

LABEL rear
    MENU LABEL Chainload ReaR from hd1
    MENU DEFAULT
    COM32 chain.c32
    APPEND hd1' | tee /boot/extlinux/extlinux.conf" \
                0 "Save EXTLINUX configuration"
            rlRun "cat /usr/share/syslinux/mbr.bin > /dev/$ROOT_DEVICE" \
                0 "Write EXTLINUX to /dev/$ROOT_DEVICE MBR"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: Installing EXTLINUX failed"
            fi
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # ReaR hopefully recovered the OS
        rlPhaseStartTest "Assert that the recovery was successful"
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists drive_layout.old
            rlAssertExists /root/rear*.log

            # check that ReaR did not overwrite itself
            rlAssertExists "$REAR_LABEL_PATH"

            rlRun -l "lsblk | tee drive_layout.new" \
                0 "Get current lsblk output"
            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            check_and_submit_rear_log recover
        rlPhaseEnd

        rlPhaseStartCleanup
            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -rf /root/rear*.log /var/log/rear/*" 0 "Remove ReaR logs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
