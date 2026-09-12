#!/usr/bin/env bash
# 起一个静态服务，浏览器打开预览壳
# 用法: bash serve.sh  然后浏览器访问 http://localhost:8080/webpreview/
set -e
cd "$(dirname "$0")/.."
PORT="${1:-8080}"
echo "flashcard 预览服务: http://localhost:${PORT}/webpreview/"
echo "按 Ctrl-C 停止"
python3 -m http.server "$PORT"
