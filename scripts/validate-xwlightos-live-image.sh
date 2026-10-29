#!/usr/bin/env bash
# Verify the finished XWLightOS 1.0 ISO, not merely the source configuration.
# This is intentionally read-only: it extracts selected files from the final
# squashfs and checks installer-critical paths, package entry points and the
# live-session privilege policy (passwordless sudo for the disposable live
# user; installed systems must never inherit it).
set -euo pipefail

validation_error() {
    status="$?"
    echo "final ISO validation failed near line $1" >&2
    exit "$status"
}
trap 'validation_error $LINENO' ERR

# Full squashfs verification must recreate device nodes and security xattrs;
# run as root so permission warnings are not mistaken for data corruption.
[ "$(id -u)" = 0 ] || {
    echo 'run final ISO validation as root (sudo) for full squashfs integrity checking' >&2
    exit 2
}

[ "$#" -eq 1 ] || {
    echo "usage: $0 XWLightOS-1.0-amd64-livecd.iso" >&2
    exit 2
}

ISO="$1"
[ -s "$ISO" ] || {
    echo "ISO is missing or empty: $ISO" >&2
    exit 1
}
for command in xorriso unsquashfs lsinitramfs grep; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required command is unavailable: $command" >&2
        exit 1
    }
done

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT
FS="$WORK/filesystem.squashfs"
LIST="$WORK/squashfs.list"

INITRD="$WORK/initrd.img"
xorriso -osirrox on -indev "$ISO" \
    -extract /live/filesystem.squashfs "$FS" \
    -extract /live/initrd.img "$INITRD" >/dev/null 2>&1
[ -s "$FS" ] || {
    echo "final ISO lacks /live/filesystem.squashfs" >&2
    exit 1
}
[ -s "$INITRD" ] || {
    echo "final ISO lacks /live/initrd.img" >&2
    exit 1
}
# A kernel panic reporting "No working init found" is detectable without a VM.
# Fully enumerate the archive to force decompression, then require its init entry.
INITRD_LIST="$WORK/initrd.list"
if ! lsinitramfs "$INITRD" > "$INITRD_LIST" || ! grep -qx 'init' "$INITRD_LIST"; then
    echo 'final ISO contains an invalid Live initrd or lacks its /init entry' >&2
    exit 1
fi

# Listing the directory tree is insufficient: a damaged compressed data block
# can leave names visible while applications fail at runtime. Fully expand the
# squashfs before any path-level inspection so a corrupt ISO cannot pass CI.
FULL_ROOT="$WORK/full-root"
if ! unsquashfs -d "$FULL_ROOT" "$FS" >/dev/null; then
    echo 'final ISO contains a corrupt or unreadable squashfs data block' >&2
    exit 1
fi
unsquashfs -l "$FS" > "$LIST"

require_path() {
    local path="$1"
    grep -q -E "(^|/)${path//./\\.}$" "$LIST" || {
        echo "missing path in final squashfs: /$path" >&2
        exit 1
    }
}

cat_image_file() {
    local path="$1" output="$2"
    unsquashfs -cat "$FS" "$path" > "$output"
}

