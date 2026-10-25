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
# Installed layer of the openssh default-off fix (user 2026-10-25: openssh
# error at both boot and shutdown; live layer is the 1710 build hook).
# Calamares unpackfs copies the live root, so a live-only disable would
# not by itself prove anything about the installed system: the package
# enable symlink rides over with the copy. Disable here in the target too,
# with the same explicit symlink removal as the live hook (systemctl in a
# target chroot cannot be relied on alone). Deliberately disable, not mask,
# and keep the package installed, so an administrator can still run
# `systemctl enable --now ssh` later. Never fail the installation over this:
# if a future image drops the package, there is simply nothing to disable.
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable ssh.service sshd.service ssh.socket sshd.socket \
        >/dev/null 2>&1 || true
fi
rm -f /etc/systemd/system/multi-user.target.wants/ssh.service \
      /etc/systemd/system/multi-user.target.wants/sshd.service \
      /etc/systemd/system/multi-user.target.wants/ssh.socket \
      /etc/systemd/system/multi-user.target.wants/sshd.socket \
      /etc/systemd/system/sshd.service \
      /etc/systemd/system/ssh.socket
# The live session's passwordless sudo rule must never survive into the
# installed system. The installed account gets sudo through sudo-group
# membership instead (granted and verified below).
rm -f /etc/sudoers.d/xwlightos-live /etc/sudoers.d/xwlightos-installer
rm -rf /etc/lightdm /etc/systemd/system/lightdm.service.d
# 注意：/etc/xdg/autostart/xwlightos-desktop-trust.desktop 不再是 live 专用——
# 用户 2026-10-23 邮件指令要求桌面图标在安装后系统也默认可信任，因此安装后保留。
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
# Deep-chain fix (user mail 2026-10-24 22:40: why do boot-animation and
# font-color fixes keep not landing): the live session forces X11 via
# AccountsService (the 1700 hook writes XSession=gnome-xorg for the
# live 'user'), but the installed account never got such a file --
# this script deletes the live one above and writes nothing for the
# new account. GDM then starts the installed user on its default
# session, which on bookworm is Wayland when available. Every
# session-level fix validated on the live X11 session then silently
# stops applying on the installed system: /etc/X11/Xsession.d and
# /etc/profile.d are never sourced (fcitx5 IM variables, Qt theme),
# and X11-oriented components run under a session they were never
# tested in. Force X11 for the installed account exactly like the
# live user, so installed == live.
install -d -m 0755 /var/lib/AccountsService/users
# 账户图标与 live 用户同理（2026-10-25 08:29 用户反馈第 8 项）：安装账号
# 同样没有 Icon 项时只会显示通用头像/回落标识。把同一张品牌头像写进
# 安装账号的 AccountsService 图标槽位；头像文件随 unpackfs 进目标系统，
# 缺失时只告警、不拖垮安装（镜像级校验已断言该文件存在）。
if [ -s /usr/share/xwlightos/branding/xwlightos-avatar.png ]; then
    install -d -m 0755 /var/lib/AccountsService/icons
    install -Dm644 /usr/share/xwlightos/branding/xwlightos-avatar.png \
        "/var/lib/AccountsService/icons/$installed_account"
    ICON_LINE="Icon=/var/lib/AccountsService/icons/$installed_account"
else
    echo "XWLightOS: brand avatar PNG is missing, installed account keeps the default icon" >&2
    ICON_LINE=""
