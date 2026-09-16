# BUG-001 · FSRS 三档评分从来没生效

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