# Calamares unpackfs must contain these executables and functional modules.
require_path 'usr/bin/unsquashfs'
require_path 'usr/bin/rsync'
require_path 'usr/bin/chvt'
require_path 'etc/calamares/branding/xwlightos/show.qml'
require_path 'etc/calamares/branding/xwlightos/stylesheet.qss'
require_path 'etc/calamares/modules/xwlightos-postinstall.conf'
require_path 'usr/local/libexec/xwlightos-target-postinstall.sh'
require_path 'usr/local/libexec/xwlightos-installed-cleanup'
require_path 'etc/systemd/system/xwlightos-installed-cleanup.service'
require_path 'usr/local/bin/xwlightos-installer'
require_path 'usr/local/sbin/xwlightos-live-session-init'
# 用户 2026-10-19 邮件批准：触屏通用兼容修法（1620 钩子，两阶段方案）。
# 开机脚本 + systemd 服务 + 已知 ID 名单必须打包进镜像。
require_path 'usr/local/sbin/xwlightos-touchscreen-fix.sh'
require_path 'etc/systemd/system/xwlightos-touchscreen-fix.service'
require_path 'etc/xwlightos/touchscreen-known-ids.conf'
# 诊断版（Build 40 触屏诊断，1621 钩子）：开机自动弹窗的诊断脚本、
# 启动器与桌面自启动入口必须进镜像。正式版确认根因后删除。
require_path 'usr/local/sbin/xwlightos-touch-diag.sh'
require_path 'usr/local/sbin/xwlightos-touch-diag-launch.sh'
require_path 'etc/xdg/autostart/xwlightos-touch-diag.desktop'
# 用户 2026-10-19 邮件：完善驱动（显卡/摄像头/声卡）。新增驱动包必须进镜像。
# 显卡：Vulkan（mesa-vulkan-drivers）、VDPAU（mesa-vdpau-drivers）、
# 老 Intel VA-API（i965-va-driver）、vainfo 诊断工具。
require_path 'usr/bin/vainfo'
require_path 'usr/lib/x86_64-linux-gnu/dri/i965_drv_video.so'
# 音频：PulseAudio 兼容层（pipewire-pulse，Firefox/VLC 等 PA 应用必需）、
# ALSA 兼容层（pipewire-alsa）、蓝牙音频（libspa-0.2-bluetooth）、pavucontrol。
require_path 'usr/bin/pipewire-pulse'
require_path 'usr/bin/pavucontrol'
# 摄像头：cheese（GNOME 拍照应用）。
require_path 'usr/bin/cheese'
require_path 'usr/sbin/gdm3'
require_path 'etc/gdm3/daemon.conf'
require_path 'etc/dconf/db/local.d/00-xwlightos-gnome'
require_path 'usr/share/themes/WhiteSur-Dark'
require_path 'usr/share/themes/WhiteSur-Dark/gnome-shell'
# dconf gtk-theme='WhiteSur-Light' 供 GTK3 应用：gtk-3.0 必须真实存在。
require_path 'usr/share/themes/WhiteSur-Dark/gtk-3.0'
require_path 'usr/share/themes/WhiteSur-Light'
require_path 'usr/share/themes/WhiteSur-Light/gnome-shell'
# 用户 2026-10-25 邮件第 1 项（所有程序还是黑色文字+背景）：GTK2/Qt5 通道
# 此前在镜像级从未被断言过——1550 钩子只断言 gtk-3.0/gtk-4.0/gnome-shell。
# WhiteSur-Light/gtk-2.0/gtkrc 必须在镜像里（上游自带或仓库兜底文件），
# 否则 /etc/gtk-2.0/gtkrc 与 Qt5 gtk2 平台主题指向一个没有 GTK2 样式的
# 主题名，GTK2/Qt5 应用落在无控回落调色板上。
require_path 'usr/share/themes/WhiteSur-Light/gtk-2.0/gtkrc'
require_path 'etc/gtk-2.0/gtkrc'
# 用户 2026-10-25 邮件第 1 项：系统级 GTK3/GTK4 settings.ini（/etc/xdg，
# XDG_CONFIG_DIRS 默认位置）必须在镜像里，且深色必须显式关闭；此前
# 系统级只有 skel 的 GTK3 一份，GTK4 系统级与不走 GNOME 会话的应用
# 没有任何浅色默认值。
require_path 'etc/xdg/gtk-3.0/settings.ini'
require_path 'etc/xdg/gtk-4.0/settings.ini'
# 用户 2026-10-25 邮件第 1 项：XDG 桌面门户必须在镜像里——Qt6 与
# Electron/Chromium 类应用经门户 Settings 接口查询浅色/深色，包清单
# 此前只有 xdg-utils，从未显式声明门户本体与 GTK 后端。D-Bus 服务文件
# 是两包各自最稳定的存在性证据。
require_path 'usr/share/dbus-1/services/org.freedesktop.portal.Desktop.service'
require_path 'usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.gtk.service'
require_path 'usr/share/icons/WhiteSur'
require_path 'usr/share/icons/WhiteSur-light'
# User mail 2026-10-28 item 3, root cause nailed 2026-10-29 from the Debian
# source package: Debian's gnome-control-center is built with
# DISTRIBUTOR_LOGO hard coded to the desktop-base vendor-logos
# alternative slave, so the Settings About panel never consults os-release
# LOGO or the icon theme. The 1705 live hook registers our own
# vendor-logos alternative at priority 60; the About panel path must
# therefore resolve through /etc/alternatives to our brand file, never to
# Debian's emblem. Resolve the chain inside the unpacked root: the links
# are absolute image paths, so readlink -f on the host would escape the
# tree and must not be used.
require_path 'usr/share/icons/vendor/scalable/emblems/emblem-vendor.svg'
require_path 'etc/alternatives/emblem-vendor-scalable'
require_path 'usr/share/xwlightos/branding/xwlightos-logo.svg'
_resolve_in_root() {
    local _p="$1" _t _hops=0
    while [ -L "$FULL_ROOT$_p" ] && [ "$_hops" -lt 5 ]; do
        _t="$(readlink "$FULL_ROOT$_p")"
        case "$_t" in
            /*) _p="$_t" ;;
            *) _p="$(dirname "$_p")/$_t" ;;
        esac
        _hops=$((_hops + 1))
    done
    echo "$_p"
}
VENDOR_RESOLVED="$(_resolve_in_root /usr/share/icons/vendor/scalable/emblems/emblem-vendor.svg)"
if [ "$VENDOR_RESOLVED" != /usr/share/xwlightos/branding/xwlightos-logo.svg ]; then
    echo "vendor emblem resolves to '$VENDOR_RESOLVED', not the XWLightOS brand file (About panel would show the Debian logo)" >&2
    exit 1
fi
test -f "$FULL_ROOT$VENDOR_RESOLVED" || {
    echo 'vendor emblem target brand file is missing from the final image' >&2
    exit 1
}
# WhiteSur GDM 登录主题（1560 钩子，等价于上游 tweaks.sh -g）：版本标记文件。
require_path 'etc/xwlightos/whitesur-gdm-theme'
# 用户 2026-10-23 邮件：安装必须全程离线。bootloader-config 补丁（1565 钩子）
# 只在目标已带 grub2-common（grub-install/update-grub）与对应平台模块时才
# 跳过 apt；这里断言镜像里四者齐全，否则补丁回退到 apt、断网安装必挂。
require_path 'usr/sbin/update-grub'
require_path 'usr/sbin/grub-install'
require_path 'usr/lib/grub/x86_64-efi/modinfo.sh'
require_path 'usr/lib/grub/i386-pc/modinfo.sh'
BOOTLOADER_CONFIG="$WORK/bootloader-config"
cat_image_file 'usr/sbin/bootloader-config' "$BOOTLOADER_CONFIG"
grep -q 'skipping apt (offline install)' "$BOOTLOADER_CONFIG" || {
    echo 'bootloader-config offline patch is missing (offline install would fail)' >&2
    exit 1
}
# Build 56 回归断言（Run 39043461212）：编译进 gresource 的资源列表里必须有
# 默认 shell 样式表 gnome-shell.css，否则 gnome-shell 回退无样式表可用、
# 会话渲染不出来、QEMU 烟测失败。
GDM_MARKER="$WORK/whitesur-gdm-theme"
cat_image_file 'etc/xwlightos/whitesur-gdm-theme' "$GDM_MARKER"
grep -q '^/org/gnome/shell/theme/gnome-shell\.css$' "$GDM_MARKER" || {
    echo 'GDM gresource lacks the default gnome-shell.css fallback (Build 56 regression)' >&2
    exit 1
}
# 用户 2026-10-18 邮件：系统默认白色。
DCLOWOS_DCONF="$WORK/00-xwlightos-gnome"
cat_image_file 'etc/dconf/db/local.d/00-xwlightos-gnome' "$DCLOWOS_DCONF"
grep -q "^color-scheme='prefer-light'$" "$DCLOWOS_DCONF" || {
    echo 'dconf default color-scheme is not prefer-light (system default must be white)' >&2
    exit 1
}
# 用户 2026-10-25 邮件第 1 项：系统级与 skel 的 GTK 设置必须逐文件验值，
# 不能只验文件存在——深色开关一旦漏写 false，GTK3/GTK4 应用就可能走深色。
XDG_GTK3="$WORK/xdg-gtk3-settings.ini"
cat_image_file 'etc/xdg/gtk-3.0/settings.ini' "$XDG_GTK3"
grep -q '^gtk-theme-name=WhiteSur-Light$' "$XDG_GTK3" || {
    echo 'system gtk-3.0 settings.ini theme is not WhiteSur-Light' >&2; exit 1; }
grep -q '^gtk-application-prefer-dark-theme=false$' "$XDG_GTK3" || {
    echo 'system gtk-3.0 settings.ini does not pin prefer-dark off' >&2; exit 1; }
XDG_GTK4="$WORK/xdg-gtk4-settings.ini"
cat_image_file 'etc/xdg/gtk-4.0/settings.ini' "$XDG_GTK4"
grep -q '^gtk-theme-name=WhiteSur-Light$' "$XDG_GTK4" || {
    echo 'system gtk-4.0 settings.ini theme is not WhiteSur-Light' >&2; exit 1; }
grep -q '^gtk-application-prefer-dark-theme=false$' "$XDG_GTK4" || {
    echo 'system gtk-4.0 settings.ini does not pin prefer-dark off' >&2; exit 1; }
SYS_GTK2RC="$WORK/sys-gtk2rc"
cat_image_file 'etc/gtk-2.0/gtkrc' "$SYS_GTK2RC"
grep -q '^gtk-theme-name="WhiteSur-Light"$' "$SYS_GTK2RC" || {
    echo 'system gtk-2.0 gtkrc theme is not WhiteSur-Light' >&2; exit 1; }
SKEL_GTK3="$WORK/skel-gtk3-settings.ini"
cat_image_file 'etc/skel/.config/gtk-3.0/settings.ini' "$SKEL_GTK3"
grep -q '^gtk-application-prefer-dark-theme=false$' "$SKEL_GTK3" || {
    echo 'skel gtk-3.0 settings.ini does not pin prefer-dark off' >&2; exit 1; }
# 用户 2026-10-18 邮件：Windows 常用中文字体别名（微软雅黑等 → Noto CJK）。
require_path 'etc/fonts/conf.d/70-xwlightos-windows-font-aliases.conf'
# 用户 2026-10-18 邮件「字体问题」：构建期在线安装的微软英文核心字体
# （1590 钩子，ttf-mscorefonts-installer），防 Office 文档错位。
require_path 'usr/share/fonts/truetype/msttcorefonts/Arial.ttf'
require_path 'usr/share/fonts/truetype/msttcorefonts/Times_New_Roman.ttf'
require_path 'usr/share/fonts/truetype/msttcorefonts/Courier_New.ttf'
# Desktop Icons NG (ding) 扩展必须装进镜像。
require_path 'usr/share/gnome-shell/extensions/ding@rastersoft.com'
# 用户 2026-10-23 邮件指令：不需要"此电脑"了（1570 钩子已删除），
# Nautilus 默认打开"其他位置"（1571 钩子 + xwlightos-default-location.py）。
# 旧"此电脑"扩展文件必须不在镜像里，新扩展必须在。
require_path 'usr/share/nautilus-python/extensions/xwlightos-default-location.py'
for gone in 'usr/share/nautilus-python/extensions/nautilus-my-computer.py' \
            'usr/share/glib-2.0/schemas/io.github.yannmasoch.nautilus-my-computer.gschema.xml'; do
    if grep -q -E "(^|/)${gone}$" "$LIST"; then
        echo "removed nautilus-my-computer extension still present in final ISO: $gone" >&2
        exit 1
    fi
done
# XWLightOS 已移除 AI 栈：ai-home.tar.gz 不应再要求存在（见下文否定检查）。
require_path 'usr/local/bin/xwlightos-power-action'
require_path 'usr/local/bin/xwlightos-logout'
require_path 'usr/local/libexec/xwlightos-privileged-action'
require_path 'usr/share/polkit-1/actions/im.system-intel-mic.xwlightos.privileged-action.policy'
require_path 'usr/bin/fcitx5'
require_path 'etc/skel/.config/fcitx5/profile'
require_path 'etc/skel/.config/fcitx5/config'
# 用户 2026-10-18 邮件：程序列表只保留「fcitx 设置」
# （org.fcitx.fcitx5-config-qt.desktop），「fcitx5」/「fcitx5 迁移助手」等
# 多余启动器必须不在镜像里（1580 钩子删除）。
require_path 'usr/share/applications/org.fcitx.fcitx5-config-qt.desktop'
for pruned in org.fcitx.Fcitx5.desktop fcitx5-configtool.desktop \
    org.fcitx.fcitx5-migrator.desktop kbd-layout-viewer5.desktop; do
    if grep -q -E "(^|/)usr/share/applications/${pruned}$" "$LIST"; then
        echo "redundant fcitx launcher still present in final ISO: $pruned" >&2
        exit 1
    fi
done

# The system must use GDM, never LightDM. Only fail on the actual LightDM
# binary or its config directory, not on docs mentioning "lightdm".
if grep -qE '(^|/)usr/sbin/lightdm$|(^|/)etc/lightdm/' "$LIST"; then
    echo 'final ISO still contains LightDM files' >&2
    exit 1
fi
# GNOME/GDM owns the graphical session. GDM autologins the Live user and
# forces the X11 session for VM compatibility.
# 根因回归断言（2026-10-17）：Debian 的 gdm3 打包时 -Dcustom-conf 指向
# /etc/gdm3/daemon.conf，GDM 从不读 /etc/gdm3/custom.conf。自动登录配置曾误放
# custom.conf 导致 10-11 后自动登录从未生效。此处断言 GDM 真正会读的文件。
GDM_CONF="$WORK/gdm-daemon.conf"
cat_image_file 'etc/gdm3/daemon.conf' "$GDM_CONF"
grep -q '^AutomaticLoginEnable=True$' "$GDM_CONF"
grep -q '^AutomaticLogin=user$' "$GDM_CONF"
grep -q '^WaylandEnable=False$' "$GDM_CONF"
# 若有人又把 [daemon] 自动登录写进 custom.conf（GDM 不读），在这里直接失败，
# 而不是等 QEMU 门禁在 260 秒后才暴露。
if cat_image_file 'etc/gdm3/custom.conf' "$WORK/gdm-custom-stray.conf" 2>/dev/null; then
    if grep -q 'AutomaticLogin' "$WORK/gdm-custom-stray.conf"; then
        echo 'etc/gdm3/custom.conf contains AutomaticLogin settings, but Debian GDM never reads that file; move them to etc/gdm3/daemon.conf' >&2
        exit 1
    fi
fi
# 自动登录的前提：live-session-init.service 必须在镜像里真正被启用。
# 曾经出过 wants 下的符号链接指向改名前的旧文件名（断链），导致服务开机
# 从未运行、user 账户从未创建、GDM 自动登录直接掉到输用户名界面，而 QEMU
# 烟测只看画面非黑、把登录界面当成了桌面。此处做静态回归断言。
SVC_WORK="$WORK/svc-check"
rm -rf "$SVC_WORK"
unsquashfs -f -d "$SVC_WORK" "$FS" \
    etc/systemd/system/xwlightos-live-session-init.service \
    etc/systemd/system/multi-user.target.wants/xwlightos-live-session-init.service \
    >/dev/null 2>&1
WANTS_LINK="$SVC_WORK/etc/systemd/system/multi-user.target.wants/xwlightos-live-session-init.service"
[ -e "$WANTS_LINK" ] || { echo 'xwlightos-live-session-init.service wants symlink is dangling (autologin user would never be created)' >&2; exit 1; }
[ "$(readlink "$WANTS_LINK")" = '../xwlightos-live-session-init.service' ] || { echo 'xwlightos-live-session-init.service wants symlink points at the wrong unit' >&2; exit 1; }
grep -q '^Before=gdm.service$' "$SVC_WORK/etc/systemd/system/xwlightos-live-session-init.service" || { echo 'xwlightos-live-session-init.service lost its Before=gdm.service ordering' >&2; exit 1; }
# 用户 2026-10-19 邮件批准：触屏修复服务必须在镜像里真正被启用，
# 否则开机脚本从不运行、触屏问题依旧。
unsquashfs -f -d "$SVC_WORK" "$FS" \
    etc/systemd/system/xwlightos-touchscreen-fix.service \
    etc/systemd/system/multi-user.target.wants/xwlightos-touchscreen-fix.service \
    >/dev/null 2>&1
TS_WANTS_LINK="$SVC_WORK/etc/systemd/system/multi-user.target.wants/xwlightos-touchscreen-fix.service"
[ -e "$TS_WANTS_LINK" ] || { echo 'xwlightos-touchscreen-fix.service wants symlink is dangling (touchscreen fix would never run at boot)' >&2; exit 1; }
[ "$(readlink "$TS_WANTS_LINK")" = '../xwlightos-touchscreen-fix.service' ] || { echo 'xwlightos-touchscreen-fix.service wants symlink points at the wrong unit' >&2; exit 1; }
grep -q '^ExecStart=/usr/local/sbin/xwlightos-touchscreen-fix.sh$' "$SVC_WORK/etc/systemd/system/xwlightos-touchscreen-fix.service" || { echo 'xwlightos-touchscreen-fix.service lost its ExecStart' >&2; exit 1; }
# 通用兜底：镜像 systemd 配置里不允许出现任何断链（改名残留最爱藏在这里）。
# 注意两个坑，Build 49（Run 38899185892）曾被它们坑过一次：
# 1) vendor 的 wants 符号链接（如 pipewire、NetworkManager、display-manager）
#    指向 /usr/lib/systemd/... 下的 unit 文件，必须把 usr/lib/systemd 连同
#    顶层 lib 符号链接一起解出来，否则会被误判成断链。
# 2) find -xtype l 对解包目录里的绝对路径符号链接会按宿主机真实的 / 去判定，
#    同样是误报。所以不直接用 -xtype l，而是逐个把目标映射回解包根目录再判定。
unsquashfs -f -d "$SVC_WORK" "$FS" etc/systemd usr/lib/systemd lib >/dev/null 2>&1
DANGLING=""
while IFS= read -r link; do
    target=$(readlink "$link")
    case "$target" in
        /*) resolved="$SVC_WORK$target" ;;
        *)  resolved="$(dirname "$link")/$target" ;;
    esac
    resolved=$(realpath -m "$resolved")
    # 只有目标落在我们从镜像里解出来的目录下时才做判定：没解出来的位置
    # （如 /run、/etc/alternatives）无法从 squashfs 静态判定，只能跳过，
    # 否则又会重蹈 Build 49 的误报。
    case "$resolved" in
        "$SVC_WORK/etc/systemd"*|"$SVC_WORK/usr/lib/systemd"*|"$SVC_WORK/lib"*) ;;
        *) continue ;;
    esac
    [ -e "$resolved" ] || DANGLING="$DANGLING
$link -> $target"
done < <(find "$SVC_WORK/etc/systemd" -type l 2>/dev/null)
[ -z "$DANGLING" ] || { echo "dangling symlinks in image systemd config:$DANGLING" >&2; exit 1; }
# Openssh default-off (user 2026-10-25: openssh error at both boot and
# shutdown). The 1710 build hook disables ssh/sshd service and socket, but
# a hook that silently failed would still ship a boot-path sshd: assert
# from the finished squashfs that no enable link for it survives, in either
# list spelling (with or without a leading slash). The package unit file
# itself under /usr/lib/systemd/system is allowed to stay; only the
# /etc/systemd enable links put sshd on the boot/shutdown path.
for _ssh_wants in \
    etc/systemd/system/multi-user.target.wants/ssh.service \
    etc/systemd/system/multi-user.target.wants/sshd.service \
    etc/systemd/system/multi-user.target.wants/ssh.socket \
    etc/systemd/system/multi-user.target.wants/sshd.socket \
    etc/systemd/system/sshd.service \
    etc/systemd/system/ssh.socket; do
    if grep -qE "(^|/)${_ssh_wants//./\\.}$" "$LIST"; then
        echo "openssh service still enabled in live image: /$_ssh_wants (1710 hook did not disable it)" >&2
        exit 1
    fi
done
# 自动登录的根因级断言（Build 50，Run 38905790559）：QEMU 截图证明 greeter
# 停在"用户名"输入框——user 账户在 GDM 启动时根本不存在。静态配置全对也
# 救不了运行时建不出用户。从 Build 51 起 user 在构建期就 bake 进镜像，
# GDM 启动时必然可见；此处断言 bake 结果真实存在。
USER_WORK="$WORK/user-check"
rm -rf "$USER_WORK"
unsquashfs -f -d "$USER_WORK" "$FS" \
    etc/passwd etc/shadow etc/group var/lib/AccountsService/users/user \
    var/lib/AccountsService/icons/user \
    usr/local/sbin/xwlightos-live-session-init \
    >/dev/null 2>&1
grep -q '^user:x:[0-9][0-9]*:[0-9][0-9]*:.*:/home/user:/bin/bash$' "$USER_WORK/etc/passwd" \
    || { echo 'live user "user" is not baked into the image passwd (GDM autologin would fall back to the username prompt)' >&2; exit 1; }
# 密码域必须为空（passwd -d），绝不能是锁定态（! 开头）：锁定账户可能让
# GDM 自动登录的 account 栈拒绝会话。
grep -q '^user::' "$USER_WORK/etc/shadow" \
    || { echo 'live user "user" password is not empty in the image shadow (must be unlocked for GDM autologin)' >&2; exit 1; }
grep -q '^XSession=gnome-xorg$' "$USER_WORK/var/lib/AccountsService/users/user" \
    || { echo 'AccountsService session seed for the live user is missing (autologin session would be ambiguous)' >&2; exit 1; }
# 用户 2026-10-25 08:29 邮件第 8 项：live 用户的账户图标必须指向品牌头像，
# 头像文件本身必须进镜像，否则设置“用户”页与登录页仍显示通用头像/回落标识。
grep -q '^Icon=/var/lib/AccountsService/icons/user$' "$USER_WORK/var/lib/AccountsService/users/user" \
    || { echo 'live user AccountsService file has no brand Icon entry (account icon would fall back)' >&2; exit 1; }
[ -s "$USER_WORK/var/lib/AccountsService/icons/user" ] \
    || { echo 'live user brand avatar icon file is missing from the image' >&2; exit 1; }
# 开机兜底脚本绝不能再锁账户，否则会把 bake 好的空密码账户重新锁死。
if grep -q 'passwd --lock' "$USER_WORK/usr/local/sbin/xwlightos-live-session-init"; then
    echo 'xwlightos-live-session-init still locks the live account (would break GDM autologin)' >&2
    exit 1
fi
# GDM greeter 去品牌：logo 覆盖 + dconf profile 必须含 system-db:gdm
# （Debian 的 gdm3 自带 profile 里没有 system-db，不加这行 gdm.d keyfile
# 会被 greeter 直接忽略，登录界面会继续显示 debian 徽标）。
GDM_BRAND_WORK="$WORK/gdm-brand-check"
rm -rf "$GDM_BRAND_WORK"
unsquashfs -f -d "$GDM_BRAND_WORK" "$FS" \
    etc/dconf/profile/gdm etc/dconf/db/gdm.d/01-xwlightos-branding \
    usr/share/xwlightos/branding/xwlightos-mark.svg \
    usr/share/xwlightos/branding/xwlightos-logo.svg \
    >/dev/null 2>&1
grep -q '^system-db:gdm$' "$GDM_BRAND_WORK/etc/dconf/profile/gdm" \
    || { echo 'gdm dconf profile lacks system-db:gdm (greeter branding keyfile would be ignored)' >&2; exit 1; }
# 用户 2026-10-24 指令：方形槽位（GDM 徽标/安装器）只用纯 Logo（无文字、
# 方形画布），420x120 带文字横幅被压窄变形。mark.svg 横幅保留作横幅用途。
grep -q "^logo='/usr/share/xwlightos/branding/xwlightos-logo.svg'$" "$GDM_BRAND_WORK/etc/dconf/db/gdm.d/01-xwlightos-branding" \
    || { echo 'GDM greeter logo override is not the pure logo (banner would be squeezed)' >&2; exit 1; }
[ -s "$GDM_BRAND_WORK/usr/share/xwlightos/branding/xwlightos-logo.svg" ] \
    || { echo 'XWLightOS pure logo SVG for the GDM greeter is missing' >&2; exit 1; }
# 用户 2026-10-23 邮件：系统图标换成新的 420x120 SVG（XW 几何符号 +
# "XW LightOS" + "by SYSTEM-Intel-MIC"）。旧的 256x256 方块标若还在，
# 说明替换漏了地方。

grep -q 'viewBox="0 0 420 120"' "$GDM_BRAND_WORK/usr/share/xwlightos/branding/xwlightos-mark.svg" \
    || { echo 'XWLightOS mark SVG is not the new 420x120 user-supplied logo' >&2; exit 1; }
grep -q 'by SYSTEM-Intel-MIC' "$GDM_BRAND_WORK/usr/share/xwlightos/branding/xwlightos-mark.svg" \
    || { echo 'XWLightOS mark SVG lacks the user-supplied byline' >&2; exit 1; }
# 用户 2026-10-23 邮件：开机动画改为效果稿（Plymouth script 主题复刻）。
# 主题文件 + 默认主题配置必须进 squashfs，且主题必须被打进 initrd
# （开机 early-userspace 显示动画靠 initrd 里的那份）。
PLYMOUTH_WORK="$WORK/plymouth-check"
rm -rf "$PLYMOUTH_WORK"
unsquashfs -f -d "$PLYMOUTH_WORK" "$FS" \
    usr/share/plymouth/themes/xwlightos \
    etc/plymouth/plymouthd.conf \
    >/dev/null 2>&1
for plymouth_asset in xwlightos.plymouth xwlightos.script mark.png \
    mark-glow.png brand-main.png brand-sub.png dot.png bar-bg.png bar-fg.png; do
    [ -s "$PLYMOUTH_WORK/usr/share/plymouth/themes/xwlightos/$plymouth_asset" ] \
        || { echo "plymouth xwlightos theme asset missing in image: $plymouth_asset" >&2; exit 1; }
done
grep -q '^Theme=xwlightos$' "$PLYMOUTH_WORK/etc/plymouth/plymouthd.conf" \
    || { echo 'plymouth default theme is not xwlightos (1630 hook did not run or failed)' >&2; exit 1; }
lsinitramfs "$INITRD" | grep -q 'usr/share/plymouth/themes/xwlightos/xwlightos.script' \
    || { echo 'plymouth xwlightos theme is not inside initrd (boot splash would not show)' >&2; exit 1; }
# 2026-10-25 Plymouth 排查补强：只查主题脚本不够，渲染链（script 插件、
# DRM/framebuffer 渲染器、i915 驱动）缺任一环都会导致 initrd 阶段无动画。
# Debian plymouth hook 本应把这几项都打进 initrd，这里逐项断言，缺失即拦下。
for plymouth_initrd_item in 'plymouth/script.so' 'plymouth/renderers/drm.so' \
    'plymouth/renderers/frame-buffer.so' 'drm/i915/i915.ko'; do
    lsinitramfs "$INITRD" | grep -q "$plymouth_initrd_item" \
        || { echo "plymouth initrd lacks renderer/driver item: $plymouth_initrd_item" >&2; exit 1; }
done
# GDM 登录页光标主题（01-xwlightos-branding）：greeter 不读用户会话的 dconf，
# 不显式设置就永远是 Adwaita 黑指针。
grep -q "^cursor-theme='WhiteSur-cursors'$" "$GDM_BRAND_WORK/etc/dconf/db/gdm.d/01-xwlightos-branding" \
    || { echo 'GDM greeter cursor-theme is not WhiteSur-cursors (login screen pointer would stay Adwaita)' >&2; exit 1; }
# 用户会话 dconf profile 必须含 system-db:local，否则 /etc/dconf/db/local.d/
# 下的全部桌面默认（WhiteSur 主题、扩展启用、dock、输入法）会被会话静默忽略
# ——登录页有主题而桌面没有，就是这个原因（用户 2026-10-18 真机反馈）。
USER_DCONF_WORK="$WORK/user-dconf-check"
rm -rf "$USER_DCONF_WORK"
unsquashfs -f -d "$USER_DCONF_WORK" "$FS" \
    etc/dconf/profile/user \
    >/dev/null 2>&1
grep -q '^system-db:local$' "$USER_DCONF_WORK/etc/dconf/profile/user" \
    || { echo 'user dconf profile lacks system-db:local (desktop theme/extensions/dock defaults would be ignored)' >&2; exit 1; }
# 系统身份去品牌：hostname / lsb-release / motd 不许再出现 debian。
HOSTNAME_WORK="$WORK/hostname-check"
cat_image_file 'etc/hostname' "$HOSTNAME_WORK"
grep -q '^xwlightos$' "$HOSTNAME_WORK" \
    || { echo 'image hostname is not xwlightos (live-build default "debian" would leak into prompts)' >&2; exit 1; }
HOSTS_WORK="$WORK/hosts-check"
cat_image_file 'etc/hosts' "$HOSTS_WORK"
grep -q '^127\.0\.1\.1[[:space:]]\+xwlightos' "$HOSTS_WORK" \
    || { echo '/etc/hosts does not map 127.0.1.1 to xwlightos (sudo would warn about unresolvable host)' >&2; exit 1; }
grep -qi 'debian' "$HOSTS_WORK" \
    && { echo '/etc/hosts still mentions Debian' >&2; exit 1; } || true
LSB_WORK="$WORK/lsb-check"
cat_image_file 'etc/lsb-release' "$LSB_WORK"
grep -q '^DISTRIB_ID=XWLightOS$' "$LSB_WORK" \
    || { echo '/etc/lsb-release is not XWLightOS-branded' >&2; exit 1; }
MOTD_WORK="$WORK/motd-check"
cat_image_file 'etc/motd' "$MOTD_WORK"
grep -qi 'debian' "$MOTD_WORK" \
    && { echo '/etc/motd still mentions Debian' >&2; exit 1; } || true
grep -q 'XWLightOS' "$MOTD_WORK" \
    || { echo '/etc/motd is not XWLightOS-branded' >&2; exit 1; }
# 用户 2026-10-25 08:29 邮件第 8 项：设置“关于”里的系统图标仍是 Debian。
# 根因：GNOME 40 起“关于”面板用 /etc/os-release 查系统 Logo（freedesktop
# os-release 规范的 LOGO 字段即图标主题名），而本仓库的 os-release 从来
# 没有 LOGO 字段、图标主题里也没有品牌图标名可查，只能回落到 Debian。
# 修法两件套缺一不可：os-release 写 LOGO=xwlightos-logo，且图标主题的
# 通用回落层 hicolor 里必须真有同名图标；distributor-logo 通用名也放
# 同一份品牌纯 Logo，覆盖按通用名回落的路径。/usr/lib/os-release 同步
# 写同一份，避免直接读该路径的工具仍看到旧标识。
# 注意：镜像里 /etc/os-release 可能是 base-files 留下的指向
# /usr/lib/os-release 的符号链接，unsquashfs -cat 读链接不可靠；这里
# 直接读已完整解包的 FULL_ROOT，由系统跟随链接解析，文件与链接两种
# 形态都判得准。
grep -q '^LOGO=xwlightos-logo$' "$FULL_ROOT/etc/os-release" \
    || { echo '/etc/os-release has no LOGO=xwlightos-logo (About panel would fall back to Debian)' >&2; exit 1; }
grep -q '^LOGO=xwlightos-logo$' "$FULL_ROOT/usr/lib/os-release" \
    || { echo '/usr/lib/os-release has no LOGO=xwlightos-logo' >&2; exit 1; }
require_path 'usr/share/icons/hicolor/scalable/apps/xwlightos-logo.svg'
require_path 'usr/share/icons/hicolor/scalable/apps/distributor-logo.svg'
# 门禁补强（用户 2026-10-28 邮件第 3 项）：1700 钩子向 WhiteSur-light 的
# 拷贝是 [ -d ] 守卫的，静默跳过时旧门禁查不出来——主题目录若在成品里
# 存在，品牌图标就必须实打实在里面，而不是只信钩子脚本写过拷贝。
# 注意机制（b1736dd 构建失败教训）：require_path 查的是 unsquashfs -l
# 的扁平清单，看不穿 WhiteSur-light 的 apps 软链接——清单里文件只出现
# 在真实路径 WhiteSur/apps/scalable 下，light 路径永远查不到，用它断言
# light 路径是必败的假阳性。所以这里统一用已完整解包的 FULL_ROOT 查
# （[ -d ]/[ -e ] 都跟随链接，与图标主题的查找方式一致）；WhiteSur 真实
# 路径同样用 FULL_ROOT 查，不混用清单机制。
if [ -d "$FULL_ROOT/usr/share/icons/WhiteSur-light/apps/scalable" ]; then
    [ -e "$FULL_ROOT/usr/share/icons/WhiteSur-light/apps/scalable/distributor-logo.svg" ] || {
        echo 'brand distributor-logo is not reachable via WhiteSur-light (About panel would miss it)' >&2; exit 1; }
    [ -e "$FULL_ROOT/usr/share/icons/WhiteSur-light/apps/scalable/xwlightos-logo.svg" ] || {
        echo 'brand xwlightos-logo is not reachable via WhiteSur-light (About panel would miss it)' >&2; exit 1; }
fi
if [ -d "$FULL_ROOT/usr/share/icons/WhiteSur/apps/scalable" ]; then
    [ -e "$FULL_ROOT/usr/share/icons/WhiteSur/apps/scalable/distributor-logo.svg" ] || {
        echo 'brand distributor-logo is not in WhiteSur/apps/scalable (1700 copy did not land)' >&2; exit 1; }
    [ -e "$FULL_ROOT/usr/share/icons/WhiteSur/apps/scalable/xwlightos-logo.svg" ] || {
        echo 'brand xwlightos-logo is not in WhiteSur/apps/scalable (1700 copy did not land)' >&2; exit 1; }
fi
# 用户 2026-10-25 11:41 关于图标：光有图标文件不够——hicolor 包自带
# 的 icon-theme.cache 若不随品牌图标一起刷新，缓存驱动的查找就看
# 不见新图标。1700 钩子现已在 squashfs 生成前强制刷新，成品里该
# 缓存文件必须存在，否则关于页仍可能回落到厂商图标。
require_path 'usr/share/icons/hicolor/icon-theme.cache'
require_path 'usr/share/xwlightos/branding/xwlightos-avatar.png'
ABOUT_LOGO_WORK="$WORK/xwlightos-logo-icon.svg"
cat_image_file 'usr/share/icons/hicolor/scalable/apps/xwlightos-logo.svg' "$ABOUT_LOGO_WORK"
grep -q 'viewBox="0 0 120 120"' "$ABOUT_LOGO_WORK" || {
    echo 'About-panel brand icon is not the square pure logo' >&2; exit 1; }
grep -q '<text' "$ABOUT_LOGO_WORK" && {
    echo 'About-panel brand icon still contains text elements' >&2; exit 1; } || true
GNOME_DEFAULTS="$WORK/00-xwlightos-gnome"
cat_image_file 'etc/dconf/db/local.d/00-xwlightos-gnome' "$GNOME_DEFAULTS"
# 用户 2026-10-24 邮件第 9、11 项：过时应用也用 WhiteSur-Light，
# 全应用统一浅色、不得黑字黑底。
grep -q "^gtk-theme='WhiteSur-Light'$" "$GNOME_DEFAULTS"
# 用户 2026-10-17 邮件指令：图标 WhiteSur-light、Shell WhiteSur-Light。
grep -q "^icon-theme='WhiteSur-light'$" "$GNOME_DEFAULTS"
grep -q 'dash-to-dock@micxgx.gmail.com' "$GNOME_DEFAULTS"
# 用户 2026-10-24 22:40 最新要求：dock 直接强制永不隐藏。
# 该要求取代 2026-10-24 19:43 的“平时常驻、全屏应用才隐藏”：
# 三个隐藏开关全关，全屏应用也不隐藏。
grep -q "^autohide=false$" "$GNOME_DEFAULTS" \
    || { echo 'dash-to-dock autohide is not disabled (dock would stay hidden)' >&2; exit 1; }
grep -q "^intellihide=false$" "$GNOME_DEFAULTS" \
    || { echo 'dash-to-dock intellihide is not disabled' >&2; exit 1; }
grep -q "^autohide-in-fullscreen=false$" "$GNOME_DEFAULTS" \
    || { echo 'dash-to-dock autohide-in-fullscreen is not disabled (user requires dock never hidden)' >&2; exit 1; }
# 用户 2026-10-24 邮件《很大问题》第 1 项：智能隐藏强制写死关闭。
# dconf 默认之外另有一层 gschema 覆盖：即使 dconf 库被绕过，schema
# 默认本身也是关闭的。两层缺一不可，这里两边都断言。
GSCHEMA_OVERRIDE="$WORK/90-xwlightos-dash-to-dock.gschema.override"
cat_image_file 'usr/share/glib-2.0/schemas/90-xwlightos-dash-to-dock.gschema.override' "$GSCHEMA_OVERRIDE"
grep -q "^intellihide=false$" "$GSCHEMA_OVERRIDE" \
    || { echo 'dash-to-dock schema override does not force intellihide off' >&2; exit 1; }
grep -q "^autohide=false$" "$GSCHEMA_OVERRIDE" \
    || { echo 'dash-to-dock schema override does not force autohide off' >&2; exit 1; }
grep -q "^autohide-in-fullscreen=false$" "$GSCHEMA_OVERRIDE" \
    || { echo 'dash-to-dock schema override does not force fullscreen hiding off (user requires dock never hidden)' >&2; exit 1; }
# 用户 2026-10-25 邮件第 5 项：dock 仍自动隐藏。上面只查了键文件文本，
# 从未查过编译产物——键文件存在但编译产物缺失/过期时，成品行为仍是
# schema 默认（隐藏开），CI 却全绿。本次补查编译产物本身：两个编译
# 文件必须进镜像；有 gsettings 时再读一次编译后的 schema 默认生效值，
# 三个开关必须全是 false（只读 schema 默认，不碰用户库）。
require_path 'usr/share/glib-2.0/schemas/gschemas.compiled'
require_path 'etc/dconf/db/local'
if command -v gsettings >/dev/null 2>&1; then
    for _dock_key in autohide intellihide autohide-in-fullscreen; do
        _dock_val="$(GSETTINGS_SCHEMA_DIR="$FULL_ROOT/usr/share/glib-2.0/schemas" GSETTINGS_BACKEND=memory gsettings get org.gnome.shell.extensions.dash-to-dock "$_dock_key" 2>/dev/null)" || {
            echo "compiled dash-to-dock schema default for $_dock_key is unreadable (gschemas.compiled stale or broken)" >&2; exit 1; }
        [ "$_dock_val" = 'false' ] || {
            echo "compiled dash-to-dock schema default for $_dock_key is not false (got $_dock_val); dock would still auto-hide" >&2; exit 1; }
    done
else
    echo 'note: gsettings unavailable, skipping compiled-schema effective-value check (compiled files already asserted above)' >&2
fi
# 用户 2026-10-24 邮件第 6 项：状态栏监控扩展必须启用。
# （2026-10-23 曾移除顶栏 system-monitor 扩展的旧注释已作废：用户
# 2026-10-24 明确要求恢复 Debian 官方打包的顶栏监控扩展。）
grep -q 'system-monitor@paradoxxx.zero.gmail.com' "$GNOME_DEFAULTS" \
    || { echo 'enabled-extensions missing top-bar system-monitor' >&2; exit 1; }
# 用户 2026-10-28 邮件第 5 项：顶栏系统监视器扩展默认显示数字，不要图形。
# 上游 *-style 三档 digit/graph/both，默认全是 graph；此处五项一并钉 digit。
grep -q '^\[org/gnome/shell/extensions/system-monitor\]$' "$GNOME_DEFAULTS" \
    || { echo 'dconf defaults lack system-monitor section (top-bar monitor would default to graphs)' >&2; exit 1; }
for _mon_key in cpu-style memory-style swap-style net-style disk-style; do
    grep -q "^$_mon_key='digit'$" "$GNOME_DEFAULTS" || {
        echo "dconf system-monitor $_mon_key is not digit (top-bar monitor would show graphs)" >&2
        exit 1
    }
done
# 用户 2026-10-24 23:31 邮件：输入法面板扩展也要（重新加回启用）。
grep -q 'kimpanel@kde.org' "$GNOME_DEFAULTS" \
    || { echo 'enabled-extensions missing kimpanel input method panel extension' >&2; exit 1; }
# 用户 2026-10-25 11:41 反馈：输入法 Shift 不能切换，是多了个英语（美国）
# 输入源抢了 fcitx5 的位置（构建里从未写过 input-sources，首次登录即
# GNOME schema 默认的 xkb us；与此前 skel 漏 fcitx5 配置的触发键缺失
# 不是同一层）。修法：GNOME 输入源列表清掉——dconf 键文件（带类型注解
# 的空数组，schema-less 解析必需）与 gschema 覆盖（第二层）两处；fcitx5
# 内部的 keyboard-us 是 Shift 切换的英文一侧，必须保留，不得误伤。
grep -q '^\[org/gnome/desktop/input-sources\]$' "$GNOME_DEFAULTS" \
    || { echo 'dconf defaults lack input-sources section (redundant English (US) source would return)' >&2; exit 1; }
grep -q '^sources=@a(ss) \[\]$' "$GNOME_DEFAULTS" \
    || { echo 'dconf input-sources is not cleared (redundant English (US) source would return)' >&2; exit 1; }
INPUT_OVERRIDE="$WORK/90-xwlightos-input-sources.gschema.override"
cat_image_file 'usr/share/glib-2.0/schemas/90-xwlightos-input-sources.gschema.override' "$INPUT_OVERRIDE"
grep -q '^\[org.gnome.desktop.input-sources\]$' "$INPUT_OVERRIDE" \
    || { echo 'input-sources schema override section missing' >&2; exit 1; }
grep -q '^sources=\[\]$' "$INPUT_OVERRIDE" \
    || { echo 'input-sources schema override does not clear sources' >&2; exit 1; }
FCITX5_PROFILE="$WORK/fcitx5-profile"
cat_image_file 'etc/skel/.config/fcitx5/profile' "$FCITX5_PROFILE"
grep -q '^Name=keyboard-us$' "$FCITX5_PROFILE" \
    || { echo 'fcitx5 keyboard-us missing from skel profile (Shift would have no English side)' >&2; exit 1; }
grep -q '^Name=pinyin$' "$FCITX5_PROFILE" \
    || { echo 'fcitx5 pinyin missing from skel profile' >&2; exit 1; }
grep -q '^DefaultIM=pinyin$' "$FCITX5_PROFILE" \
    || { echo 'fcitx5 DefaultIM is not pinyin' >&2; exit 1; }
# 编译后的 schema 默认生效值（与 dock 三开关同款查法）：gschemas.compiled
# 已在前面断言存在；有 gsettings 时再读一次，空列表读出来是 @a(ss) []。
if command -v gsettings >/dev/null 2>&1; then
    _input_src="$(GSETTINGS_SCHEMA_DIR="$FULL_ROOT/usr/share/glib-2.0/schemas" GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.input-sources sources 2>/dev/null)" || {
        echo 'compiled input-sources schema default is unreadable (gschemas.compiled stale or broken)' >&2; exit 1; }
    [ "$_input_src" = '@a(ss) []' ] || {
        echo "compiled input-sources schema default is not empty (got $_input_src); redundant English (US) source would return" >&2; exit 1; }
else
    echo 'note: gsettings unavailable, skipping compiled input-sources effective-value check' >&2
fi
# 用户 2026-10-24 邮件第 6、10 项：状态栏监控与输入法面板扩展必须启用。
# （2026-10-23 曾移除顶栏 system-monitor 扩展的旧注释已作废：用户
# 2026-10-24 明确要求恢复 Debian 官方打包的顶栏监控扩展。）
for _ext in 'apps-menu@gnome-shell-extensions.gcampax.github.com' \
             'ding@rastersoft.com' \
             'native-window-placement@gnome-shell-extensions.gcampax.github.com' \
             'places-menu@gnome-shell-extensions.gcampax.github.com' \
             'drive-menu@gnome-shell-extensions.gcampax.github.com'; do
    grep -q "$_ext" "$GNOME_DEFAULTS" || {
        echo "enabled-extensions missing $_ext" >&2
        exit 1
    }
done
# 以下两处旧断言已作废（Build 32 失败根因，2026-10-25 修复）：
# 10-23 移除顶栏 system-monitor 扩展时留下的“启用列表不得含该扩展、
# 镜像里不得有该扩展文件”断言，与用户 2026-10-24 要求恢复该扩展
# 直接冲突（前面刚断言必须启用，后面又断言不得出现，构建必红）。
# 之前修法只改了注释、漏了这两处断言。现整段删除，不再断言。
# 注意：light-style 已于 2026-10-19 从构建移除（#61/#62 构建失败根因）——
# GNOME 官方 43.1 仓库里没有该扩展，且它依赖 GNOME 45+ 的 API，在 GNOME 43
# 上从原理上跑不起来；浅色效果由 dconf color-scheme='prefer-light' 实现，
# 故此处不再断言 light-style（断言了反而构建失败）。
# 用户 2026-10-23 指令：性能监视工具换成 Debian 官方 gnome-system-monitor
# 应用（package list 显式声明），顶栏扩展版已移除。
require_path 'usr/bin/gnome-system-monitor'
# libadwaita/GTK4 应用主题（1550 钩子装进 /etc/skel/.config/gtk-4.0/，
# 上游 install.sh -l 的等效做法；没有它 Nautilus 等只会显示原生 Adwaita）。
SKEL_GTK4="$WORK/skel-gtk4.css"
cat_image_file 'etc/skel/.config/gtk-4.0/gtk.css' "$SKEL_GTK4"
[ -s "$SKEL_GTK4" ] || {
    echo 'WhiteSur-Light gtk-4.0 theme missing from /etc/skel (libadwaita apps would stay Adwaita)' >&2
    exit 1
}
# mac 主题回归：user-theme 扩展必须启用（顶栏 WhiteSur shell 主题），不可精简。
grep -q 'user-theme@gnome-shell-extensions.gcampax.github.com' "$GNOME_DEFAULTS"
grep -q "^\[org/gnome/shell/extensions/user-theme\]$" "$GNOME_DEFAULTS"
grep -q "^name='WhiteSur-Light'$" "$GNOME_DEFAULTS"
# 用户 2026-10-17 邮件指令：窗口按钮放右上角。
grep -q "^button-layout=':minimize,maximize,close'$" "$GNOME_DEFAULTS"
# 光标主题三处必须一致（用户 2026-10-23「Mac 主题没完全用上」：
# 之前只断言了文件存在，从不断言 dconf 与 X11 默认，登录页/根窗口的
# 指针一直是 Adwaita）。
# ① 桌面会话 dconf。
grep -q "^cursor-theme='WhiteSur-cursors'$" "$GNOME_DEFAULTS" \
    || { echo 'dconf cursor-theme is not WhiteSur-cursors' >&2; exit 1; }
# ② X11 系统默认光标（1550 钩子注册）：根窗口/GDM/会话启动瞬间的指针。
CURSOR_DEFAULT_FILE="$FULL_ROOT/usr/share/icons/default/index.theme"
[ -f "$CURSOR_DEFAULT_FILE" ] \
    || { echo 'X11 default cursor index.theme is missing' >&2; exit 1; }
grep -q 'WhiteSur-cursors' "$CURSOR_DEFAULT_FILE" \
    || { echo 'X11 default cursor is not WhiteSur-cursors (root window / GDM would stay Adwaita)' >&2; exit 1; }
# ③ dconf 里不得再有指向已删除 AI 组件的死快捷键（/usr/local/bin/xwlightos-ai-chat
# 已不存在，校验脚本 elsewhere 断言它必须不存在）。
grep -q 'xwlightos-ai-chat' "$GNOME_DEFAULTS" && {
    echo 'dconf still references the removed xwlightos-ai-chat binary (dead keybinding)' >&2
    exit 1
} || true
# WhiteSur GDM 登录主题版本标记（1560 钩子写入）。
GDM_THEME_MARKER="$WORK/whitesur-gdm-theme"
cat_image_file 'etc/xwlightos/whitesur-gdm-theme' "$GDM_THEME_MARKER"
grep -q '^whitesur-gdm-theme 2026-09-10' "$GDM_THEME_MARKER"
# XWLightOS ships no AI components: no AI dock entries required.
LIVE_INIT="$WORK/xwlightos-live-session-init"
cat_image_file 'usr/local/sbin/xwlightos-live-session-init' "$LIVE_INIT"
! grep -qE 'chpasswd|lightdm|nopasswdlogin' "$LIVE_INIT"
FCITX5_CONFIG="$WORK/fcitx5-config"
cat_image_file 'etc/skel/.config/fcitx5/config' "$FCITX5_CONFIG"
grep -q '^\[Hotkey/AltTriggerKeys\]$' "$FCITX5_CONFIG"
grep -q '^0=Shift_L$' "$FCITX5_CONFIG"
FCITX5_PROFILE="$WORK/fcitx5-profile"
cat_image_file 'etc/skel/.config/fcitx5/profile' "$FCITX5_PROFILE"
grep -q '^Name=pinyin$' "$FCITX5_PROFILE"
POWER_BRIDGE="$WORK/xwlightos-power-action"
cat_image_file 'usr/local/bin/xwlightos-power-action' "$POWER_BRIDGE"
grep -q '^exec pkexec /usr/local/libexec/xwlightos-privileged-action "\$action"$' "$POWER_BRIDGE"
LOGOUT_HELPER="$WORK/xwlightos-logout"
cat_image_file 'usr/local/bin/xwlightos-logout' "$LOGOUT_HELPER"
grep -q 'gnome-session-quit --logout' "$LOGOUT_HELPER"
PRIVILEGED_ACTION="$WORK/xwlightos-privileged-action"
cat_image_file 'usr/local/libexec/xwlightos-privileged-action' "$PRIVILEGED_ACTION"
grep -q -- '--restore' "$PRIVILEGED_ACTION"
grep -q -- '--no-reboot' "$PRIVILEGED_ACTION"
! grep -q '\$@' "$PRIVILEGED_ACTION"
grep -q 'systemctl --no-wall poweroff' "$PRIVILEGED_ACTION"
grep -q 'systemctl --no-wall reboot' "$PRIVILEGED_ACTION"
TARGET_POSTINSTALL="$WORK/xwlightos-target-postinstall"
cat_image_file 'usr/local/libexec/xwlightos-target-postinstall.sh' "$TARGET_POSTINSTALL"
grep -q '/usr/local/libexec/xwlightos-installed-cleanup' "$TARGET_POSTINSTALL"
grep -q 'systemctl enable xwlightos-installed-cleanup.service' "$TARGET_POSTINSTALL"
# Build 34（用户 2026-10-25：管家后端自启“又掉了”）：1660 钩子的启用
# 只是 live 层，postinstall 必须在装完系统里再启用一次，否则安装路径
# 一丢 wants 软链接、构建仍绿灯。以下三处缺一不可：厂商重启用、
# 管家 unit 本体、目标里 /etc/environment（厂商 unit 无 '-' 前缀的
# EnvironmentFile，缺文件即硬失败）。
grep -q 'installed target: vendor service enabled' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not re-enable vendor services in the installed target (live-only 1660 enable is a single layer)' >&2; exit 1; }
grep -q 'com.seewo.terminalmanager.service' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall never mentions the terminalmanager unit (installed target has no second enable layer)' >&2; exit 1; }
grep -q '/etc/environment' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not ensure /etc/environment in the installed target (vendor manager unit hard-fails without it)' >&2; exit 1; }
# Openssh default-off, installed layer (user 2026-10-25): the live-only
# 1710 hook cannot prove anything about the installed system, because
# Calamares unpackfs copies the live root including any enable symlink.
# The postinstall must therefore disable sshd in the target itself, with
# the same explicit wants-link removal as the live hook.
grep -q 'systemctl disable ssh.service sshd.service' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not disable ssh/sshd in the installed target (openssh error would survive installation)' >&2; exit 1; }
grep -q 'multi-user.target.wants/ssh.service' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not remove the ssh enable symlink in the installed target' >&2; exit 1; }
INSTALLED_CLEANUP="$WORK/xwlightos-installed-cleanup"
cat_image_file 'usr/local/libexec/xwlightos-installed-cleanup' "$INSTALLED_CLEANUP"
! grep -qE 'read[[:space:]]+-r[[:space:]]+-d' "$INSTALLED_CLEANUP"
! grep -qE '/usr/(local/)?share/applications/\{' "$INSTALLED_CLEANUP"
grep -q 'for home_dir in /home/\* /root /etc/skel; do' "$INSTALLED_CLEANUP"
grep -q 'clean_desktop_dir "\$home_dir/Desktop"' "$INSTALLED_CLEANUP"
grep -q "'/etc/skel/Desktop/Install XWLightOS.desktop'" "$INSTALLED_CLEANUP"
# 用户 2026-10-23 邮件第 10 项：安装完成后 Calamares 及相关包必须卸载、
# 提权配置必须清掉，不在已安装系统里残留。
grep -q 'apt-get purge -y calamares calamares-settings-debian' "$INSTALLED_CLEANUP" || {
    echo 'installed cleanup does not purge the Calamares packages' >&2
    exit 1
}
grep -q 'apt-get autoremove --purge -y' "$INSTALLED_CLEANUP" || {
    echo 'installed cleanup does not autoremove Calamares dependencies' >&2
    exit 1
}
grep -q '/etc/sudoers.d/xwlightos-installer' "$INSTALLED_CLEANUP" || {
    echo 'installed cleanup does not remove the installer sudoers entry' >&2
    exit 1
}
# Regression test for the Build 28 install failure: clean_desktop_dir used
# to return 1 on an existing but empty Desktop dir, and set -e then killed
# the cleanup helper (and postinstall) silently with exit 1 and no output.
# The trigger is deterministic: the helper first deletes the skel Desktop
# installer entry, leaving that directory empty for the later sweep.
# This test extracts only the function and runs it against scratch dirs;
# the full helper is never executed here because it touches absolute paths.
CLEANUP_FUNC_FILE="$WORK/clean_desktop_dir.func"
sed -n '/^clean_desktop_dir() {/,/^}/p' "$INSTALLED_CLEANUP" > "$CLEANUP_FUNC_FILE"
[ -s "$CLEANUP_FUNC_FILE" ] || {
    echo 'installed cleanup clean_desktop_dir function not found' >&2
    exit 1
}
CLEANUP_TEST_ROOT="$WORK/cleanup-test"
rm -rf "$CLEANUP_TEST_ROOT"
mkdir -p "$CLEANUP_TEST_ROOT/empty/Desktop" "$CLEANUP_TEST_ROOT/full/Desktop"
printf '[Desktop Entry]\nName=Test\n' > "$CLEANUP_TEST_ROOT/full/Desktop/test.desktop"
if ! sh -eu -c '. "$1"; clean_desktop_dir "$2"; clean_desktop_dir "$3"; echo SURVIVED' sh "$CLEANUP_FUNC_FILE" "$CLEANUP_TEST_ROOT/empty/Desktop" "$CLEANUP_TEST_ROOT/full/Desktop" | grep -q SURVIVED; then
    echo 'installed cleanup clean_desktop_dir fails on an empty Desktop dir' >&2
    exit 1
fi
[ -f "$CLEANUP_TEST_ROOT/full/Desktop/test.desktop" ] && {
    echo 'installed cleanup did not remove a Desktop shortcut' >&2
    exit 1
}
rm -rf "$CLEANUP_TEST_ROOT" "$CLEANUP_FUNC_FILE"
CLEANUP_SERVICE="$WORK/xwlightos-installed-cleanup.service"
cat_image_file 'etc/systemd/system/xwlightos-installed-cleanup.service' "$CLEANUP_SERVICE"
grep -q '^Before=gdm.service$' "$CLEANUP_SERVICE"
grep -q '^ExecStart=/usr/local/libexec/xwlightos-installed-cleanup$' "$CLEANUP_SERVICE"
POLKIT_POLICY="$WORK/xwlightos-privileged-action.policy"
cat_image_file 'usr/share/polkit-1/actions/im.system-intel-mic.xwlightos.privileged-action.policy' "$POLKIT_POLICY"
grep -q 'id="im.system-intel-mic.xwlightos.privileged-action"' "$POLKIT_POLICY"
grep -q '<allow_active>auth_self</allow_active>' "$POLKIT_POLICY"
LIVE_POLKIT_RULE="$WORK/49-xwlightos-calamares.rules"
cat_image_file 'etc/polkit-1/rules.d/49-xwlightos-calamares.rules' "$LIVE_POLKIT_RULE"
grep -q 'im.system-intel-mic.xwlightos.privileged-action' "$LIVE_POLKIT_RULE"
grep -q 'subject.isInGroup("sudo")' "$LIVE_POLKIT_RULE"
grep -q 'polkit.Result.YES' "$LIVE_POLKIT_RULE"
! grep -q 'org.freedesktop.policykit.exec' "$LIVE_POLKIT_RULE"

# Verify the installed, hook-mutated Calamares settings rather than source
# templates. A missing sequence entry recreates the historical module-load
# failure, so both the instance and the sequence reference are mandatory.
SETTINGS="$WORK/settings.conf"
cat_image_file 'etc/calamares/settings.conf' "$SETTINGS"
grep -q -E '^[[:space:]]*branding:[[:space:]]*xwlightos[[:space:]]*$' "$SETTINGS"
grep -q -E '^[[:space:]]*-[[:space:]]*id:[[:space:]]*xwlightos-postinstall[[:space:]]*$' "$SETTINGS"
grep -q -E '^[[:space:]]*module:[[:space:]]*shellprocess[[:space:]]*$' "$SETTINGS"
grep -q -E '^[[:space:]]*config:[[:space:]]*xwlightos-postinstall\.conf[[:space:]]*$' "$SETTINGS"
grep -q -E '^[[:space:]]*-[[:space:]]*shellprocess@xwlightos-postinstall[[:space:]]*$' "$SETTINGS"

# Live privilege policy (user instruction 2026-10-23): the disposable live
# user escalates to root without a password, like any conventional live CD.
# The rule must be mode 0440 (sudo silently ignores anything else), must be
# syntactically valid, and must never leak into an installed system (the
# Calamares postinstall removes it; assertions below).
SUDOERS="$WORK/xwlightos-live.sudoers"
cat_image_file 'etc/sudoers.d/xwlightos-live' "$SUDOERS"
grep -q -E '^user ALL=\(ALL\) NOPASSWD: ALL$' "$SUDOERS"
[ "$(stat -c '%a' "$FULL_ROOT/etc/sudoers.d/xwlightos-live")" = 440 ] || {
    echo 'live sudoers file is not mode 0440; sudo would ignore it' >&2
    exit 1
}
if grep -qx 'etc/sudoers.d/xwlightos-installer' "$LIST"; then
    echo 'superseded narrow live sudoers rule still present' >&2
    exit 1
fi
# The live user must actually resolve to the sudo group in the image.
LIVE_GROUP="$WORK/live-group"
cat_image_file 'etc/group' "$LIVE_GROUP"
grep -q -E '^sudo:[^:]*:[^:]*:([^:,]*,)*user(,|$)' "$LIVE_GROUP" || {
    echo 'live user is not in the sudo group' >&2
    exit 1
}
# Installed path: the postinstall must drop the live sudoers files, grant
# sudo-group membership to the Calamares-created account (and fail loudly
# rather than ship a sudo-less system), and arm the first-boot repair net.
grep -q 'rm -f /etc/sudoers.d/xwlightos-live /etc/sudoers.d/xwlightos-installer' "$TARGET_POSTINSTALL"
grep -q 'systemctl enable xwlightos-sudo-repair.service' "$TARGET_POSTINSTALL"
grep -q 'refusing to ship a sudo-less system' "$TARGET_POSTINSTALL"
require_path 'usr/local/libexec/xwlightos-sudo-repair'
require_path 'etc/systemd/system/xwlightos-sudo-repair.service'
# The installed-only repair unit must not be enabled in the live image.
if grep -qx 'etc/systemd/system/multi-user.target.wants/xwlightos-sudo-repair.service' "$LIST"; then
    echo 'installed-only sudo repair unit is enabled in the live image' >&2
    exit 1
fi

DESKTOP="$WORK/xwlightos-installer.desktop"
cat_image_file 'usr/share/applications/xwlightos-installer.desktop' "$DESKTOP"
grep -q -E '^Exec=(/usr/local/bin/)?xwlightos-installer([[:space:]]|$)' "$DESKTOP"
if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$DESKTOP"
fi

# The final image must ship GNOME as its only desktop session.  GDM autologs
# into the GNOME X11 session, so the GNOME session entry must exist and no
# non-GNOME X11/Wayland session entry may be installed at all.  A resurrected
# legacy desktop session would fail here even though the keyword scan is gone.
require_path 'usr/share/xsessions/gnome-xorg.desktop'
SESSION_ENTRIES="$WORK/session-entries.list"
grep -E '(^|/)usr/share/(xsessions|wayland-sessions)/[^/]+\.desktop$' "$LIST" \
    > "$SESSION_ENTRIES" || true
NON_GNOME_SESSIONS="$WORK/non-gnome-sessions.list"
# GNOME ships several official session variants alongside the main X11
# entry (e.g. gnome-wayland.desktop, gnome-classic.desktop,
# gnome-classic-xorg.desktop, gnome-classic-wayland.desktop); all of them
# are GNOME's own and must not be treated as legacy contamination.
grep -vE '(^|/)gnome(-classic)?(-xorg|-wayland)?\.desktop$' "$SESSION_ENTRIES" \
    > "$NON_GNOME_SESSIONS" || true
if [ -s "$NON_GNOME_SESSIONS" ]; then
    echo 'final ISO installs a non-GNOME desktop session:' >&2
    cat "$NON_GNOME_SESSIONS" >&2
    exit 1
fi
# The removed self-developed components must not reappear either.
# PeaZip joins them (user 2026-10-25: no Chinese UI, replaced by File
# Roller): if any step reinstalls it, the final ISO must fail here.
for path in \
    usr/local/libexec/xwlightos-component-launch \
    usr/bin/xwlightos-store \
    usr/bin/xwlightos-widgets \
    usr/bin/winver \
    usr/bin/xwlightos-ipconfig \
    usr/local/bin/linux-regedit \
    usr/local/bin/devmgr \
    usr/bin/peazip \
    usr/share/applications/peazip.desktop; do
    if grep -q -E "(^|/)${path//./\\.}$" "$LIST"; then
        echo "final ISO still contains a removed component: /$path" >&2
        exit 1
    fi
done

# File Roller is the archive manager behind the default application
# associations (user 2026-10-25: PeaZip removed, no Chinese UI).
require_path 'usr/bin/file-roller'
require_path 'usr/share/applications/org.gnome.FileRoller.desktop'
# GNOME Text Editor is the default handler for plain text.
require_path 'usr/bin/gnome-text-editor'
require_path 'usr/share/applications/org.gnome.TextEditor.desktop'
# System-wide default application associations (GNOME "默认应用程序").
MIMEAPPS="$WORK/mimeapps.list"
cat_image_file 'etc/xdg/mimeapps.list' "$MIMEAPPS"
grep -q '^text/plain=org.gnome.TextEditor.desktop$' "$MIMEAPPS"
grep -q '^image/jpeg=org.gnome.eog.desktop$' "$MIMEAPPS"
grep -q '^video/mp4=vlc.desktop$' "$MIMEAPPS"
grep -q '^application/zip=org.gnome.FileRoller.desktop$' "$MIMEAPPS"
# ONLYOFFICE is the default handler for office documents and PDF.
grep -q '^application/pdf=onlyoffice-desktopeditors.desktop$' "$MIMEAPPS"
for oo_mime in \
    application/msword \
    application/vnd.openxmlformats-officedocument.wordprocessingml.document \
    application/vnd.ms-excel \
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet \
    application/vnd.ms-powerpoint \
    application/vnd.openxmlformats-officedocument.presentationml.presentation; do
    grep -q "^${oo_mime}=onlyoffice-desktopeditors.desktop$" "$MIMEAPPS" || {
        echo "ONLYOFFICE is not the default handler for $oo_mime in final ISO" >&2
        exit 1
    }
done
# ONLYOFFICE must really be inside the ISO: binary, desktop entry, desktop
# shortcut, and the multi-window seed in the skeleton config.
require_path 'usr/bin/onlyoffice-desktopeditors'
require_path 'usr/share/applications/onlyoffice-desktopeditors.desktop'
# 用户 2026-10-24 指令：桌面保持干净，skel Desktop 不得预置 ONLYOFFICE/
# 终端等应用快捷方式（清理服务与安装后 cleanup 做运行时兜底）。
if grep -qx 'etc/skel/Desktop/ONLYOFFICE.desktop' "$LIST"; then
    echo 'skel Desktop still seeds an ONLYOFFICE shortcut (desktop must stay clean)' >&2; exit 1
fi
if grep -qx 'etc/skel/Desktop/终端.desktop' "$LIST"; then
    echo 'skel Desktop still seeds a terminal shortcut (desktop must stay clean)' >&2; exit 1
fi
OO_CONF="$WORK/DesktopEditors.conf"
cat_image_file 'etc/skel/.config/onlyoffice/DesktopEditors.conf' "$OO_CONF"
# 9.4.0 semantics (verified in the shipped index.html settings JS):
# editorwindowmode=true -> "In its own window"; false forces tab mode.
grep -q -E '^editorWindowMode *= *true$' "$OO_CONF" || {
    echo 'ONLYOFFICE multi-window mode is not seeded in final ISO' >&2
    exit 1
}
# Hardware compatibility layer and dev toolchain must be present.
require_path 'usr/sbin/cupsd'
require_path 'usr/bin/gcc'
require_path 'usr/bin/git'
require_path 'usr/bin/ffmpeg'
# Fcitx5 must autostart in the GNOME session and be wired as the input
# method framework via Xsession.d (GNOME X11 session sources it).
FCITX5_AUTOSTART="$WORK/fcitx5.desktop"
cat_image_file 'etc/xdg/autostart/fcitx5.desktop' "$FCITX5_AUTOSTART"
grep -q '^OnlyShowIn=GNOME;$' "$FCITX5_AUTOSTART"
IM_ENV="$WORK/90fcitx5-xwlightos"
cat_image_file 'etc/X11/Xsession.d/90fcitx5-xwlightos' "$IM_ENV"
# fcitx5 上游文档（fcitx-im.org/wiki/Setup_Fcitx_5）规定的值是 =fcitx
#（不是 =fcitx5）：GTK/QT 输入法模块名沿用 fcitx。
grep -q '^export GTK_IM_MODULE=fcitx$' "$IM_ENV"
grep -q '^export QT_IM_MODULE=fcitx$' "$IM_ENV"
grep -q '^export XMODIFIERS=@im=fcitx$' "$IM_ENV"
# 用户 2026-10-24 22:53 输入法修法：只写 Xsession.d/profile.d 不够，
# GDM 默认路径的 GNOME 会话读不到它们；/etc/environment 经 pam_env
# 对所有显示管理器登录生效（X11 与 Wayland 均可），必须同步写死。
SYS_ENV="$WORK/sys-environment"
cat_image_file 'etc/environment' "$SYS_ENV"
grep -q '^GTK_IM_MODULE=fcitx$' "$SYS_ENV"
grep -q '^QT_IM_MODULE=fcitx$' "$SYS_ENV"
grep -q '^XMODIFIERS=@im=fcitx$' "$SYS_ENV"
grep -q '^QT_QPA_PLATFORMTHEME=gtk2$' "$SYS_ENV" || {
    echo 'system environment lacks Qt platform theme (Qt apps would drift off WhiteSur-Light)' >&2; exit 1; }
# Shift 切换的结构性门禁：skel 配置必须同时有左右 Shift 触发键，
# 且 profile 必须同时含 keyboard（英文端）与 pinyin（中文端），
# 缺任一端 AltTrigger 切换就没有两个落点。
FCITX_CFG="$WORK/fcitx5-config"
cat_image_file 'etc/skel/.config/fcitx5/config' "$FCITX_CFG"
grep -q '^0=Shift_L$' "$FCITX_CFG"
grep -q '^1=Shift_R$' "$FCITX_CFG"
# 小节级门禁：此前只在全文件 grep，Shift_L 出现在别处也能蒙混；
# 触发键必须实打实落在 [Hotkey/AltTriggerKeys] 小节内才算数。
FCITX_ALT_SECTION="$WORK/fcitx5-alttrigger"
awk '/^\[Hotkey\/AltTriggerKeys\]/{in_section=1; next} /^\[/{in_section=0} in_section' "$FCITX_CFG" > "$FCITX_ALT_SECTION"
grep -q '^0=Shift_L$' "$FCITX_ALT_SECTION" || {
    echo 'fcitx5 Shift_L is not inside [Hotkey/AltTriggerKeys] (Shift trigger would not fire)' >&2; exit 1; }
grep -q '^1=Shift_R$' "$FCITX_ALT_SECTION" || {
    echo 'fcitx5 Shift_R is not inside [Hotkey/AltTriggerKeys] (Shift trigger would not fire)' >&2; exit 1; }
# 用户 2026-10-25 邮件第 1 项：屏幕键盘默认开启（此前仓库从未写过
# 该键，GNOME 默认 false），且 GTK 输入法模块经 xsettings 通道钉死
# 为 fcitx（屏幕键盘落点的 GTK 文本框须经此通道才走 fcitx）。
OSK_DCONF="$WORK/00-xwlightos-gnome-osk"
cat_image_file 'etc/dconf/db/local.d/00-xwlightos-gnome' "$OSK_DCONF"
grep -q '^screen-keyboard-enabled=true$' "$OSK_DCONF" || {
    echo 'dconf does not enable the on-screen keyboard by default (user mail 2026-10-25 item 1)' >&2; exit 1; }
grep -q "^overrides={'Gtk/IMModule':<'fcitx'>}$" "$OSK_DCONF" || {
    echo 'dconf xsettings does not pin Gtk/IMModule to fcitx (GTK apps could bypass fcitx)' >&2; exit 1; }
FCITX_PROFILE="$WORK/fcitx5-profile"
cat_image_file 'etc/skel/.config/fcitx5/profile' "$FCITX_PROFILE"
grep -q '^Name=keyboard-us$' "$FCITX_PROFILE"
grep -q '^Name=pinyin$' "$FCITX_PROFILE"
# 写错值的 90xwlightos-fcitx5-im（=fcitx5）必须不存在，否则会覆盖正确值
# （用户 2026-10-18 真机反馈中文无法输入）。
if grep -q -E '(^|/)etc/X11/Xsession\.d/90xwlightos-fcitx5-im$' "$LIST"; then
    echo "wrong input-method env file still in final ISO: /etc/X11/Xsession.d/90xwlightos-fcitx5-im (its =fcitx5 values are invalid per upstream docs)" >&2
    exit 1
fi

# XWLightOS ships no AI components: the runtime binaries, gateway units and
# desktop entries below must NOT be present in the image.
for path in \
    usr/bin/openclaw \
    usr/bin/omniroute \
    usr/local/bin/xwlightos-firstboot \
    usr/local/bin/xwlightos-ai-chat \
    usr/local/bin/xwlightos-ai-manager \
    lib/systemd/system/xwlightos-omniroute.service \
    lib/systemd/system/xwlightos-openclaw.service \
    lib/systemd/system/xwlightos-firstboot.service \
    usr/share/applications/xwlightos-ai-chat.desktop \
    usr/share/applications/xwlightos-ai-manager.desktop \
    usr/share/applications/omniroute-dashboard.desktop; do
    if grep -q -E "(^|/)${path//./\\.}$" "$LIST"; then
        echo "XWLightOS must not ship AI component: /$path" >&2
        exit 1
    fi
done

# Core runtime that must be inside the ISO.
# XWLightOS 已移除 AI 栈：Node.js/npm 不再需要（原为 OpenClaw 运行时）；
# xwlightos-sysmon 也不再需要（原为 AI system-monitor skill 的配套脚本）。
for path in \
    usr/bin/firefox; do
    require_path "$path"
done

# XWLightOS ships no AI components: no Playwright browsers, no OpenClaw
# unit, no ai-home tarball are required.

# All XWLightOS third-party components resolve to curated aliases in
# the WhiteSur icon theme.  Checking the final squashfs catches both package
# staging omissions and upstream icon-generation overwrites.
require_path 'usr/share/icons/WhiteSur'
# XWLightOS ships no ai-home tarball (AI components removed).
require_path 'usr/share/icons/WhiteSur/index.theme'
# 系统实际使用的图标主题是 WhiteSur-light（用户 2026-10-17 邮件指令）。
require_path 'usr/share/icons/WhiteSur-light'
require_path 'usr/share/icons/WhiteSur-light/index.theme'

# File Roller ships its own upstream desktop entry; validate it the same way.
if command -v desktop-file-validate >/dev/null 2>&1; then
    FILEROLLER_DESKTOP="$WORK/org.gnome.FileRoller.desktop"
    cat_image_file 'usr/share/applications/org.gnome.FileRoller.desktop' "$FILEROLLER_DESKTOP"
    desktop-file-validate "$FILEROLLER_DESKTOP"
fi
TERMINAL_ENTRY="$WORK/xterm.desktop"
cat_image_file 'usr/local/share/applications/xterm.desktop' "$TERMINAL_ENTRY"
grep -q 'DejaVu Sans Mono' "$TERMINAL_ENTRY"
grep -q 'XTerm\*background:#000000' "$TERMINAL_ENTRY"
FONTCONF="$WORK/xwlightos-fontconfig.xml"
cat_image_file 'etc/fonts/local.conf' "$FONTCONF"
grep -q '<family>DejaVu Sans Mono</family>' "$FONTCONF"
grep -q '<family>Noto Sans CJK SC</family>' "$FONTCONF"
! grep -q '<test name="lang" compare="contains"><string>zh</string></test>' "$FONTCONF"

# Firefox ESR 默认配置：默认搜索引擎必应（用户 2026-10-19 邮件指令），
# 主页为本地 XWLightOS 主页 html（用户 2026-10-23 邮件指令：换成用户给的
# html，liveCD 与安装好的系统都要改，不再是 bing.com）。通过 Enterprise
# policies.json 落盘，Debian firefox-esr 的标准路径为
# /usr/lib/firefox-esr/distribution/policies.json。
require_path 'usr/share/xwlightos/homepage.html'
# 用户 2026-10-24 指令：主页 html 不做字节数/md5 校验，用户以后可能自己
# 改 html；只要求仓库里的文件原样落盘、不被构建改写（includes.chroot
# 文件即原样拷贝，无任何改写步骤）。
FF_POLICIES="$WORK/firefox-policies.json"
cat_image_file 'usr/lib/firefox-esr/distribution/policies.json' "$FF_POLICIES"
python3 - "$FF_POLICIES" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    pol = json.load(f)["policies"]
assert pol["SearchEngines"]["Default"] == "Bing", "default search engine is not Bing"
assert pol["Homepage"]["URL"] == "file:///usr/share/xwlightos/homepage.html", "homepage is not the local XWLightOS homepage html"
# 用户 2026-10-24 指令：收藏直接放收藏栏、不许套文件夹。Mozilla 官方文档：
# ManagedBookmarks 必然生成文件夹按钮，故改用 Bookmarks 策略 Placement=toolbar。
assert "ManagedBookmarks" not in pol, "ManagedBookmarks would wrap bookmarks in a folder"
bms = pol["Bookmarks"]
assert any(b.get("Title") == "XWLightOS主页" and b.get("URL") == "file:///usr/share/xwlightos/homepage.html" and b.get("Placement") == "toolbar" for b in bms), "XWLightOS homepage toolbar bookmark missing"
assert any(b.get("Title") == "哔哩哔哩" and b.get("URL") == "https://space.bilibili.com/1978487514" and b.get("Placement") == "toolbar" for b in bms), "bilibili toolbar bookmark missing"
# 打开不弹首次使用/升级页、直接进主页；默认中文；收藏栏常显。
assert pol["OverrideFirstRunPage"] == "", "first-run page is not disabled"
assert pol["OverridePostUpdatePage"] == "", "post-update page is not disabled"
assert pol["RequestedLocales"][0] == "zh-CN", "Firefox default locale is not zh-CN"
assert pol["DisplayBookmarksToolbar"] == "always", "bookmarks toolbar is not always shown"
# 用户 2026-10-24 邮件《很大问题》第 5 项：新标签页也要打开用户主页。
# Mozilla 官方文档明言 Homepage 策略不改变新标签页（新标签页设置只有
# “Firefox 主页”和“空白页”两档），因此必须用扩展实现：策略强制安装
# 本地新标签页扩展（新标签页直接显示内嵌的主页副本，见下文 Build 37 根因）。
ext = pol["ExtensionSettings"]["xwlightos-newtab@xwlightos.local"]
assert ext["installation_mode"] == "force_installed", "new-tab extension is not force-installed"
assert ext["install_url"] == "file:///usr/share/xwlightos/firefox-newtab.xpi", "new-tab extension URL is wrong"
# Build 34 根因：Build 33 的 XPI 未签名且策略里没有签名首选项，Firefox ESR
# 默认拒装未签名扩展、新标签页回落默认页。ESR 专用的签名首选项必须由
# 策略锁定为 false，否则上面的 force_installed 在真机上仍是摆设。
pref = pol["Preferences"]["xpinstall.signatures.required"]
assert pref["Value"] is False, "xpinstall.signatures.required is not false (unsigned new-tab extension would be disabled)"
assert pref["Status"] == "locked", "xpinstall.signatures.required is not locked"
print("XWLightOS: Firefox search=Bing, homepage=user html as-is, toolbar bookmarks OK, first-run off, zh-CN, new-tab extension forced")
PYEOF

# 新标签页扩展本体必须落盘且 manifest 可解析（否则策略指向空文件）。
# Build 37 机制变更：扩展页上下文到 file:// 的导航被 Firefox 安全策略拦截
# （moz-extension 页 load/link file: 报错、tabs API 报 Illegal URL），旧
# redirect.html 跳转从原理上不可能生效；新标签页的覆盖页直接就是内嵌的
# 主页副本，XPI 里只应有 manifest.json 与 homepage.html 两项，且内嵌副本
# 必须与落盘的 file:// 主页逐字节一致，否则新标签页与启动主页/收藏栏主页
# 看到的不是同一份主页。
require_path 'usr/share/xwlightos/firefox-newtab.xpi'
FF_XPI="$WORK/firefox-newtab.xpi"
cat_image_file 'usr/share/xwlightos/firefox-newtab.xpi' "$FF_XPI"
FF_HOMEPAGE="$WORK/firefox-homepage.html"
cat_image_file 'usr/share/xwlightos/homepage.html' "$FF_HOMEPAGE"
python3 - "$FF_XPI" "$FF_HOMEPAGE" <<'PYEOF'
import json
import sys
import zipfile
z = zipfile.ZipFile(sys.argv[1])
man = json.loads(z.read("manifest.json"))
assert man["browser_specific_settings"]["gecko"]["id"] == "xwlightos-newtab@xwlightos.local", "new-tab extension id mismatch"
assert man["chrome_url_overrides"]["newtab"] == "homepage.html", "new-tab override page is not the bundled homepage copy"
assert man["version"] == "1.2", "new-tab extension version is not 1.2 (Build 36's redirect-based 1.1 copy would not be force-reinstalled by policy)"
assert set(z.namelist()) == {"manifest.json", "homepage.html"}, "new-tab xpi must contain exactly manifest + bundled homepage (stale redirect page would break the mechanism)"
with open(sys.argv[2], "rb") as f:
    live_homepage = f.read()
assert z.read("homepage.html") == live_homepage, "bundled new-tab homepage copy differs from installed homepage.html (new tab would show a stale homepage)"
print("XWLightOS: new-tab xpi valid")
PYEOF

# 用户 2026-10-24 邮件《很大问题》第 7 项：右键新建文本/PPT/DOC。
# Nautilus 的“新建文档”菜单只列出 ~/Templates（中文环境为 ~/模板）
# 里的模板文件，两边都放，缺一不可；PPT/DOCX 必须是结构有效的
# OOXML 空文件，不能放损坏文件。
# 用户 2026-10-24 22:53 邮件：不只 txt/pptx/docx，xls 之类的常见类型
# 都要加——补齐 xlsx/xls/ods、doc/odt、ppt/odp，同样逐个校验
# （OOXML/ODF 走 zip 完整性 + XML 解析，旧二进制格式验 OLE 魔数）。
require_path 'etc/skel/Templates/新建文本文件.txt'
require_path 'etc/skel/Templates/新建演示文稿.pptx'
require_path 'etc/skel/Templates/新建文档.docx'
require_path 'etc/skel/Templates/新建工作表.xlsx'
require_path 'etc/skel/Templates/新建工作表.xls'
require_path 'etc/skel/Templates/新建工作表.ods'
require_path 'etc/skel/Templates/新建文档.doc'
require_path 'etc/skel/Templates/新建文本文档.odt'
require_path 'etc/skel/Templates/新建演示文稿.ppt'
require_path 'etc/skel/Templates/新建演示文稿.odp'
require_path 'etc/skel/模板/新建文本文件.txt'
require_path 'etc/skel/模板/新建演示文稿.pptx'
require_path 'etc/skel/模板/新建文档.docx'
require_path 'etc/skel/模板/新建工作表.xlsx'
require_path 'etc/skel/模板/新建工作表.xls'
require_path 'etc/skel/模板/新建工作表.ods'
require_path 'etc/skel/模板/新建文档.doc'
require_path 'etc/skel/模板/新建文本文档.odt'
require_path 'etc/skel/模板/新建演示文稿.ppt'
require_path 'etc/skel/模板/新建演示文稿.odp'
for _tpl in 'etc/skel/Templates/新建演示文稿.pptx' 'etc/skel/Templates/新建文档.docx' 'etc/skel/Templates/新建工作表.xlsx' 'etc/skel/Templates/新建工作表.ods' 'etc/skel/Templates/新建文本文档.odt' 'etc/skel/Templates/新建演示文稿.odp'; do
    _tmp="$WORK/$(basename "$_tpl")"
    cat_image_file "$_tpl" "$_tmp"
    python3 - "$_tmp" <<'PYEOF'
import sys
import zipfile
from xml.etree import ElementTree as ET
z = zipfile.ZipFile(sys.argv[1])
assert z.testzip() is None, "template zip corrupt"
for name in z.namelist():
    if name.endswith(".xml") or name.endswith(".rels"):
        ET.fromstring(z.read(name))
print("XWLightOS: template valid:", sys.argv[1])
PYEOF
done
for _tpl in 'etc/skel/Templates/新建工作表.xls' 'etc/skel/Templates/新建文档.doc' 'etc/skel/Templates/新建演示文稿.ppt'; do
    _tmp="$WORK/$(basename "$_tpl")"
    cat_image_file "$_tpl" "$_tmp"
    python3 - "$_tmp" <<'PYEOF'
import sys
with open(sys.argv[1], "rb") as f:
    magic = f.read(8)
assert magic == bytes.fromhex("D0CF11E0A1B11AE1"), "template OLE magic wrong"
print("XWLightOS: template OLE valid:", sys.argv[1])
PYEOF
done

# All Apps must not surface session/power helpers as regular applications.  This
# validates the fully installed filesystem rather than trusting the source hook.
for desktop_file in "$FULL_ROOT"/usr/share/applications/*.desktop "$FULL_ROOT"/usr/local/share/applications/*.desktop; do
    [ -f "$desktop_file" ] || continue
    if grep -Eqi \
        '^(Name|Name\[zh_CN\]|GenericName|Comment)=.*(Shutdown|Shut Down|Power Off|Restart|Reboot|Log ?Out|Logoff|Logout|Suspend|Sleep|Hibernate|Lock Screen|Lock Session|关机|重启|重新启动|注销|登出|睡眠|挂起|休眠|锁屏|锁定)' \
        "$desktop_file" || \
       grep -Eqi \
        '^Exec=.*(systemctl[[:space:]]+(poweroff|reboot|suspend|hibernate)|loginctl[[:space:]]+(poweroff|reboot|suspend|hibernate|terminate-session|lock-session)|lxqt-leave|xfce4-session-logout|mate-session-save|openbox[[:space:]]+--exit|gnome-session-quit|(^|[[:space:]])(poweroff|reboot|shutdown|logout|logoff|xscreensaver-command|dm-tool)[[:space:]])' \
        "$desktop_file"; then
        echo "final ISO still exposes a forbidden system-command desktop entry: ${desktop_file#$FULL_ROOT/}" >&2
        exit 1
    fi
done


# ===== Build 26 真机反馈断言（用户 2026-10-24，Build 25 测后 10+1 项）=====
# 1/2 安装器图标：纯 Logo（方形 viewBox、无文字）、Calamares 引用 logo 文件、
# installer 图标主题文件真实存在（旧 Icon=xwlightos-installer 无文件可解析）。
LOGO_FILE="$WORK/xwlightos-logo.svg"
cat_image_file 'usr/share/xwlightos/branding/xwlightos-logo.svg' "$LOGO_FILE"
grep -q 'viewBox="0 0 120 120"' "$LOGO_FILE" || {
    echo 'pure logo SVG is not the square 120x120 canvas' >&2; exit 1; }
grep -q '<text' "$LOGO_FILE" && {
    echo 'pure logo SVG still contains text elements' >&2; exit 1; } || true
require_path 'usr/share/icons/hicolor/scalable/apps/xwlightos-installer.svg'
BRANDING_DESC="$WORK/branding.desc"
cat_image_file 'etc/calamares/branding/xwlightos/branding.desc' "$BRANDING_DESC"
grep -q 'productIcon: "xwlightos-logo.svg"' "$BRANDING_DESC" || {
    echo 'Calamares productIcon is not the pure logo' >&2; exit 1; }
grep -q 'welcomeExpandingLogo: false' "$BRANDING_DESC" || {
    echo 'Calamares welcomeExpandingLogo is not false (logo would stretch)' >&2; exit 1; }
# 3 开机动画：Plymouth 脚本必须用 GetWidth/GetHeight 取屏幕尺寸
#（旧版误用 GetX/GetY=原点坐标，内容被定位到屏幕外）；已装系统与 live 的
# 内核命令行都必须带 quiet splash，否则全程滚屏、无动画。
PLY_SCRIPT="$WORK/xwlightos.plymouth.script"
cat_image_file 'usr/share/plymouth/themes/xwlightos/xwlightos.script' "$PLY_SCRIPT"
grep -q 'Window.GetWidth ()' "$PLY_SCRIPT" || {
    echo 'plymouth script does not use Window.GetWidth (animation positioned off-screen)' >&2; exit 1; }
grep -q 'Window.GetX ()' "$PLY_SCRIPT" && {
    echo 'plymouth script still misuses Window.GetX as screen width' >&2; exit 1; } || true
GRUBD_FILE="$WORK/00-xwlightos-grubd.cfg"
cat_image_file 'etc/default/grub.d/00-xwlightos.cfg' "$GRUBD_FILE"
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash plymouth.ignore-serial-consoles"$' "$GRUBD_FILE" || {
    echo 'grub.d lacks quiet splash + plymouth.ignore-serial-consoles (installed boot would scroll text, no splash)' >&2; exit 1; }
grep -q 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash plymouth.ignore-serial-consoles"' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall grub.d lacks quiet splash + plymouth.ignore-serial-consoles' >&2; exit 1; }
# Build 37（开机动画安装后缺口）：postinstall 的 GRUB drop-in 不得再与主题
# 耦合（主题缺失时删文件会连带丢掉 splash 标志），且 update-grub 不得再
# `|| true` 吞掉失败（装完系统的 grub.cfg 是事后断言的唯一实证）。
! grep -q 'rm -f /etc/default/grub.d/00-xwlightos.cfg' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall still deletes the grub drop-in when theme assets are missing (splash flags would be lost with it)' >&2; exit 1; }
! grep -q 'update-grub || true' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall still swallows update-grub failure (broken installed grub.cfg would hide behind a green install)' >&2; exit 1; }
grep -q 'target update-grub failed' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not fail loudly on update-grub failure' >&2; exit 1; }
grep -q 'generated target grub.cfg lacks the splash kernel flags' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not verify the generated grub.cfg carries the splash flags' >&2; exit 1; }
# Build 37（管家后端安装后缺口）：postinstall 的厂商重启用必须与 1660 live
# 层同款直连 multi-user wants，不走服从 unit 自身 WantedBy 的 systemctl
# enable（WantedBy 不是 multi-user 时终检会误判），也不依赖 chroot 内
# systemctl 是否可用。
grep -q 'ln -sfn "$_vunit" "/etc/systemd/system/multi-user.target.wants/$_vname"' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall vendor re-enable does not link directly into multi-user wants like the 1660 live layer' >&2; exit 1; }
# Deep-chain fix (user mail 2026-10-24 22:40): the installed account
# must be forced onto the X11 session like the live user, otherwise
# every session-level fix validated on live X11 silently stops
# applying on the installed system (Wayland default on bookworm).
grep -q 'XSession=gnome-xorg' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not force X11 session for installed account' >&2; exit 1; }
grep -q 'var/lib/AccountsService/users' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall writes no AccountsService session file' >&2; exit 1; }
# 用户 2026-10-25 邮件第 6 项：postinstall 必须把 skel 的 fcitx5 配置
# （双 Shift 触发键）显式补给安装账号，只靠 Calamares 的 skel 继承
# 一旦漏掉，安装后用户拿到的就是 fcitx5 默认配置、Shift 触发键缺失。
grep -q 'skel/.config/fcitx5' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not seed fcitx5 config for installed account (Shift trigger relies on skel inheritance alone)' >&2; exit 1; }
# 用户 2026-10-25 邮件第 1 项：postinstall 必须把主题文件也补给安装账号，
# 不能只补 fcitx5——此前三处主题文件全靠 Calamares 的 skel 继承，漏掉
# 则安装后用户失去 gtk-3.0 深色关闭、.gtkrc-2.0 与 gtk-4.0 样式。
grep -q 'skel/.config/gtk-3.0/settings.ini' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not seed gtk-3.0 settings.ini for installed account' >&2; exit 1; }
grep -q 'skel/.gtkrc-2.0' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not seed .gtkrc-2.0 for installed account' >&2; exit 1; }
grep -q 'skel/.config/gtk-4.0' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not seed gtk-4.0 theme for installed account' >&2; exit 1; }
# 用户 2026-10-25 08:29 邮件第 8 项：安装账号也要写品牌头像，live 与装完系统
# 的账户图标不能一处改、一处漏。
grep -q 'var/lib/AccountsService/icons' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall writes no AccountsService icon for the installed account' >&2; exit 1; }
grep -q 'usr/share/xwlightos/branding/xwlightos-avatar.png' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not copy the brand avatar for the installed account' >&2; exit 1; }
# 用户 2026-10-25 11:41 邮件第 2 项（关于图标）与第 3 项（dock 回归）的
# 目标端补齐：此前校验只查了 live 镜像的键文件与编译产物，从未查过
# postinstall 里有没有目标端重编——删掉目标端重编、CI 仍全绿，装完
# 系统就回到厂商默认。以下两组缺一不可：
#  (a) dock：postinstall 必须重跑 dconf update 与 glib-compile-schemas
#      并断言两编译产物，否则装完系统仍读厂商 schema 默认（隐藏开）。
#  (b) 关于图标：postinstall 必须把品牌图标拷进当前主题
#      WhiteSur-light 并刷新 hicolor 图标缓存，否则目标端缓存一重建，
#      关于页就回到厂商图标。
grep -q 'dconf update' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not re-run dconf update (installed dock/system defaults would rely on live compilation alone)' >&2; exit 1; }
grep -q 'glib-compile-schemas' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not re-run glib-compile-schemas (installed dash-to-dock schema override would rely on live compilation alone)' >&2; exit 1; }
grep -q 'gtk-update-icon-cache' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not refresh icon caches (installed About brand icon would rely on live cache alone)' >&2; exit 1; }
grep -q 'usr/share/icons/hicolor' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not refresh the hicolor icon cache (About brand icon lookup would miss cache-added brand files)' >&2; exit 1; }
grep -q 'WhiteSur-light' "$TARGET_POSTINSTALL" || {
    echo 'target postinstall does not seed the brand icon into the active WhiteSur-light theme (About lookup would rely on hicolor fallback alone)' >&2; exit 1; }
# 用户 2026-10-25 邮件第 4 项：开机动画仍无。此前校验只查了安装后 GRUB
# 的 grub.d 与 initrd 里的主题，从未查过 live 启动菜单本身：BIOS
#（isolinux）与 UEFI（grub）两套菜单都由同一条 --bootappend-live 生成，
# 若其中混入串口控制台且缺 plymouth.ignore-serial-consoles，live 启动
# 全程滚屏、无动画，而 CI 只看最终桌面帧、从不看 cmdline，必然漏网。
# 两套菜单必须同时存在、同一 live 条目必须同时含 quiet splash 与
# plymouth.ignore-serial-consoles，且不得含 journald 转发到控制台。
# 注意 /boot/grub/grub.cfg 的来源：它不是 live-build 原生生成的（本构建
# 模式下 live-build 不生成该文件，3000 二进制钩子会注明这一点），而是
# repack 脚本把 UEFI 菜单文件写进 ISO 的结果；UEFI 启动经 BOOTX64.EFI
# 内嵌的 stub 链到该文件，故此处取到的就是 UEFI 实际用的菜单，不是摆设。
xorriso -osirrox on -indev "$ISO" \
    -extract /isolinux/live.cfg "$WORK/live.cfg" \
    -extract /boot/grub/grub.cfg "$WORK/grub.cfg" >/dev/null 2>&1 || true
for _menu in "$WORK/live.cfg" "$WORK/grub.cfg"; do
    [ -s "$_menu" ] || {
        echo "final ISO lacks a live boot menu: $_menu (BIOS/UEFI hybrid image must ship both)" >&2; exit 1; }
    _boot_lines="$WORK/$(basename "$_menu").bootlines"
    grep -E '^[[:space:]]*(linux|append)[[:space:]]' "$_menu" > "$_boot_lines" || {
        echo "live boot menu has no kernel boot line: $_menu" >&2; exit 1; }
    grep -q 'forward_to_console=1' "$_boot_lines" && {
        echo "live boot menu re-enables journald forwarding to console, which masks the splash: $_menu" >&2; exit 1; } || true
    _splash_line="$(grep 'quiet' "$_boot_lines" | grep 'splash' | grep 'plymouth.ignore-serial-consoles' | head -n 1 || true)"
    [ -n "$_splash_line" ] || {
        echo "no live boot line carries quiet splash + plymouth.ignore-serial-consoles: $_menu" >&2; exit 1; }
done
# 4 扩展入口与扩展文件门禁（1650 钩子在构建期同口径断言，这里查成品）。
require_path 'usr/share/applications/org.gnome.Extensions.desktop'
require_path 'usr/bin/gnome-extensions'
# 6 桌面清理服务与设置工具必须进镜像。
# 用户 2026-10-25 09:01 指令：希沃侧边栏暂时删除，启动器已随
# 侧边栏删除一并去掉；这里不再要求它存在，改为要求它不存在。
# 用户 2026-10-28 邮件第 4 项：2 秒轮询改事件驱动——启用的是 path
# 单元，服务改为 path 触发的单次运行；设置工具里必须有清理开关。
require_path 'usr/local/bin/xwlightos-desktop-cleaner'
require_path 'etc/systemd/user/xwlightos-desktop-cleaner.path'
require_path 'etc/systemd/user/xwlightos-desktop-cleaner.service'
require_path 'usr/local/bin/xwlightos-settings'
require_path 'usr/share/applications/xwlightos-settings.desktop'
CLEANER_WANTS="$FULL_ROOT/etc/systemd/user/default.target.wants/xwlightos-desktop-cleaner.path"
[ -e "$CLEANER_WANTS" ] || {
    echo 'desktop cleaner path unit is not enabled (dangling/missing wants symlink)' >&2; exit 1; }
CLEANER_PATH="$WORK/xwlightos-desktop-cleaner.path"
cat_image_file 'etc/systemd/user/xwlightos-desktop-cleaner.path' "$CLEANER_PATH"
grep -q '^PathModified=%h/Desktop$' "$CLEANER_PATH" || {
    echo 'desktop cleaner path unit does not watch ~/Desktop' >&2; exit 1; }
grep -q '^Unit=xwlightos-desktop-cleaner.service$' "$CLEANER_PATH" || {
    echo 'desktop cleaner path unit does not trigger the cleaner service' >&2; exit 1; }
CLEANER_SERVICE="$WORK/xwlightos-desktop-cleaner.service"
cat_image_file 'etc/systemd/user/xwlightos-desktop-cleaner.service' "$CLEANER_SERVICE"
grep -q '^Type=oneshot$' "$CLEANER_SERVICE" || {
    echo 'desktop cleaner service is not oneshot (path trigger would start a polling daemon)' >&2; exit 1; }
grep -q -- '--once' "$CLEANER_SERVICE" || {
    echo 'desktop cleaner service does not run a single sweep (--once)' >&2; exit 1; }
CLEANER_SCRIPT="$WORK/xwlightos-desktop-cleaner"
cat_image_file 'usr/local/bin/xwlightos-desktop-cleaner' "$CLEANER_SCRIPT"
grep -q -- '--once' "$CLEANER_SCRIPT" || {
    echo 'desktop cleaner script has no --once mode' >&2; exit 1; }
# 用户 2026-10-28 第二封邮件：清理只影响希沃。厂商文件统一用
# com.seewo. 前缀（白板/管家/视频展台/班级优化大师实包核验），
# 脚本必须含该前缀匹配，缺了就是“删一切 .desktop”的旧行为回潮。
grep -q 'com.seewo\.' "$CLEANER_SCRIPT" || {
    echo 'desktop cleaner script is not scoped to Seewo vendor files (com.seewo. prefix)' >&2; exit 1; }
SETTINGS_TOOL="$WORK/xwlightos-settings"
cat_image_file 'usr/local/bin/xwlightos-settings' "$SETTINGS_TOOL"
grep -q 'xwlightos-desktop-cleaner.path' "$SETTINGS_TOOL" || {
    echo 'settings tool has no desktop cleaner toggle' >&2; exit 1; }
# 7 希沃厂商 unit 清单（1660 钩子生成）必须进镜像且含管家后端。
SEEWO_INV="$WORK/seewo-vendor-units.txt"
cat_image_file 'etc/xwlightos/seewo-vendor-units.txt' "$SEEWO_INV"
grep -qx 'com.seewo.terminalmanager.service' "$SEEWO_INV" || {
    echo 'seewo vendor unit inventory lacks com.seewo.terminalmanager.service (manager backend would not start)' >&2; exit 1; }
# 用户 2026-10-25 09:01 指令：希沃侧边栏与 Udi 组件暂时删除。
# 成品里不得再出现它们，否则就是删除没落地——这里是反向门禁，
# 防止某版厂商清单变动又把删除的组件悄悄带回来。
[ ! -e "$FULL_ROOT/usr/local/bin/xwlightos-sidebar-launcher" ] || {
    echo 'removed sidebar launcher is still present in the image' >&2; exit 1; }
[ ! -e "$FULL_ROOT/usr/share/applications/com.seewo.easisidebar.desktop" ] || {
    echo 'removed sidebar desktop entry is still present in the image' >&2; exit 1; }
grep -qi 'easisidebar\|udi-hotspot' "$SEEWO_INV" && {
    echo 'removed sidebar/Udi unit is still present in the vendor inventory' >&2; exit 1; } || true
# 清单只是清单：管家后端真正开机起得来，还要看 live 镜像里
# multi-user.target.wants 下的启用软链接本身在不在、指没指到
# 真实存在的 unit 文件。只查清单的旧口径会让“有清单、无启用”
# 的镜像一路绿灯（Build 34 前的口径缺口）。
TM_WANTS="$FULL_ROOT/etc/systemd/system/multi-user.target.wants/com.seewo.terminalmanager.service"
[ -L "$TM_WANTS" ] || {
    echo 'terminalmanager service is not enabled in the live image (inventory alone does not start it)' >&2; exit 1; }
TM_TARGET="$(readlink "$TM_WANTS")"
case "$TM_TARGET" in
    /*) [ -e "$FULL_ROOT$TM_TARGET" ] || {
        echo "terminalmanager wants symlink points at a missing unit: $TM_TARGET" >&2; exit 1; } ;;
    *) [ -e "$(dirname "$TM_WANTS")/$TM_TARGET" ] || {
        echo "terminalmanager wants symlink points at a missing unit: $TM_TARGET" >&2; exit 1; } ;;
esac
# 8 桌面/GRUB 壁纸必须是用户 2026-10-24 补发图（1672x941，PNG 落盘）。
WALL_FILE="$WORK/xwlightos-wallpaper.png"
cat_image_file 'usr/share/xwlightos/branding/xwlightos-aurora-wallpaper.png' "$WALL_FILE"
[ "$(md5sum "$WALL_FILE" | cut -d' ' -f1)" = "eb051973b3cce6079660a3e16390e96e" ] || {
    echo 'wallpaper is not the user-supplied 2026-10-24 image' >&2; exit 1; }
# 9 WhiteSur-Light shell CSS 的程序栏对比度覆盖必须在成品里。
SHELL_CSS="$WORK/whitesur-light-gnome-shell.css"
cat_image_file 'usr/share/themes/WhiteSur-Light/gnome-shell/gnome-shell.css' "$SHELL_CSS"
grep -q 'XWLightOS-APPGRID-CONTRAST' "$SHELL_CSS" || {
    echo 'WhiteSur-Light shell css lacks the app-grid contrast override' >&2; exit 1; }
# 10 U 盘自动挂载 + 自动打开（dconf 媒体处理）。
grep -q '^automount=true$' "$GNOME_DEFAULTS" || {
    echo 'GNOME automount is not enabled by default' >&2; exit 1; }
grep -q '^automount-open=true$' "$GNOME_DEFAULTS" || {
    echo 'GNOME automount-open is not enabled by default' >&2; exit 1; }
grep -q '^show-home=false$' "$GNOME_DEFAULTS" || {
    echo 'ding show-home is not disabled (desktop would show system icons)' >&2; exit 1; }

printf 'XWLightOS 1.0 final ISO content validation passed: %s\n' "$ISO"
