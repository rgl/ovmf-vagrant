#!/bin/bash
set -euxo pipefail

# install.
# see https://u-root.org/
# see https://github.com/u-root/u-root
# TODO lock the version.
go get -v github.com/u-root/u-root

# build a default initramfs.
mkdir -p u-root && cd u-root
cat >uinit.sh <<'EOF'
#!/bin/sh
echo 'Mounting /sys/firmware/efi/efivars...'
mount -o rw,nosuid,nodev,noexec,relatime -t efivarfs efivarfs /sys/firmware/efi/efivars

echo 'Mounting /boot/efi...'
mkdir -p /boot/efi
mount -t vfat /dev/sda1 /boot/efi

echo 'Mounts:'
cat /proc/mounts

echo 'Secure Boot Status:'
sbctl status

echo 'Useful commands:'
echo 'Create secure boot keys: sbctl create-keys'
echo 'Enroll secure boot keys: sbctl enroll-keys'
echo 'Sign linux: sbctl sign /boot/efi/linux'
echo 'Unmount: umount /boot/efi'
echo 'Reboot the system: shutdown -r'
echo 'Shutdown the system: shutdown'
EOF
chmod +x uinit.sh
u-root \
    -o initramfs.cpio \
    -uinitcmd '/uinit.sh' \
    -files uinit.sh:uinit.sh \
    -files "$(ls /vagrant/tmp/linux-modules/lib/modules/*/kernel/kernel/configs.ko):modules/configs.ko" \
    -files /usr/bin/lsblk \
    -files /usr/bin/lspci \
    -files /usr/share/misc/pci.ids \
    -files /usr/bin/sbsiglist \
    -files /usr/bin/sbvarsign \
    -files /usr/bin/sbkeysync \
    -files /usr/bin/sbsign \
    -files /usr/bin/sbverify \
    -files ~/go/bin/efianalyze:usr/local/bin/efianalyze \
    -files ~/go/bin/sbctl:usr/local/bin/sbctl \
    minimal \
    github.com/u-root/u-root/cmds/exp/bootvars
cpio --list --numeric-uid-gid --verbose <initramfs.cpio
# NB to abort qemu press ctrl+a, c then enter the quit command.
# NB to poweroff the vm enter the shutdown command.
#qemu-system-x86_64 -kernel "/boot/vmlinuz-$(uname -r)" -initrd initramfs.cpio -nographic -append console=ttyS0
#qemu-system-x86_64 -kernel "/boot/vmlinuz-$(uname -r)" -initrd initramfs.cpio -append vga=786

