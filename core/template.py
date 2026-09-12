"""
flashcard 模板引擎 · 占位符渲染
================================================
卡牌模板 = 一份 HTML + 一个字段字典。
渲染规则:
    {{field}}            直接替换
    {{#field}}...{{/field}}   字段为真/非空/非空列表时保留块内内容
    {{^field}}...{{/field}}   字段为空时保留

循环字段（如 phrases）不在这里展开成 HTML —— 交给模板自带的
script.js 读 getCard().fields 自己生成 DOM，这样模板作者想怎么
排版就怎么排版，引擎不掺和。

也支持 .apkg 式的 {{FrontSide}} / {{Tags}} 之类的兼容占位（可选）。
"""

from __future__ import annotations
import re
from typing import Any

# {{#name}} ... {{/name}}  /  {{^name}} ... {{/name}}
_SEC_RE = re.compile(r"\{\{([#^])(\w+)\}\}(.*?)\{\{/\2\}\}", re.S)
_VAR_RE = re.compile(r"\{\{(\w+)\}\}")


def _is_truthy(v: Any) -> bool:
    if v is None:
        return False
    if isinstance(v, str):
        return v.strip() != ""
    if isinstance(v, (list, dict, tuple, set)):
        return len(v) > 0
    return bool(v)


def render(template: str, fields: dict, extra: dict | None = None) -> str:
    """
    渲染模板。
    fields: 卡牌字段字典
    extra:  额外注入（如 __index / __total / 已学状态）
    """
    data = dict(fields)
    if extra:
        data.update(extra)

    # 反复展开 section，直到不再变化（支持嵌套）
    prev = None
    while prev != template:
        prev = template

        def _sub(m: re.Match) -> str:
            sign, name, body = m.group(1), m.group(2), m.group(3)
            truthy = _is_truthy(data.get(name))
            if sign == "#":
                return body if truthy else ""
            else:  # ^
                return "" if truthy else body

        template = _SEC_RE.sub(_sub, template)

    # 变量替换（列表字段留空，由 JS 处理）
    def _var(m: re.Match) -> str:
        name = m.group(1)
        v = data.get(name, "")
        if isinstance(v, (list, dict)):
            return ""
        return "" if v is None else str(v)

    return _VAR_RE.sub(_var, template)


def load_template(dir_path: str) -> dict:
    """读取一个模板包目录，返回 {manifest, html, css, js}"""
    import json, os
    with open(os.path.join(dir_path, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    files = manifest.get("files", {})
    # manifest 里用的是 template/style/script，内部统一成 html/css/js
    keymap = {"template": "html", "style": "css", "script": "js"}
    out = {"manifest": manifest, "html": "", "css": "", "js": ""}
    for key, fname in files.items():
        p = os.path.join(dir_path, fname)
        content = ""
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                content = f.read()
        out[keymap.get(key, key)] = content
    return out


def build_page(tpl: dict, fields: dict, extra: dict | None = None) -> str:
    """把模板 + 数据组装成一个完整的、可塞进 WebView 的 HTML 页面"""
    html = render(tpl["html"], fields, extra)
    css = tpl.get("css", "")
    js = tpl.get("js", "")
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>{css}</style>
</head>
<body>
{html}
<script>{js}</script>
</body>
</html>"""


if __name__ == "__main__":
    import json, os
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tpl = load_template(os.path.join(base, "templates", "bubei_dark"))
    deck = json.load(open(os.path.join(base, "decks", "kaoyan_20.json"), encoding="utf-8"))
    card = deck["cards"][0]
    page = build_page(tpl, card, {"__index": 1, "__total": len(deck["cards"])})
    print(page[:800])
    print("...")
    print(f"[OK] 渲染成功，页面 {len(page)} 字符")
