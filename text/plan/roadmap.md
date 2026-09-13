# flashcard 路线图

> 架构总纲见 [`docs/WORKFLOW.md`](../../docs/WORKFLOW.md)。
> 本文只说「接下来做什么」，按优先级排。

最后更新：2026-09-13

---

## P0 · 骨架级（不做就是残废）

### 1. 排课器 Planner

把「记忆模型」和「每日排课」拆开，见 WORKFLOW §1。

- 日预算：复习位 X / 新词位 Y（用户可调）
- 到期队列按优先级排序：`逾期天数 × 真题词频 × (1+错误率)`
- **欠账不累积**：今天没做完的，明天重新排队，不叠加
- 冲刺模式（可选叠加层）：`sprint: {target_date, weight_boost}`

**不做的话**：要么每天复习不完（雪球越滚越大），要么到期全做完（淹没）。

### 2. 标熟（`known`）

- 语义：**永久出队**，与 `graduated`（本轮通过）严格区分
- **可撤销**：长期使用，误标一次很烦
- 要留撤销口子：标熟后若在文章里猜错，自动降级回队列并提示

**不做的话**：6590 词全进队列，实际只用背 2000，白干 2/3。

---

## P1 · 体验级（决定好不好用）

### 3. 分级自测流程

导入词表后快速刷一遍：`熟 → 标熟` / `模糊` / `不认识 → 待背池`。

- 2000 词 × 3 秒 ≈ 100 分钟，分几次刷完
- **一步省掉 2/3 工作量**，优先级应该排在 TTS 前面

### 4. 今日任务统一入口

书架级一个大入口，**跨书汇总**：`复习 47 · 新词 40`。

现在必须进书 → 进章 → 点「开始复习」，太深。这是不背单词的核心体验。

---

## P2 · 能力级

### 5. TTS 抽象层

```
Flashcard.tts(text, lang)     ← 牌组只发这一句，不关心底下是谁
        │
   TtsService
        ├── SystemTtsEngine    → flutter_tts（默认：离线、免费、零延迟）
        └── OpenAiTtsEngine    → POST /v1/audio/speech
                                   model / voice / base_url / key 可配
                                   → just_audio 播放
                                   → 音频按 hash 缓存，别重复烧钱
```

设置页：引擎开关 / base_url / key / model / voice / 英美音色。
顺带接上 `manifest.tts.auto_play`（写了但没人读）：进卡自动朗读。

### 6. 词条库按 lemma 主键

把「词」提升为一等公民：

```
① 词条库 LemmaStore   主键 = word（小写 lemma）
     释义 / 音标 / 词根 / 例句 / AI 笔记 / 用户笔记 / 来源标签 / 收藏 / 标熟
     ★ 跨书共享 —— 一处加笔记，处处显示（干掉「加笔记要付费」）

② 调度库 ScheduleStore  主键 = word
     FSRS 状态

③ 牌组库 DeckStore      书 → 章 → 页，纯内容组织，不持有状态

④ 日志 EventLog         append-only，每次评分一行

⑤ 快照 status.json      给外部读
```

**当前缺口**：`CardStore` 把调度和 KV 混在一起，词条数据散在 deck json 里。

### 7. `status.json` 外部监督快照

App 每次 answer / 每轮结束 / 退出时，原子写（先 `.tmp` 再 rename）：

```
/storage/emulated/0/Documents/flashcard/status.json
```

由 Termux MCP 读取，AI 定时查岗。

**不上 MCP**（后台常驻 + 保活 + 国产 ROM 杀进程，纯挖坑）。
App 已申请 `MANAGE_EXTERNAL_STORAGE`，路已铺一半。

现有 `exportBook`（手动导出整本书）保留，那是备份/迁移用的。

---

## P3 · 增强级

### 8. 文章牌组 `article_reader`

语篇中学习。新模板 + 新数据格式：

```json
{
  "title": "AI and the Future of Work",
  "source": {"paper": "2023 英语一 Text 2", "para": 3},
  "article_html": "<p>... <w>intensive</w> ...</p>",
  "words": [
    {"w":"intensive","pos":"adj.","meaning":"密集的",
     "phonetic_us":"...","note":"AI笔记：...","sent":"原句"}
  ]
}
```

- 点击划线词 → 悬浮释义 → 三档评分
- 评分进 **词级** FSRS 状态，与单词牌组共享
- 内容生产线：真题 PDF → 提取过滤 → AI 写文章（词必须自然出现）→ deck JSON
- **密度建议 15~20 词/篇**，40 词太密阅读体验差

### 9. 其他

- 收藏 → 生词本（全局，跨书）
- 拼写题（`StudyMode.spell` 已定义未实现）
- 近义字段 `synonyms`（底栏 tab：词组搭配 / 近义 / 词根）
- 统计：累计已学 / 连续天数 / 词量增长曲线 / 错词演化
- `kMaxInterval = 365` 对长期使用偏保守，可调
- 重测轮加「跳过」逃生口（现在是无限循环直到全过）

---

## 已完成

| 日期 | 事项 |
|---|---|
| 2026-09-13 | 架构 v2 定稿；修复 5 个 bug（含 FSRS 评分失效）；CI 资源同步；v0.2.3 出包 |