fi
cat > "/var/lib/AccountsService/users/$installed_account" <<ACCEOF
[User]
XSession=gnome-xorg
$ICON_LINE
ACCEOF
# 用户 2026-10-25 09:01 指令：希沃侧边栏暂时删除，上面那段
# sidebar-off 标志写入已随侧边栏删除一并去掉（不再给不存在的
# 组件写关闭标志）。恢复侧边栏时 revert 删除提交即可。
# 用户 2026-10-25 邮件《继续修复》第 6 项：Shift 切换仍失效。
# 已核实 Build 33 代码侧链路本身是全的：skel 配置有双 Shift
# AltTriggerKeys、profile 有中英双端点、/etc/environment 有三变量、
# 自启动文件与面板扩展都在，live 用户经 1700 钩子 cp -a skel 必得该
# 配置。但安装账号的家目录只经 Calamares 建用户一环继承 skel——
# 1700 钩子的 cp -a 只管 live 用户，postinstall 此前从未给安装账号
# 补过 fcitx5 配置。只要 skel 继承链路有任何一环漏掉（与 4908b0a
# 的 live/安装不一致教训同类），安装后用户拿到的就是 fcitx5 默认
# 配置：守护进程在跑、点图标能切换（图标走 D-Bus 不走触发键），
# 唯独 Shift 触发键不存在——与用户本次反馈的现象逐项吻合。
# 因此这里只补缺口（cp -n，绝不覆盖已有配置）、失败只警告不拖垮
# 安装，把“skel 一定继承”从假设变成 postinstall 保证。注意：
# 本段修的是继承链路，不是触发键本身——触发键值（Shift_L/Shift_R）
# 仍以 skel 文件为准，此处不改值。
if [ -d /etc/skel/.config/fcitx5 ]; then
    mkdir -p "/home/$installed_account/.config/fcitx5" 2>/dev/null || true
    for _fcitx5_conf in config profile; do
        cp -n "/etc/skel/.config/fcitx5/$_fcitx5_conf" \
            "/home/$installed_account/.config/fcitx5/$_fcitx5_conf" 2>/dev/null || \
            echo "XWLightOS: could not seed fcitx5 $_fcitx5_conf for $installed_account (Shift trigger may be missing)" >&2
    done
    chown -R "$installed_account:$installed_account" "/home/$installed_account/.config/fcitx5" 2>/dev/null || true
fi
# 用户 2026-10-25 邮件第 1 项（所有程序还是黑色文字+背景）——主题文件的
# 安装账号补种，与上面 fcitx5 同款教训、同款修法：
# live 用户经 1700 钩子 cp -a skel 必得主题文件，但安装账号只靠
# Calamares 建用户时的 skel 继承；postinstall 此前只给 fcitx5 补过缺口，
# 从未给主题文件补过。一旦继承链路漏掉，安装后用户就没有
# .config/gtk-3.0/settings.ini（prefer-dark=false）、.gtkrc-2.0、
# .config/gtk-4.0/gtk.css（libadwaita 应用的 WhiteSur-Light 样式）——
# GNOME 会话内的 dconf 虽仍给浅色，但不走 dconf 的应用（GTK2、Qt5
# gtk2、直接读 settings.ini 的 GTK3/GTK4 应用）就失去浅色锚点。
# 因此这里只补缺口（cp -n，绝不覆盖用户已有配置）、失败只警告不拖垮
# 安装；值仍以 skel 为准，此处不改值。
if [ -f /etc/skel/.config/gtk-3.0/settings.ini ]; then
    mkdir -p "/home/$installed_account/.config/gtk-3.0" 2>/dev/null || true
    cp -n /etc/skel/.config/gtk-3.0/settings.ini \
        "/home/$installed_account/.config/gtk-3.0/settings.ini" 2>/dev/null || \
        echo "XWLightOS: could not seed gtk-3.0 settings.ini for $installed_account" >&2
    chown -R "$installed_account:$installed_account" "/home/$installed_account/.config/gtk-3.0" 2>/dev/null || true
fi
if [ -f /etc/skel/.gtkrc-2.0 ]; then
    cp -n /etc/skel/.gtkrc-2.0 "/home/$installed_account/.gtkrc-2.0" 2>/dev/null || \
        echo "XWLightOS: could not seed .gtkrc-2.0 for $installed_account" >&2
    chown "$installed_account:$installed_account" "/home/$installed_account/.gtkrc-2.0" 2>/dev/null || true
fi
if [ -d /etc/skel/.config/gtk-4.0 ]; then
    mkdir -p "/home/$installed_account/.config/gtk-4.0" 2>/dev/null || true
    cp -an /etc/skel/.config/gtk-4.0/. \
        "/home/$installed_account/.config/gtk-4.0/" 2>/dev/null || \
        echo "XWLightOS: could not seed gtk-4.0 theme for $installed_account" >&2
    chown -R "$installed_account:$installed_account" "/home/$installed_account/.config/gtk-4.0" 2>/dev/null || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable xwlightos-installed-cleanup.service >/dev/null 2>&1 || true
    systemctl enable gdm.service >/dev/null 2>&1 || true
fi

