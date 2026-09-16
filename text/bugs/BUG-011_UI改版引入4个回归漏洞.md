# BUG-011 · UI 改版引入的 4 个回归/漏洞（2026-09-15 复审）

**严重度**：🔴 高

`2eab0e4` 深度改版 `script.js` 时，把 `151d069` 的部分修复连同新逻辑一起带崩。复审发现：

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | **BUG-009 回归**：choice/cloze 答错不再切词义页 | 重写 `pick()` → `handleChoicePick()` 时丢了 `data-state="back"`；且 `mount()` 只在 read 模式调 `renderBackFace()`，就算切过去也是空页 | `handleChoicePick` 答错切 back；`mount()` 改为所有模式都先 `renderBackFace()` |
| 2 | **cloze 自动发音泄题** | 新增的「进卡自动发音」对 cloze 也播，而 cloze 的答案就是这个单词 | 自动发音加 `mode !== "cloze"` 条件 |
| 3 | **250ms 连点锁对选项按钮失效** | 选项是直接 `addEventListener`，事件在 target 阶段先于 root 委托执行，绕过了 `clickLock` | `handleChoicePick` 开头加 `if (clickLock) return;` |
| 4 | **cloze 挖空正则未转义 + 全局替换** | `new RegExp(w, "ig")`：`a.m.` 之类会抛异常，`act` 会误挖 `practice` | 转义正则元字符 + `\b...\b` 整词、首次替换 |

另修两处低危：`_onMsg` 的 `Rating.fromKey` 对未知评分会 `throw` 且无捕获 → 兜底 `good`；骨架页首帧不再渲染空卡（避免闪一下空页）。

**修复**：2026-09-15（本次复审，`templates/bubei_dark/script.js` + `app/lib/screens/review_screen.dart`）。

---
