#!/bin/bash
# XWLightOS 构建日志复查脚本
# 用法: ./scripts/review-xwlightos-build-log.sh [release-tag]
# 不带参数则复查最新 release 的 build.log
set -euo pipefail

REPO="mic-yh10993/XWLightOS"
TOKEN_FILE="$HOME/.dclawos_github_token"
TAG="${1:-}"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "错误: token 文件不存在: $TOKEN_FILE" >&2
    exit 1
fi
TOKEN="$(cat "$TOKEN_FILE")"

# 确定 tag
if [ -z "$TAG" ]; then
    TAG="$(curl -s -H "Authorization: Bearer $TOKEN" \
        "https://api.github.com/repos/$REPO/releases/latest" | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")"
    echo "使用最新 release: $TAG"
fi

# 找到 build.log 的 asset id
ASSET_ID="$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/$REPO/releases/tags/$TAG" | \
    python3 -c "
import json,sys
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if a['name'] == 'build.log':
        print(a['id'])
        break
")"

if [ -z "$ASSET_ID" ]; then
    echo "错误: release $TAG 中没有找到 build.log" >&2
    exit 1
fi

# 下载
LOGFILE="/tmp/xwlightos-build-$TAG.log"
curl -sL -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/octet-stream" \
    -o "$LOGFILE" \
    "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID"

LINES="$(wc -l < "$LOGFILE")"
echo "=== XWLightOS 构建日志复查: $TAG ==="
echo "日志行数: $LINES"
echo ""

# 关键检查
echo "--- 钩子执行 ---"
grep -c "XWLightOS:" "$LOGFILE" | xargs echo "XWLightOS 标记行数:"
echo ""
echo "--- 教育软件 ---"
grep "XWLightOS: fetching" "$LOGFILE" | sed 's/.*fetching //' | sort -u
echo ""
echo "--- 错误扫描 ---"
ERRORS="$(grep -in "failed\|error\|missing path\|exit non-zero" "$LOGFILE" | grep -vi "0 failed" | head -20)"
if [ -z "$ERRORS" ]; then
    echo "未发现错误关键字"
else
    echo "$ERRORS"
fi
echo ""
echo "--- 关键里程碑 ---"
for pattern in "touchscreen" "education software" "WhiteSur" "firefox" "onlyoffice"; do
    count="$(grep -ci "$pattern" "$LOGFILE")"
    echo "$pattern: $count 行"
done
echo ""
echo "日志已保存: $LOGFILE"
