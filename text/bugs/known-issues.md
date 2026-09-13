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

**修法（第一版，已废弃）**：补一个「记对了」反悔位。

**修法（最终）**：天赢拍板——**不要反悔位**。点了「忘记」就老老实实显示「下一词」，
且只留这一个按钮（`flex:1` 自动撑满整行）。少一个按钮，少一层逻辑。

保留的规则只有一条：

```css
/* 正面点了「忘记」：词义页只剩「下一词」，flex:1 自动撑满整行 */
.fc-root[data-pre="again"] .fc-actions-back .fc-again{display:none}
```

**修复**：2026-09-13（第一版 commit `9075549`，最终版见当日后续 commit）

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

### BUG-007 · choice 选项没有词性

**严重度**：🔴 高（影响可用性）

选项只有中文释义，四个释义摆一起（比如「密集的 / 脆弱的 / 可行的 / 模糊的」）
光看中文根本没法选 —— 词性被丢了。

**根因**：`_choicesFor()` 只取 `fields['meaning']`，没带 `pos`。

**修法**：`choices` 从 `{text, right}` 扩成 `{text, pos, right}`，
`script.js` 把词性渲染成左侧淡色斜体小标签（`.fc-opt-pos`），答对/答错时跟着变色。

**修复**：2026-09-13（第二轮）

---

### BUG-008 · choice 和 cloze 挨着考同一个词 = 送答案

**严重度**：🔴 高（破坏考法有效性）

`_startRetest()` 里 `for each card: add choice; add cloze`，
于是顺序是 `A-choice → A-cloze → B-choice → B-cloze`。

刚做完 A 的「英→中选义」，紧接着 A 的「例句挖空选词」——
挖空句子里那个词，上一题刚在选项里见过。**啥子都知道答案。**

**修法**：重测拆成两个独立轮次，一次过完：
```
choice 轮：池内所有卡的 choice
cloze  轮：池内所有卡的 cloze
```

**修复**：2026-09-13（第二轮）

---

### BUG-009 · 答错就循环重考 = 重复刺激

**严重度**：🟡 中

原逻辑「两个考法都过才毕业，任一没过留池下一轮重来」，
于是答错一张卡就要反复考到全对为止（`_startRetest` 还每轮 `clear()` 清空记录，
导致上轮过掉的考法下轮还得重考）。

实际体验就是：选错了 → 又回来考 → 又错 → 再来。**选错了就是选错了，不该这么折腾。**

**修法**：**不再循环重考**。
```
choice 轮 → cloze 轮 → 池内所有卡直接毕业
```
挣扎程度记在 `_effort` 里，映射成 hard / again 落盘。
今天错了就错了，**明天由 FSRS 安排再见** —— 与「欠账不累积」同一套哲学。

副作用：`retestModes` / `_passedModes` 整套「全过才毕业」机制删掉，代码短了一截。

**修复**：2026-09-13（第二轮）

---

## ⚠️ 观察项（待定，非明确 bug）

### OBS-001 · ~~重测轮 `_passedModes.clear()` 浪费~~ 【已随 BUG-009 解决】

重测不再循环，每张卡每轮只考一次，不存在「下轮重考」问题。

### OBS-002 · ~~重测轮没有逃生口~~ 【已随 BUG-009 解决】

不再有无限循环，走完 choice + cloze 两轮自动结束。

### OBS-003 · 首次间隔恒为 1 天

`kLearningInterval = 1`，之后按 FSRS 递增（约 1 → 7 → 20 → 50 → …）。

### OBS-004 · `kMaxInterval = 365` 偏保守

对长期使用（不只考研）可能偏短，可调。

---

## 📋 待修

暂无。新 bug 往这里追加。
