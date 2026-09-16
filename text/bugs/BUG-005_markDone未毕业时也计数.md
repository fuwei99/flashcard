# BUG-005 · `markDone()` 在未毕业时也计数

**严重度**：🟢 低

`await widget.settings.markDone()` 在 learn 轮每次都调，
模糊/忘记（未毕业）也算进今日进度 → 今日进度虚高。

**修法**：只在真正毕业（`graduated` 且未 `_written`）时计数。

**修复**：2026-09-13，commit `9075549`

---
