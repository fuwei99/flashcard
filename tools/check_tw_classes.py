#!/usr/bin/env python3
"""扫模板 script.js 里用到的 Tailwind 任意值类，比对 style.css 产物，列出缺失。

背景：bubei_react_v1 靠内联 Tailwind 任意值类（bg-[#262c44] 这种）撑样式，
style.css 是编译产物。Tailwind JIT 只扫源码字符串，扫不到 JS 里 `'..'+cls+'..'`
动态拼出来的类名 —— 于是漏编译，弹窗/间距/z-index 全裸奔。

用法：
    python3 tools/check_tw_classes.py [模板目录]
    # 默认 templates/bubei_react_v1
缺任何一个类就 exit 1，方便挂 CI / pre-commit。
"""
import os
import re
import sys

PREFIX = r"""(?:bg|text|border|rounded|z|w|h|p|px|py|pt|pb|pl|pr|m|mx|my|mt|mb|ml|mr|
gap|leading|tracking|decoration|underline-offset|shadow|inset|top|left|right|bottom|
min-w|min-h|max-w|max-h|flex|grid|col|row|space|blur|opacity|font|animate|transition|
duration|scale|translate|from|via|to|order|basis|grow|shrink|overflow|cursor|select|
list|align|justify|content|place|self|object|aspect|columns|indent|whitespace|break|
line|ring|outline|divide|fill|stroke|caret|accent|will|origin|rotate|skew|delay|ease|
isolation|mix|backdrop|filter|drop|saturate|sepia|grayscale|invert|hue|pointer|tabular)"""

USED_RE = re.compile(
    r"\b(" + PREFIX.replace("\n", "") + r"-\[[^\]\s\"']+\])"
)

# Tailwind 产物里这些字符要转义
ESC_CHARS = "[]#/%.(),"


def esc_cls(u: str) -> str:
    out = []
    for ch in u:
        out.append("\\" + ch if ch in ESC_CHARS else ch)
    return "".join(out)


def main() -> int:
    tpl = sys.argv[1] if len(sys.argv) > 1 else "templates/bubei_react_v1"
    js_path = os.path.join(tpl, "script.js")
    css_path = os.path.join(tpl, "style.css")
    if not os.path.exists(js_path) or not os.path.exists(css_path):
        print(f"找不到 {js_path} 或 {css_path}", file=sys.stderr)
        return 2
    js = open(js_path, encoding="utf-8").read()
    css = open(css_path, encoding="utf-8").read()
    used = set(USED_RE.findall(js))
    miss = sorted(u for u in used if ("." + esc_cls(u)) not in css)
    print(f"{tpl}: 任意值类 {len(used)} 个，CSS 产物缺失 {len(miss)} 个")
    for m in miss:
        print("  MISS", m)
    if miss:
        print("\n=> 补进 style.css 末尾（Tailwind 转义写法），否则这些样式裸奔。")
    return 1 if miss else 0


if __name__ == "__main__":
    sys.exit(main())
