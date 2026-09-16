# 已知问题台账

最后更新：2026-09-16

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

### BUG-009 · 答错后不给看词义，只机械重复

**严重度**：🟡 中

choice / cloze 答错后直接翻篇 —— 既不显示完整的词义，也不给学习机会。
而这张卡后面还要重考，于是变成「选错 → 下一题 → 又考 → 又错」的纯机械循环，
错的人在原地打转，学不到东西。

**修法**：**答错切到词义页**，把词 + 词性 + 释义 + 例句完整看一遍，
点「下一词」继续。这张卡**仍然会被重考**（循环到 choice + cloze 都过），
但每轮答错后都先补一遍课，而不是干巴巴重复。

**注意**：**循环重考本身是设计意图，保留**。上一版草稿误读成「不要重考」，
已纠正。

**修复**：2026-09-13（第二轮）

---

## ⚠️ 观察项（待定，非明确 bug）

### OBS-001 · ~~重测轮 `_passedModes.clear()` 浪费~~ 【已随 BUG-008 解决】

现在每轮只考「还没过」的考法（`_startChoice()` / `_startCloze()` 会跳过已过的），
不会再 clear 之后把已过的考法也重考一遍。

### OBS-002 · 重测轮没有逃生口

循环重考是**设计意图**（choice + cloze 两个考法都过才毕业），
但词太生时可能一直卡在某一轮。考虑加一个「跳过」出口。

### OBS-003 · 首次间隔恒为 1 天

`kLearningInterval = 1`，之后按 FSRS 递增（约 1 → 7 → 20 → 50 → …）。

### OBS-004 · `kMaxInterval = 365` 偏保守

对长期使用（不只考研）可能偏短，可调。

---

### BUG-010 · 切页卡顿与幽灵点击穿透秒跳正面
**严重度**：🔴 高（破坏背诵流程）
**现象**：词义页点击「下一词」时因 `loadHtmlString` 重载造成延迟卡顿，用户连击屏幕，第二击命中新页面的正面按钮（如「记得」），导致新卡正面被秒跳，直接进入词义解析。
**根因**：WebView 全页重载造成数十至数百毫秒的白屏/无响应，未采用 SPA 增量数据挂载，且缺乏切页防抖门锁。
**方案**：见 [`text/plan/2026-09-15_refactor_plan.md`](../plan/2026-09-15_refactor_plan.md)。
**修复**：2026-09-15（骨架页单次 load + `Flashcard.mountCard()` DOM 增量挂卡 + 250ms 连点锁）。

---

### BUG-011 · UI 改版引入的 4 个回归/漏洞（2026-09-15 复审）

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

## 📋 待修

### BUG-012 · 自评“记得”直接绕过测验毕业（熟识感幻觉漏洞）

**严重度**：🔴 高（破坏记忆闭环 / 算法被欺骗）

**现象**：
在背诵/复习第一阶段（learn），只要用户点击「记得（good）」，卡片直接调用 `graduated.add(card.id)` 毕业出队并落盘 FSRS `Rating.good`，完全绕过后续的客观重测（Choice 选义 / Cloze 填空）。
用户在实际背诵中极易因单词形体眼熟产生“熟识感幻觉（Fluency Illusion）”，误以为自己掌握。这种虚假自评会导致未掌握词被 FSRS 判定为高稳定性，复习间隔被指数级拉长，考场上直接暴毙。

**根因**：
`StudySession.submitLearn()` 过度信任主观自评，将「记得」作为无条件毕业的逃逸出口：
```dart
void submitLearn(Rating r) {
  if (r == Rating.good || _modesFor(card).isEmpty) {
    graduated.add(card.id); // 直接毕业，不进重测池
  } else {
    _retestPool.add(card);
    _bump(card.id, r == Rating.again ? 2 : 1);
  }
  _advance();
}
```

**改造方案**：
1. **彻底废除主观三档自评**：移除「记得 / 模糊 / 忘记」按钮，禁止由用户良心决定卡片是否毕业。
2. **强制客观首测（英选汉）**：卡片呈现上来就是看英语选中文释义（4 选 1）。
3. **容错与惩罚闭环**：
   - 选对：进入下一阶验证或判定本次通过；
   - 选错/记错：直接判定为 `again`（`_effort` 升至 2），当场弹回展示完整词义/例句解析，并强制丢入本轮重测池反复重考，直到客观答对才能毕业。

