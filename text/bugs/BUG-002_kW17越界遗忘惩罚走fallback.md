# BUG-002 · `kW[17]` 越界，遗忘惩罚走 fallback

**严重度**：🟡 中

```dart
final sMin = s / math.exp(kW.length > 17 ? kW[17] : 2.0);
```

`kW` 只有 17 项（w0~w16），`17 > 17` 永假 → 永远走 fallback 的 2.0。
结果是忘记一次稳定性只剩 13.5%，惩罚过重；而且那个 2.0 是拍脑袋的，不是 FSRS 论文值。

**修法**：显式常量 `kForgetRetainExp = 1.5`（约剩 22%）。

**修复**：2026-09-13，commit `9075549`

---
