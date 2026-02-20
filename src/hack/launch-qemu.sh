#!/bin/bash

# Launch a QEMU VM from a CanvOS installer ISO for smoke testing.
# Usage: ./launch-qemu.sh <path-to-iso>
#
# Screenshot capability:
# https://unix.stackexchange.com/a/476617

if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 <iso-file>"
    echo "Example: $0 ../../build/palette-edge-installer.iso"
    exit 1
fi

if [ ! -e disk.img ]; then
    qemu-img create -f qcow2 disk.img 60g
fi

#    -nic bridge,br=br0,model=virtio-net-pci \
qemu-system-x86_64 \
    -enable-kvm \
    -cpu "${CPU:=host}" \
    -nographic \
    -m "${MEMORY:=10096}" \
    -smp "${CORES:=5}" \
    -monitor unix:/tmp/qemu-monitor.sock,server=on,wait=off \
    -serial mon:stdio \
    -rtc base=utc,clock=rt \
    -chardev socket,path=qga.sock,server=on,wait=off,id=qga0 \
    -device virtio-serial \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -drive if=virtio,media=disk,file=disk.img \
    -drive if=ide,media=cdrom,file="${1}"
