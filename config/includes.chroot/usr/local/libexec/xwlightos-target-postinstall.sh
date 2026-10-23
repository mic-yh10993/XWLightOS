#!/bin/sh
set -eu

# This script runs inside the newly installed target through Calamares
# shellprocess. It must be safe to run more than once.
TARGET=/

# The Live image starts a temporary `user` session directly. The installed
# system must never preserve that identity or bypass authentication: the GDM
# login screen authenticates the Calamares-created account.
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable xwlightos-live-session-init.service >/dev/null 2>&1 || true
fi
rm -f /etc/systemd/system/xwlightos-live-session-init.service \
      /etc/systemd/system/multi-user.target.wants/xwlightos-live-session-init.service \
      /usr/local/sbin/xwlightos-live-session-init
# The live session's passwordless sudo rule must never survive into the
# installed system. The installed account gets sudo through sudo-group
# membership instead (granted and verified below).
rm -f /etc/sudoers.d/xwlightos-live /etc/sudoers.d/xwlightos-installer
rm -rf /etc/lightdm /etc/systemd/system/lightdm.service.d
rm -f /etc/xdg/autostart/xwlightos-desktop-trust.desktop
# The Live account is created at boot and must never be selected should its
# passwd entry happen to be visible while Calamares runs. Clear the image's
# Live session file first, then require the account created by Calamares.
rm -f /etc/xwlightos/session-user
# Installed systems use the GDM login screen: drop the Live autologin.
# 注意：Debian 的 gdm3 只读 /etc/gdm3/daemon.conf（见该文件头注释的根因说明），
# 不要改回 custom.conf，那个文件 GDM 根本不读。
if [ -f /etc/gdm3/daemon.conf ]; then
    sed -i '/^AutomaticLoginEnable=/d; /^AutomaticLogin=/d' /etc/gdm3/daemon.conf
fi
# The Live `user` account is baked into the image so GDM can autologin on the
# LiveCD. It must never survive into the installed system: remove the account
# (and its home) here in the target, before the installed session is used.
if id user >/dev/null 2>&1; then
    userdel -r user >/dev/null 2>&1 || userdel user >/dev/null 2>&1 || true
fi
rm -f /var/lib/AccountsService/users/user
human_accounts=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" && $1 != "user" && $1 != "live" {print $1}' /etc/passwd)
installed_account=$(printf '%s\n' "$human_accounts" | sed '/^$/d' | tail -n1)
if [ -z "$installed_account" ]; then
    echo 'XWLightOS: Calamares did not create an installed session account' >&2
    exit 1
fi
install -Dm644 /dev/stdin /etc/xwlightos/session-user <<EOF
$installed_account
EOF
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable xwlightos-installed-cleanup.service >/dev/null 2>&1 || true
    systemctl enable gdm.service >/dev/null 2>&1 || true
fi

# Calamares executes this after the selected account exists.  Use the shared
# installed-only cleaner so the system menu, inherited skeleton Desktop and
# already-created user Desktop/XDG directories are handled as one operation.
if [ -x /usr/local/libexec/xwlightos-installed-cleanup ]; then
    /usr/local/libexec/xwlightos-installed-cleanup
else
    echo 'XWLightOS: installed-only installer cleanup helper is missing' >&2
    exit 1
fi

# Keep one Widgets process: XWLightOS supplies the system XDG autostart entry.
# Remove an upstream per-user copy which older media created after a settings
# save and which then duplicated edge strips on every subsequent login.
find /home /root /etc/skel -type f -path '*/.config/autostart/widget-panel.desktop' -delete 2>/dev/null || true

# Keep the XWLightOS GRUB theme self-contained in the installed target. Copy
# both the theme and its relative desktop-image asset before running grub-mkconfig.
THEME_SRC=/usr/share/xwlightos/branding/theme.txt
[ -f "$THEME_SRC" ] || THEME_SRC=/boot/grub/themes/xwlightos/theme.txt
WALL_SRC=/usr/share/xwlightos/branding/xwlightos-aurora-wallpaper.png
[ -f "$WALL_SRC" ] || WALL_SRC=/boot/grub/themes/xwlightos/xwlightos-aurora-wallpaper.png
if [ -f "$THEME_SRC" ] && [ -f "$WALL_SRC" ]; then
    install -Dm644 "$THEME_SRC" /boot/grub/themes/xwlightos/theme.txt
    install -Dm644 "$WALL_SRC" /boot/grub/themes/xwlightos/xwlightos-aurora-wallpaper.png
    mkdir -p /etc/default/grub.d
    cat > /etc/default/grub.d/00-xwlightos.cfg <<'EOF'
GRUB_DISTRIBUTOR="XWLightOS"
GRUB_THEME="/boot/grub/themes/xwlightos/theme.txt"
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=6
GRUB_DEFAULT=0
GRUB_DISABLE_OS_PROBER=false
EOF
else
    # Never leave a dangling GRUB_THEME which produces a boot-time error.
    rm -f /etc/default/grub.d/00-xwlightos.cfg
fi

# GNOME provides its own screen lock; no external locker is needed.

# Preserve the password entered in Calamares and make the created human user
# eligible for sudo without changing or resetting its password.
#
# The Calamares users module assigns its defaultGroups (which include sudo)
# with a single atomic `usermod -aG`: if any one of those groups is missing
# in the target, the whole command fails and the new account ends up with NO
# supplementary groups at all. Repair that here group by group, so one
# missing group can never silently strip sudo (or audio/video/plugdev).
for grp in cdrom floppy sudo audio dip video plugdev netdev lpadmin scanner bluetooth; do
    if getent group "$grp" >/dev/null 2>&1; then
        usermod -aG "$grp" "$installed_account" >/dev/null 2>&1 || \
            echo "XWLightOS: could not add $installed_account to group $grp" >&2
    else
        echo "XWLightOS: group $grp missing in target, skipped" >&2
    fi
done
# The installed account must be able to sudo. Fail the installation loudly
# here instead of shipping a system whose owner cannot administrate it.
if ! id -nG "$installed_account" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
    echo "XWLightOS: $installed_account is not in the sudo group; refusing to ship a sudo-less system" >&2
    exit 1
fi
# Second layer behind the grant above: a first-boot repair net re-checks the
# recorded installed account before GDM starts, in case anything later in
# the install sequence drops the membership again.
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable xwlightos-sudo-repair.service >/dev/null 2>&1 || true
fi

# Refresh device state and initramfs so firmware already present in the target
# is discovered without requiring a second manual driver step.
command -v udevadm >/dev/null 2>&1 && udevadm trigger --action=add || true
command -v depmod >/dev/null 2>&1 && depmod -a || true
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true

# Regenerate GRUB only after the target theme and defaults are present.
command -v update-grub >/dev/null 2>&1 && update-grub || true

# Perform one more hardware/firmware probe at first boot, when the installed
# kernel and target udev database are active. Optional firmware never blocks
# graphical login.
install -Dm644 /dev/stdin /etc/systemd/system/xwlightos-driver-probe.service <<'EOF'
[Unit]
Description=XWLightOS hardware and firmware probe
After=local-fs.target systemd-udev-settle.service
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'udevadm trigger --action=add; depmod -a; update-initramfs -u -k all; if command -v fwupdmgr >/dev/null 2>&1; then fwupdmgr get-devices || true; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable xwlightos-driver-probe.service >/dev/null 2>&1 || true
fi