# create a disk image.
qemu-img create -f qcow2 boot.qcow2 150M
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 boot.qcow2
sudo parted --script /dev/nbd0 mklabel gpt
sudo parted --script /dev/nbd0 mkpart esp fat32 1MiB 100MiB
sudo parted --script /dev/nbd0 set 1 esp on
sudo parted --script /dev/nbd0 set 1 boot on
sudo parted --script /dev/nbd0 mkpart root ext4 100MiB 100%
sudo parted --script /dev/nbd0 print
sudo mkfs -t vfat -n ESP /dev/nbd0p1
sudo mkfs -t ext4 -L ROOT /dev/nbd0p2
sudo mkdir -p /mnt/ovmf/{esp,root}
sudo mount /dev/nbd0p1 /mnt/ovmf/esp
sudo mount /dev/nbd0p2 /mnt/ovmf/root
sudo install /vagrant/tmp/*.efi /mnt/ovmf/esp
cat initramfs.cpio | (cd /mnt/ovmf/root && sudo cpio -idv --no-absolute-filenames)
sudo install /vagrant/tmp/linux /mnt/ovmf/esp
sudo bash -c 'cat >/mnt/ovmf/esp/startup.nsh' <<'EOF'
# show the UEFI versions.
ver

# show the memory map.
memmap

# show the disks and filesystems.
map

# show the environment variables.
set

# show all UEFI variables.
#dmpstore -all

# show the secure boot platform status.
# possible values:
#   00: User Mode
#   01: Setup Mode
setvar -guid 8be4df61-93ca-11d2-aa0d-00e098032b8c SetupMode

# show the secure boot status.
# possible values:
#   00: Disabled
#   01: Enabled
setvar -guid 8be4df61-93ca-11d2-aa0d-00e098032b8c SecureBoot

# show the secure boot key stores.
setvar -guid 8be4df61-93ca-11d2-aa0d-00e098032b8c PK   # Platform Key (PK).
setvar -guid 8be4df61-93ca-11d2-aa0d-00e098032b8c KEK  # Key Exchange Key (KEK).
setvar -guid d719b2cb-3d3a-4596-a3bc-dad00e67656f db   # Signature Database (DB); aka Allow list database.
setvar -guid d719b2cb-3d3a-4596-a3bc-dad00e67656f dbx  # Forbidden Signature Database (DBX); ala Deny list database.

# show boot entries.
bcfg boot dump -v

# execute linux.
fs0:
linux mitigations=off console=ttyS0 debug earlyprintk=serial rw root=/dev/sda2 init=/init
EOF
df -h /mnt/ovmf/esp
df -h /mnt/ovmf/root
sudo umount /mnt/ovmf/esp
sudo umount /mnt/ovmf/root
sudo qemu-nbd --disconnect /dev/nbd0

# create the launch script.
# NB to start from scratch, delete the test sub-directory before executing run.sh.
cat >run.sh <<'EOF'
#!/bin/bash
set -euxo pipefail
mkdir -p test && cd test
if [ ! -f test-ovmf-code-amd64.fd ]; then
    install -m 440 ../OVMF_CODE.fd test-ovmf-code-amd64.fd
fi
if [ ! -f test-ovmf-vars-amd64.fd ]; then
    install -m 660 ../OVMF_VARS.fd test-ovmf-vars-amd64.fd
fi
if [ ! -f test-boot.qcow2 ]; then
    install -m 660 ../boot.qcow2 test-boot.qcow2
    # NB to use the ubuntu image instead, uncomment the following line.
    #qemu-img create -f qcow2 -b ~/.vagrant.d/boxes/ubuntu-20.04-uefi-amd64/0/libvirt/box.img test-boot.qcow2
    qemu-img info test-boot.qcow2
fi
# NB replace -nographic with -vga qxl to enable the GUI console.
qemu-system-x86_64 \
  -name amd64 \
  -no-user-config \
  -nodefaults \
  -nographic \
  -machine q35,accel=kvm,smm=on \
  -cpu host \
  -smp 2 \
  -m 2g \
  -k pt \
  -boot menu=on,strict=on \
  -chardev stdio,mux=on,signal=off,id=char0 \
  -mon chardev=char0,mode=readline \
  -serial chardev:char0 \
  -fw_cfg name=opt/org.tianocore/IPv4PXESupport,string=n \
  -fw_cfg name=opt/org.tianocore/IPv6PXESupport,string=n \
  -global ICH9-LPC.disable_s3=1 \
  -global ICH9-LPC.disable_s4=1 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,unit=0,file=test-ovmf-code-amd64.fd,format=raw,readonly \
  -drive if=pflash,unit=1,file=test-ovmf-vars-amd64.fd,format=raw \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-pci,rng=rng0 \
  -debugcon file:ovmf.log \
  -global isa-debugcon.iobase=0x402 \
  -qmp unix:amd64.socket,server,nowait \
  -device virtio-scsi-pci,id=scsi0 \
  -drive if=none,file=test-boot.qcow2,format=qcow2,id=hd0 \
  -device scsi-hd,drive=hd0
EOF
chmod +x run.sh

# copy to the host.
install -d /vagrant/tmp
install -m 444 boot.qcow2 /vagrant/tmp
install -m 555 run.sh /vagrant/tmp