# Calamares executes this after the selected account exists.  Use the shared
# installed-only cleaner so the system menu, inherited skeleton Desktop and
# already-created user Desktop/XDG directories are handled as one operation.
if [ -x /usr/local/libexec/xwlightos-installed-cleanup ]; then
    # 2026-10-24 Build 28 安装失败教训：此处原先是无保护调用，清理脚本
    # 一旦静默失败，set -e 直接杀掉本脚本，Calamares 只报 exit 1 且无输出，
    # 后续 GRUB、sudo 修复、initramfs 全部没跑。失败必须大声报出来。
    if ! /usr/local/libexec/xwlightos-installed-cleanup; then
        echo 'XWLightOS: installed cleanup failed; refusing to continue a half-cleaned install' >&2
        exit 1
    fi
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
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
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

# Build 34（用户 2026-10-25 邮件：管家后端自启“又掉了”）：live 镜像
# 只在 1660 构建钩子里启用厂商 unit（/etc/systemd/system/
# multi-user.target.wants），那是纯 live 层：本脚本此前从未在装完
# 系统里重启用过它们，安装路径上一旦丢了 wants 软链接，就会静默
# 发出一个管家后端永不起的系统——而构建仍绿灯，因为校验只查了
# 清单文件里有没有管家 unit，从没查装完系统这边。这里在目标里
# 再启用一次，与上面 gdm/sudo-repair 的启用同款：这是第二层，
# 不是替代 1660 钩子。
# /etc/environment 在目标里也必须存在：厂商 unit 写的是
# EnvironmentFile=/etc/environment（无 '-' 前缀），缺文件是硬失败
# 不是跳过。live 镜像经 includes.chroot 自带该文件；若安装路径
# 把它丢了，在此按同一格式重建（pam_env/systemd EnvironmentFile
# 格式，不带 export），而不是直接发一个注定起不来的后端。
if [ ! -f /etc/environment ]; then
    cat > /etc/environment <<'ENVEOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
QT_QPA_PLATFORMTHEME=gtk2
ENVEOF
    echo 'XWLightOS: /etc/environment missing in installed target, recreated (vendor manager unit hard-fails without it)'
