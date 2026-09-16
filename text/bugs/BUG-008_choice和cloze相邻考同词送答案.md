# BUG-008 · choice 和 cloze 挨着考同一个词 = 送答案

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
