#!/bin/sh
# XWLightOS 触屏诊断启动器（诊断版专用，正式版确认根因后删除）。
# 由桌面自启动调用：打开一个最大化终端跑诊断脚本，脚本结束后
# 终端保持打开，屏幕停在诊断结果上，供用户拍照。
exec gnome-terminal --maximize -- bash -c '/usr/local/sbin/xwlightos-touch-diag.sh; exec bash'
