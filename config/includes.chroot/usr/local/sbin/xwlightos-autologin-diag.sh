#!/bin/sh
# XWLightOS 自动登录诊断（烟测门禁的会话证据来源，常驻保留）。
# 在 GDM 启动约 240 秒后，把自动登录的关键状态写到串口（/dev/ttyS0），
# 供 QEMU 烟测在像素未见壁纸时判定会话是否已注册：GDM 是否尝试自动登录、
# AccountsService 是否已看到 live 用户、用户会话是否存在。输出很小，
# 不拖慢启动（区别于全量 journal 转发，后者可能改变启动时序）。
OUT=/dev/ttyS0
[ -e "$OUT" ] || OUT=/dev/console
{
  echo "=== XWLightOS autologin diag ==="
  echo "--- loginctl sessions ---"
  loginctl --no-legend 2>&1 || true
  echo "--- gdm active ---"
  systemctl is-active gdm.service 2>&1 || true
  echo "--- accountsservice users ---"
  busctl tree org.freedesktop.Accounts 2>&1 | head -20 || true
  echo "--- gdm journal last 40 ---"
  journalctl -u gdm.service --no-pager -n 40 2>&1 || true
  echo "--- user manager ---"
  systemctl status 'user@1000.service' --no-pager 2>&1 | head -8 || true
  echo "=== end autologin diag ==="
} > "$OUT" 2>&1 || true
