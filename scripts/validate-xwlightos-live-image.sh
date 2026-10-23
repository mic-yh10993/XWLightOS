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
# dconf gtk-theme='WhiteSur-Dark' 供 GTK3 老应用：gtk-3.0 必须真实存在。
require_path 'usr/share/themes/WhiteSur-Dark/gtk-3.0'
require_path 'usr/share/themes/WhiteSur-Light'
require_path 'usr/share/themes/WhiteSur-Light/gnome-shell'
require_path 'usr/share/icons/WhiteSur'
require_path 'usr/share/icons/WhiteSur-light'
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
# 自动登录的根因级断言（Build 50，Run 38905790559）：QEMU 截图证明 greeter
# 停在"用户名"输入框——user 账户在 GDM 启动时根本不存在。静态配置全对也
# 救不了运行时建不出用户。从 Build 51 起 user 在构建期就 bake 进镜像，
# GDM 启动时必然可见；此处断言 bake 结果真实存在。
USER_WORK="$WORK/user-check"
rm -rf "$USER_WORK"
unsquashfs -f -d "$USER_WORK" "$FS" \
    etc/passwd etc/shadow etc/group var/lib/AccountsService/users/user \
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
    >/dev/null 2>&1
grep -q '^system-db:gdm$' "$GDM_BRAND_WORK/etc/dconf/profile/gdm" \
    || { echo 'gdm dconf profile lacks system-db:gdm (greeter branding keyfile would be ignored)' >&2; exit 1; }
grep -q "^logo='/usr/share/xwlightos/branding/xwlightos-mark.svg'$" "$GDM_BRAND_WORK/etc/dconf/db/gdm.d/01-xwlightos-branding" \
    || { echo 'GDM greeter logo override is missing (Debian logo would stay on the login screen)' >&2; exit 1; }
[ -s "$GDM_BRAND_WORK/usr/share/xwlightos/branding/xwlightos-mark.svg" ] \
    || { echo 'XWLightOS mark SVG for the GDM greeter logo is missing' >&2; exit 1; }
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
GNOME_DEFAULTS="$WORK/00-xwlightos-gnome"
cat_image_file 'etc/dconf/db/local.d/00-xwlightos-gnome' "$GNOME_DEFAULTS"
grep -q "^gtk-theme='WhiteSur-Dark'$" "$GNOME_DEFAULTS"
# 用户 2026-10-17 邮件指令：图标 WhiteSur-light、Shell WhiteSur-Light。
grep -q "^icon-theme='WhiteSur-light'$" "$GNOME_DEFAULTS"
grep -q 'dash-to-dock@micxgx.gmail.com' "$GNOME_DEFAULTS"
# 用户 2026-10-23 邮件指令：工具栏在时不隐藏 dock，只有全屏窗口才隐藏 dock。
grep -q "^autohide=false$" "$GNOME_DEFAULTS" \
    || { echo 'dash-to-dock autohide is not disabled (dock would stay hidden)' >&2; exit 1; }
grep -q "^intellihide=false$" "$GNOME_DEFAULTS" \
    || { echo 'dash-to-dock intellihide is not disabled' >&2; exit 1; }
grep -q "^autohide-in-fullscreen=true$" "$GNOME_DEFAULTS" \
    || { echo 'dash-to-dock autohide-in-fullscreen is not enabled' >&2; exit 1; }
# 用户 2026-10-17 邮件指令的全局默认扩展（不可缺项）。
# 用户 2026-10-23 指令：性能监视改用 Debian 官方 gnome-system-monitor 应用，
# paradoxxxzero 顶栏 system-monitor 扩展已移除（1610 钩子删除），此处不再断言；
# 且 enabled-extensions 里不得再引用它的 UUID（GNOME 会静默跳过，留着是脏配置）。
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
grep -q 'system-monitor@paradoxxx' "$GNOME_DEFAULTS" && {
    echo 'enabled-extensions still references the removed paradoxxxzero system-monitor extension' >&2
    exit 1
} || true
# 1610 钩子已删除：paradoxxxzero 扩展文件不得再出现在镜像里。
grep -q -E '(^|/)usr/share/gnome-shell/extensions/system-monitor@paradoxxx\.zero\.gmail\.com' "$LIST" && {
    echo 'removed system-monitor@paradoxxx.zero.gmail.com extension still in final ISO' >&2
    exit 1
} || true
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
for path in \
    usr/local/libexec/xwlightos-component-launch \
    usr/bin/xwlightos-store \
    usr/bin/xwlightos-widgets \
    usr/bin/winver \
    usr/bin/xwlightos-ipconfig \
    usr/local/bin/linux-regedit \
    usr/local/bin/devmgr; do
    if grep -q -E "(^|/)${path//./\\.}$" "$LIST"; then
        echo "final ISO still contains a removed component: /$path" >&2
        exit 1
    fi
done

# PeaZip is the only remaining binary package: the archive manager behind
# the default application associations.
require_path 'usr/bin/peazip'
require_path 'usr/share/applications/peazip.desktop'
# PeaZip's bundled libQt6Pas links libQt6PrintSupport.so.6; without it the
# launcher dies silently (user 2026-10-18: "peazip打不开").
require_path 'usr/lib/x86_64-linux-gnu/libQt6PrintSupport.so.6'
# GNOME Text Editor is the default handler for plain text.
require_path 'usr/bin/gnome-text-editor'
require_path 'usr/share/applications/org.gnome.TextEditor.desktop'
# System-wide default application associations (GNOME "默认应用程序").
MIMEAPPS="$WORK/mimeapps.list"
cat_image_file 'etc/xdg/mimeapps.list' "$MIMEAPPS"
grep -q '^text/plain=org.gnome.TextEditor.desktop$' "$MIMEAPPS"
grep -q '^image/jpeg=org.gnome.eog.desktop$' "$MIMEAPPS"
grep -q '^video/mp4=vlc.desktop$' "$MIMEAPPS"
grep -q '^application/zip=peazip.desktop$' "$MIMEAPPS"
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
require_path 'etc/skel/Desktop/ONLYOFFICE.desktop'
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

# PeaZip ships its own upstream desktop entry; XWLightOS no longer rewrites
# third-party entries through an adapter.
if command -v desktop-file-validate >/dev/null 2>&1; then
    PEAZIP_DESKTOP="$WORK/peazip.desktop"
    cat_image_file 'usr/share/applications/peazip.desktop' "$PEAZIP_DESKTOP"
    desktop-file-validate "$PEAZIP_DESKTOP"
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

# Firefox ESR 默认配置（用户 2026-10-19 邮件指令）：默认搜索引擎必应，
# 主页 bing.com。通过 Enterprise policies.json 落盘，Debian firefox-esr
# 的标准路径为 /usr/lib/firefox-esr/distribution/policies.json。
FF_POLICIES="$WORK/firefox-policies.json"
cat_image_file 'usr/lib/firefox-esr/distribution/policies.json' "$FF_POLICIES"
python3 - "$FF_POLICIES" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    pol = json.load(f)["policies"]
assert pol["SearchEngines"]["Default"] == "Bing", "default search engine is not Bing"
assert pol["Homepage"]["URL"] == "https://www.bing.com", "homepage is not bing.com"
print("XWLightOS: Firefox default search=Bing, homepage=bing.com")
PYEOF

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

printf 'XWLightOS 1.0 final ISO content validation passed: %s\n' "$ISO"
