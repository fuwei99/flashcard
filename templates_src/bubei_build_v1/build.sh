#!/usr/bin/env bash
# bubei_build_v1 模板构建脚本
# ============================================================
# 把本目录（React+Vite 源）build 成壳能内联的三件套，
# 产物拷到 templates/bubei_build_v1/。
#
# 用法：
#   bash templates_src/bubei_build_v1/build.sh
#
# 依赖：node >= 20.19（vite 7 要求）。首次跑会自动 npm install。
# ============================================================
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
OUT="$ROOT/templates/bubei_build_v1"

echo "==> 安装依赖"
[ -d node_modules ] || npm install --no-audit --no-fund

echo "==> 构建（vite lib 模式 → IIFE + 降级 CSS + 内联图片）"
npm run build

echo "==> 拷产物到 $OUT"
mkdir -p "$OUT"
cp dist/script.js "$OUT/script.js"
cp dist/style.css "$OUT/style.css"

echo "==> 语法自检"
node --check "$OUT/script.js" && echo "  script.js OK"

echo "==> 完成"
ls -la "$OUT"
echo
echo "提示：设备侧同步"
echo "  cp $OUT/* /mnt/Flashcard/templates/bubei_build_v1/"

# ------------------------------------------------------------
# 关键坑（踩过，别再踩）：
#   vite lib 模式**不会**自动替换 process.env.NODE_ENV，
#   React 的 CJS 构建里带着它 → WebView 没有 process 对象
#   → ReferenceError → 整个 IIFE 崩掉 → 白屏。
#   vite.config.ts 里用 define 强制替换成字面量。改配置时别删。
# ------------------------------------------------------------
