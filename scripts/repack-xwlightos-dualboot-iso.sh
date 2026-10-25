#!/usr/bin/env bash
# Add a standalone x86_64 EFI boot image to the final live-build ISO while
# retaining the matching ISOLINUX BIOS tree. This is used identically locally
# and in GitHub Actions to prevent BIOS/UEFI drift.
set -euo pipefail

[ "$#" -eq 1 ] || {
    echo "usage: $0 INPUT.iso" >&2
    exit 2
}

ISO="$1"
[ -s "$ISO" ] || {
    echo "ISO is missing or empty: $ISO" >&2
    exit 1
}
for command in grub-mkstandalone mkfs.vfat mmd mcopy xorriso truncate; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required command is unavailable: $command" >&2
        exit 1
    }
done

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BINARY_TREE="${XWLIGHTOS_BINARY_TREE:-$ROOT/binary}"
[ -d "$BINARY_TREE" ] || {
    echo "live-build binary tree is missing: $BINARY_TREE" >&2
    exit 1
}
for path in isolinux/isolinux.bin isolinux/ldlinux.c32 isolinux/vesamenu.c32; do
    [ -s "$BINARY_TREE/$path" ] || {
        echo "required BIOS boot asset is missing from binary tree: $path" >&2
        exit 1
    }
done

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
EFI_STUB="$WORK/grub-stub.cfg"
EFI_MENU="$WORK/grub-menu.cfg"
EFI_BIN="$WORK/BOOTX64.EFI"
EFI_IMG="$WORK/efi.img"
REPACKED="$ISO.dualboot"

# The UEFI menu lives in a real file on the ISO (/boot/grub/grub.cfg) instead
# of only inside the standalone GRUB binary, so that:
#  - the Validate step can check the exact menu UEFI boot will use.
#    Build 34 failed here: the gate looked for /boot/grub/grub.cfg on the
#    ISO root, but the repack embedded the menu inside BOOTX64.EFI and
#    shipped no such file, so the gate could never find it (and the repo's
#    own 3000 binary hook had already noted that live-build does not
#    generate binary/boot/grub/grub.cfg in this mode).
#  - the UEFI menu carries the same splash flags as the BIOS menu.
#    Before this change the embedded UEFI menu had NO quiet splash and NO
#    plymouth.ignore-serial-consoles, so on UEFI hardware the splash never
#    had a chance (user 2026-10-25: splash never shows) even though the
#    BIOS menu carried both flags via --bootappend-live.
# The standalone binary only carries a stub that chains to the menu file;
# the menu file is what UEFI boot actually uses, so the gate validates the
# real menu, not a decoy copy.
cat > "$EFI_STUB" <<'EOF'
search --no-floppy --file --set=root /live/vmlinuz
configfile ($root)/boot/grub/grub.cfg
EOF

cat > "$EFI_MENU" <<'EOF'
set timeout=12
set default=0
insmod iso9660
insmod search
insmod linux
insmod normal
search --no-floppy --file --set=root /live/vmlinuz
menuentry "Start XWLightOS Live" {
  linux /live/vmlinuz boot=live config components console=tty0 console=ttyS0 quiet splash plymouth.ignore-serial-consoles
  initrd /live/initrd.img
}
menuentry "XWLightOS Live (safe graphics)" {
  linux /live/vmlinuz boot=live config components nomodeset console=tty0 console=ttyS0 quiet splash plymouth.ignore-serial-consoles
  initrd /live/initrd.img
}
EOF

grub-mkstandalone -O x86_64-efi -o "$EFI_BIN" \
    --modules="iso9660 search linux normal" \
    "boot/grub/grub.cfg=$EFI_STUB"
truncate -s 16M "$EFI_IMG"
mkfs.vfat -F 16 "$EFI_IMG" >/dev/null
mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$EFI_BIN" ::/EFI/BOOT/BOOTX64.EFI

# -iso-level 3: xorriso's mkisofs emulation caps single files at 4GiB-1 by
# default; level 3 raises the limit to 400GiB-200KiB. Required since
# binary/live/filesystem.squashfs passed 4GiB (ONLYOFFICE integration).
# Boot assets (isolinux, kernel, initrd, efi.img) stay small; the squashfs
# is stored as a multi-extent file, which Linux isofs reads transparently.
# -graft-points: map the UEFI menu file to /boot/grub/grub.cfg on the ISO.
# Plain paths without '=' keep their default placement (binary-tree contents
# at the root, efi.img at /efi.img), so only the menu mapping is new.
xorriso -as mkisofs -r -J -iso-level 3 -V "XWLIGHTOS 1.0" \
    -graft-points \
    -o "$REPACKED" \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e efi.img -no-emul-boot \
    -isohybrid-gpt-basdat "$BINARY_TREE" "$EFI_IMG" "boot/grub/grub.cfg=$EFI_MENU"
mv -f "$REPACKED" "$ISO"
# Self-check: the repacked ISO must actually carry the UEFI menu file with
# the splash flags; fail loudly here instead of letting the Validate step
# (or real UEFI hardware) discover a missing menu later.
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg "$WORK/check-menu.cfg" >/dev/null 2>&1 || {
    echo "repacked ISO lacks /boot/grub/grub.cfg (UEFI menu file missing)" >&2
    exit 1
}
grep -q 'quiet splash plymouth.ignore-serial-consoles' "$WORK/check-menu.cfg" || {
    echo "repacked UEFI menu lacks quiet splash + plymouth.ignore-serial-consoles" >&2
    exit 1
}
printf 'Repacked dual BIOS/UEFI XWLightOS ISO: %s\n' "$ISO"
