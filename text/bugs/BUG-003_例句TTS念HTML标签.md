# BUG-003 · 例句 TTS 念 HTML 标签

**严重度**：🟡 中

`sentence_en` 形如 `The course requires <u>intensive</u> study...`，
按钮直接 `data-tts="{{sentence_en}}"` → 系统 TTS 念出 "less-than-u-greater-than"。

**修法**：`webview_bridge` 的 `tts` 分支统一剥标签（所有牌组受益），
`script.js` 加第二道防线。

**修复**：2026-09-13，commit `9075549`

---
