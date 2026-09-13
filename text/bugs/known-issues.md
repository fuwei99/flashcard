# 已知问题台账

最后更新：2026-09-13

---

## ✅ 已修

### BUG-001 · FSRS 三档评分从来没生效

**严重度**：🔴 核心

**现象**：稳定性只涨不跌，一个词实际忘了五次，调度器眼里每次都是「记得很好」。
`_stabilityAfterForget()` 和 `hardPenalty` 是死代码。

**根因**：`review_screen.dart` 两处落盘都写死 `Rating.good`，
而 `review()` 全项目只有那一个调用点。JS 发来的 `again`/`hard` 被当成布尔用掉后丢弃。

```dart
// 修复前
69:  if (willGraduate) _write(id, Rating.good);
74:  if (_session.graduated.contains(id)) _write(id, Rating.good);
```

**修法**：`StudySession._effort[cardId]`（只增不减）+ `ratingFor(cardId)`，
毕业时按本轮挣扎程度选档（一次过 good / 费劲 hard / 硬骨头 again）。

**修复**：2026-09-13，commit `9075549`

---

### BUG-002 · `kW[17]` 越界，遗忘惩罚走 fallback

**严重度**：🟡 中

```dart
final sMin = s / math.exp(kW.length > 17 ? kW[17] : 2.0);
```

`kW` 只有 17 项（w0~w16），`17 > 17` 永假 → 永远走 fallback 的 2.0。
结果是忘记一次稳定性只剩 13.5%，惩罚过重；而且那个 2.0 是拍脑袋的，不是 FSRS 论文值。

**修法**：显式常量 `kForgetRetainExp = 1.5`（约剩 22%）。

**修复**：2026-09-13，commit `9075549`

---

### BUG-003 · 例句 TTS 念 HTML 标签

**严重度**：🟡 中

`sentence_en` 形如 `The course requires <u>intensive</u> study...`，
按钮直接 `data-tts="{{sentence_en}}"` → 系统 TTS 念出 "less-than-u-greater-than"。

**修法**：`webview_bridge` 的 `tts` 分支统一剥标签（所有牌组受益），
`script.js` 加第二道防线。

**修复**：2026-09-13，commit `9075549`

---

### BUG-004 · `data-pre=again` 时手滑不可逆

**严重度**：🟡 中

原 CSS 在 `pre=again` 时藏掉「记错了」，导致：

| 手滑方向 | 能否救 |
|---|---|
| `忘记→记得` | ✅ 词义页有「记错了」 |
| `记得→忘记` | ❌ 被藏，只剩「下一词」，只能认 again |

**修法**：补「记对了」反悔位（`data-rating="good"`），只在 `pre=again` 时露出。

**修复**：2026-09-13，commit `9075549`

---

### BUG-005 · `markDone()` 在未毕业时也计数

**严重度**：🟢 低

`await widget.settings.markDone()` 在 learn 轮每次都调，
模糊/忘记（未毕业）也算进今日进度 → 今日进度虚高。

**修法**：只在真正毕业（`graduated` 且未 `_written`）时计数。

**修复**：2026-09-13，commit `9075549`

---

### BUG-006 · 改根 `templates/` 不进 APK

**严重度**：🔴 核心（差点白干）

`app/assets/templates/` 是**独立副本**而非软链。
改了根 `templates/bubei_dark/` 三个文件，APK 里还是旧模板。
`diff` 确认差异恰好只有当时那几处编辑。

**修法**：CI 构建前强制 `cp -r templates/. app/assets/templates/`，
确立根目录为唯一真源。

**修复**：2026-09-13，commit `9075549`

---

## ⚠️ 观察项（待定，非明确 bug）

### OBS-001 · 重测轮 `_passedModes.clear()` 浪费

`_startRetest()` 每轮清空通过记录，所以上一轮过了一个考法，下一轮两个都要重考。
符合「两个都过」的设计，但略费时。

### OBS-002 · 重测轮没有逃生口

是**无限循环直到全过**（不是死锁，已验证）。词太生时用户可能卡住，考虑加「跳过」。

### OBS-003 · 首次间隔恒为 1 天

`kLearningInterval = 1`，之后按 FSRS 递增（约 1 → 7 → 20 → 50 → …）。

### OBS-004 · `kMaxInterval = 365` 偏保守

对长期使用（不只考研）可能偏短，可调。

---

## 📋 待修

暂无。新 bug 往这里追加。