fi
if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    for _vbase in /usr/lib/systemd/system /lib/systemd/system; do
        [ -d "$_vbase" ] || continue
        for _vunit in "$_vbase"/*seewo* "$_vbase"/*cvte* "$_vbase"/*maxhub* "$_vbase"/*easi*; do
            [ -f "$_vunit" ] || continue
            _vname="$(basename "$_vunit")"
            # 一个 unit 文件可同时命中多个 glob（如 cvte + maxhub），
            # 去重后只启用一次，避免安装日志里出现重复的启用行。
            case " ${_seen:-} " in
                *" $_vname "*) continue ;;
            esac
            _seen="${_seen:-}$_vname "
            case "$_vname" in
                *.service) ;;
                *) continue ;;
            esac
            case "$_vname" in
                *update*|*upgrade*|*ota*) continue ;;
            esac
            # 用户 2026-10-25 09:01 指令：Udi 组件暂时删除，1550 钩子
            # 已跳过其安装；这里不再为不存在的 Udi 留跳过规则。
            # 没有 [Install] 节的 unit 会让 systemctl enable 失败；
            # 此时回退到显式 wants 软链接，也就是 1660 钩子用的
            # 同一种启用，绝不能静默丢掉这个服务。
            systemctl enable "$_vname" >/dev/null 2>&1 || \
                ln -sfn "$_vunit" "/etc/systemd/system/multi-user.target.wants/$_vname" || true
            echo "XWLightOS: installed target: vendor service enabled: $_vname"
        done
    done
    unset _vbase _vunit _vname _seen
    if [ -f /usr/lib/systemd/system/com.seewo.terminalmanager.service ] || \
       [ -f /lib/systemd/system/com.seewo.terminalmanager.service ]; then
        [ -e /etc/systemd/system/multi-user.target.wants/com.seewo.terminalmanager.service ] || {
            echo 'XWLightOS: terminalmanager unit present in target but not enabled; refusing to ship a backend that never starts' >&2
            exit 1
        }
    else
        echo 'XWLightOS: WARNING: terminalmanager unit absent in installed target (manager backend cannot start)' >&2
    fi
fi

# Refresh device state and initramfs so firmware already present in the target
# is discovered without requiring a second manual driver step.
command -v udevadm >/dev/null 2>&1 && udevadm trigger --action=add || true
command -v depmod >/dev/null 2>&1 && depmod -a || true
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all || true

# Regenerate GRUB only after the target theme and defaults are present.
command -v update-grub >/dev/null 2>&1 && update-grub || true

# Target-side compiled-artifact guarantee for the dock (user 2026-10-25:
# dock still auto-hides after install). The live image already compiles
# both layers at build time (1700 hook: dconf update + glib-compile-schemas),
# but nothing ever verified the COMPILED artifacts on the installed system:
# Calamares unpackfs copies the live root, and any later target-side package
# trigger that rebuilds schemas without the override would silently revert
# the dock to the Debian schema defaults (autohide/intellihide on). Re-run
# both compiles here in the target and assert the compiled files exist, so
# the installed system cannot ship with a stale or missing compilation.
# This is a no-op when the live compilation already rode over intact.
if command -v dconf >/dev/null 2>&1; then
    dconf update || {
        echo 'XWLightOS: target dconf update failed; dock/system defaults would not apply' >&2
        exit 1
    }
else
    echo 'XWLightOS: dconf missing in target; dock defaults cannot be compiled' >&2
    exit 1
fi
if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas /usr/share/glib-2.0/schemas || {
        echo 'XWLightOS: target glib-compile-schemas failed; dash-to-dock schema override would not apply' >&2
        exit 1
    }
else
    echo 'XWLightOS: glib-compile-schemas missing in target; dash-to-dock schema override cannot be compiled' >&2
    exit 1
fi
[ -f /etc/dconf/db/local ] || {
    echo 'XWLightOS: target compiled dconf db missing after dconf update' >&2
    exit 1
}
[ -f /usr/share/glib-2.0/schemas/gschemas.compiled ] || {
    echo 'XWLightOS: target compiled GSettings schemas missing after glib-compile-schemas' >&2
    exit 1
}
grep -q '^intellihide=false$' /usr/share/glib-2.0/schemas/90-xwlightos-dash-to-dock.gschema.override || {
    echo 'XWLightOS: target dash-to-dock schema override does not force intellihide off' >&2
    exit 1
}

# Target-side brand-icon delivery for the Settings About panel (mirror
# of the 1700 live hook, user 2026-10-25: About icon still shows the
# vendor logo). unpackfs copies the live root, so the live hook's copies
# and refreshed caches normally ride over intact; re-run both here so a
# later target-side trigger that rebuilds an icon cache without the
# brand files cannot silently revert the About panel to the vendor
# logo. Branding must never break an installation, so every step here
# only warns: the live image already carries the brand files, and a
# missing cache tool in the target is not a reason to fail the install.
for _theme in WhiteSur-light WhiteSur; do
    _appdir="/usr/share/icons/$_theme/scalable/apps"
    if [ -d "$_appdir" ]; then
        for _icon in xwlightos-logo distributor-logo; do
            if [ -s "/usr/share/icons/hicolor/scalable/apps/$_icon.svg" ]; then
                cp -a "/usr/share/icons/hicolor/scalable/apps/$_icon.svg" "$_appdir/$_icon.svg" 2>/dev/null || {
                    echo "XWLightOS: target brand icon copy failed for $_theme/$_icon (About panel may fall back to hicolor)" >&2
                }
            fi
        done
    fi
done
unset _theme _appdir _icon
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    for _dir in /usr/share/icons/hicolor /usr/share/icons/WhiteSur-light /usr/share/icons/WhiteSur; do
        if [ -d "$_dir" ]; then
            gtk-update-icon-cache -f "$_dir" >/dev/null 2>&1 || {
                echo "XWLightOS: target gtk-update-icon-cache failed for $_dir (About brand icon may stay invisible to cache-driven lookup)" >&2
            }
        fi
    done
    unset _dir
fi
if command -v gtk4-update-icon-cache >/dev/null 2>&1; then
    for _dir in /usr/share/icons/hicolor /usr/share/icons/WhiteSur-light /usr/share/icons/WhiteSur; do
        if [ -d "$_dir" ]; then
            gtk4-update-icon-cache -f "$_dir" >/dev/null 2>&1 || true
        fi
    done
    unset _dir
fi

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
