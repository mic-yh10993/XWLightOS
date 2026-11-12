#!/bin/sh
# XWLightOS: auto-enable no-auth drives when the user chose passwordless login.
#
# 第 13 轮（2026-11-12，用户 2026-11-11 邮件第 3 项“如果安装系统勾选
# 了免密码登录自动开启该功能”）：一次性服务，只跑一次（stamp 文件
# /var/lib/xwlightos/noauth-drives-autosetup.done）。开机时读装好后的
# 系统状态——GDM 自动登录是否开着（/etc/gdm3/daemon.conf 的
# AutomaticLoginEnable=true + AutomaticLogin=<用户>，或 AccountsService
# 里该用户的 AutomaticLogin=true）——若开着，就调助手脚本装上免授权
# 规则；没开就不动，开关保持关着。
#
# 为什么不在 postinstall 里做：Calamares 的 settings.conf 不在仓库，
# 无法确认 users 模块与 shellprocess（postinstall）的先后；postinstall
# 还会删 daemon.conf 里的 AutomaticLogin 行——若 users 模块先于它跑，
# 它根本看不到安装时的选择。本服务只读装好后的系统状态，不依赖
# Calamares 模块顺序。只跑一次，所以用户之后在设置里手动关掉开关，
# 不会被下次开机顶回来。
#
# 注意：live 会话本身就是自动登录（daemon.conf 里 AutomaticLogin=user），
# 所以 live 下本服务也会把规则装上——这是按“自动登录→免授权”同一规则
# 办事，不是 bug；安装后的系统按安装时勾没勾免密码登录决定。
# 尽力而为：读不到状态、助手脚本失败，都不拖垮开机（返回 0）。
set -eu

STAMP=/var/lib/xwlightos/noauth-drives-autosetup.done
[ -f "$STAMP" ] && exit 0

AUTOLOGIN_USER=""
if [ -f /etc/gdm3/daemon.conf ]; then
    if grep -q '^AutomaticLoginEnable=true' /etc/gdm3/daemon.conf; then
        AUTOLOGIN_USER=$(sed -n 's/^AutomaticLogin=//p' /etc/gdm3/daemon.conf | head -1)
    fi
fi
if [ -z "$AUTOLOGIN_USER" ]; then
    for f in /var/lib/AccountsService/users/*; do
        [ -f "$f" ] || continue
        if grep -q '^AutomaticLogin=true' "$f"; then
            AUTOLOGIN_USER=$(basename "$f")
            break
        fi
    done
fi
if [ -n "$AUTOLOGIN_USER" ]; then
    /usr/local/libexec/xwlightos-toggle-noauth-drives on || true
fi
mkdir -p /var/lib/xwlightos
touch "$STAMP"
exit 0
