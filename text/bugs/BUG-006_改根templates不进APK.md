# BUG-006 · 改根 `templates/` 不进 APK

**严重度**：🔴 核心（差点白干）

`app/assets/templates/` 是**独立副本**而非软链。
改了根 `templates/bubei_dark/` 三个文件，APK 里还是旧模板。
`diff` 确认差异恰好只有当时那几处编辑。

**修法**：CI 构建前强制 `cp -r templates/. app/assets/templates/`，
确立根目录为唯一真源。

**修复**：2026-09-13，commit `9075549`

---
