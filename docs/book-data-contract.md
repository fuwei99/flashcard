---
doc_version: 1
status: 生效（v4 草案作废，见 git 历史）
title: 书 / 卡 数据契约
audience: Agent / 模板作者 / 数据脚本
source_of_truth: reference/最新不背单词复刻源码/src/flashcard/data.ts
---

# 书 / 卡 数据契约

> **一句话**：模板只认一种卡形 —— 源码 `src/flashcard/data.ts` 的 `WordCard`。
> 书的每张卡 = 一个 `WordCard` + `id`，**平铺**（不是塞进 `fields`）。
> 不再靠字段名猜、不再正则补高亮、不再往句子里埋 `<u>`。
> 老书（v3）文件不动，靠 adapter 在内存里归一化。

---

## 0. 为什么废掉 v4 草案

v4 草案（`run 化文本 / 内联动作 / 显式渲染契约`）是**在没人给定目标形状时**的自我发明。
现在「最新复刻源码」把 `WordCard` 接口**写死**了 —— 目标形状已经存在，照抄即可，
再自造一套「run / tap」只会多一层翻译，反而离模板要的东西更远。

**结论**：契约 = 源码 `WordCard` 的 JSON 化。唯一改动是补 `id` 和可选扩展字段。

---

## 1. 卡：WordCard

### 1.1 类型定义（与源码 1:1）

```ts
interface Sense {
  pos: string;          // "n." / "adj." / "v."
  cn: string[];         // 词义，数组！["事件", "(两国间的) 冲突"]
}

interface SenseExample {
  en: string;
  cn: string;
  src: string;          // "词书例句" / "柯林斯" / "NPR 听力" / "BBC 新闻"
}

interface MeaningDetail {
  meaning: string;      // 必须与某个 senses[].cn 里的字符串【完全相等】
  enDef?: string;       // 英文释义（例句卡下半屏）
  pattern?: string;     // 用法框，如 "~ (of / in sth)"
  examples: SenseExample[];
}

interface WordCard {
  id: string;           // 唯一 id（壳会用它做 FSRS 主键）
  word: string;
  syllable: string;     // "com·po·nent"（拆分助记）
  phonetic: string;     // "/kəmˈpoʊnənt/"
  verified?: boolean;   // 人工校验过（数据质量位，模板只当 flag）

  senses: Sense[];

  sentence: { en: string; cn: string };   // 主例句；en 里【不要】埋 <u>

  collocations: { en: string; cn: string; m?: number; tag?: string }[];
  derivatives?: { word: string; pos: string; cn: string }[];
  synonyms?: string[];
  antonyms?: string[];
  root?: { tag: string; text: string }[];
  rootSummary?: string;
  exams?: { en: string; src: string; level?: string }[];

  meaningDetails?: MeaningDetail[];       // 例句轮播卡的燃料
}
```

### 1.2 字段 → 渲染位置

| 字段 | 必填 | 渲染在哪 | 备注 |
|---|---|---|---|
| `id` | ✅ | 壳主键 | 没有 `id` 壳会退回用 `word` |
| `word` | ✅ | Hero 大标题 / 真题高亮 / 点词 | |
| `syllable` | ✅ | Hero（`prefs.syllable` 开时替代 word） | v3 缺，可生成 |
| `phonetic` | ✅ | Hero 发音胶囊右侧 | v3 有 us/uk 两串 → 取 us |
| `verified` | ⬜ | 无直接渲染 | 质量位 |
| `senses` | ✅ | 词义行（`SenseLine`）；笔记浮层 chips | `cn` 逐条渲染 |
| `sentence` | ✅ | 例句卡上半屏；学习正面 | `en` 可点词 |
| `collocations` | ✅ | tab「词组搭配」 | 无则 tab 空 |
| `derivatives` | ⬜ | tab「派生」 | 无则 tab 空 |
| `synonyms` | ⬜ | tab「近义」→ 近义行 | |
| `antonyms` | ⬜ | tab「近义」→ 反义行 | 近反义同 tab |
| `root` | ⬜ | tab「词根」→ 标签+文本 | |
| `rootSummary` | ⬜ | tab「词根」→ 末尾整段 | |
| `exams` | ⬜ | 真题浮层（搜索框那个） | |
| `meaningDetails` | ⬜ | **例句轮播卡**（`SentenceViewer`） | 没有它点词义不开轮播 |

### 1.3 三条绑定机制（缺一不可）

1. **`senses[].cn[]` ↔ `meaningDetails[].meaning`**
   字符串**完全相等**才算绑定。绑定的词义渲染成**虚线下划线 + 可点**，
   点开 = 打开例句轮播卡并定位到该 detail。不绑定的词义是纯文本。

   > 源码：`details.findIndex((d) => d.meaning === m)` —— `===`，不是 includes。

2. **`collocations[].m`** = 绑定的 `meaningDetails` 序号。
   - `m` 省略 → 默认 `0`
   - `m === -1` → **不绑**（不划虚线、不可点）
   - `m >= 0` 且 `details.length > m` → 绑定，虚线可点，点开定位
   - `m >= details.length` → 越界，按不绑处理

3. **pos 反查**：例句轮播卡下半屏词性不是单独存的，是
   `senses.find(s => s.cn.includes(detail.meaning))?.pos` **反查**出来的。
   → 所以 `meaning` 必须能在 `senses[].cn` 里精确命中，否则词性为空。

### 1.4 正例（`incident`，全部字段填满）

```json
{
  "id": "incident",
  "word": "incident",
  "syllable": "in·ci·dent",
  "phonetic": "/ˈɪnsɪdənt/",
  "verified": true,
  "senses": [
    { "pos": "n.", "cn": ["事件", "(两国间的) 冲突", "事变"] }
  ],
  "sentence": {
    "en": "This was a very unfortunate incident.",
    "cn": "这是一次非常不幸的事件。"
  },
  "collocations": [
    { "en": "an unfortunate incident", "cn": "不幸的事件", "tag": "核心高频" },
    { "en": "a shooting incident", "cn": "枪击事件" },
    { "en": "a diplomatic incident", "cn": "外交事件" },
    { "en": "without incident", "cn": "平安无事地", "m": -1 }
  ],
  "derivatives": [
    { "word": "incidence", "pos": "n.", "cn": "发生率；发病率" },
    { "word": "incidental", "pos": "adj.", "cn": "附带的；次要的" },
    { "word": "incidentally", "pos": "adv.", "cn": "顺便提一句" }
  ],
  "synonyms": ["event", "occurrence", "episode", "happening"],
  "antonyms": ["routine", "normality"],
  "root": [
    { "tag": "前缀", "text": "in- = 在…上，向内" },
    { "tag": "词根", "text": "cid = 落下，降临" },
    { "tag": "后缀", "text": "-ent = 名词后缀" }
  ],
  "rootSummary": "incident = 落到头上的事 ⇨ 发生的事件，(偶发的) 冲突",
  "exams": [
    { "en": "This was a very unfortunate incident.", "src": "考研一 2015 阅读", "level": "考研" },
    { "en": "The incident was quickly forgotten by the public.", "src": "考研二 2018 完形", "level": "考研" }
  ],
  "meaningDetails": [
    {
      "meaning": "事件",
      "enDef": "something that happens, especially sth unusual or unpleasant 事件，事故",
      "pattern": "~ (of sth)",
      "examples": [
        { "en": "This was a very unfortunate incident.", "cn": "这是一次非常不幸的事件。", "src": "词书例句" },
        { "en": "The incident was caught on camera.", "cn": "这一事件被摄像机拍了下来。", "src": "NPR 听力" },
        { "en": "Police are investigating the incident.", "cn": "警方正在调查这一事件。", "src": "BBC 新闻" }
      ]
    },
    {
      "meaning": "(两国间的) 冲突",
      "enDef": "a serious or violent event, such as a crime, an accident or an attack （两国间的）冲突，摩擦",
      "examples": [
        { "en": "The border incident raised tensions between the two countries.", "cn": "边境冲突加剧了两国间的紧张局势。", "src": "NPR 听力" }
      ]
    }
  ]
}
```

注意正例里：`"事件"` 和 `"(两国间的) 冲突"` 在 `senses[].cn` 和
`meaningDetails[].meaning` 里**一字不差**重复 —— 这就是绑定。

---

## 2. 查词浮层（DictEntry，独立数据源）

点词查词（`DictPopup`）用的是**另一套**数据结构，不是 `WordCard`：

```ts
interface DictExample { en: string; cn?: string; src?: string }

interface DictEntry {
  word: string;
  phonetic?: string;
  level?: string;                            // 考研 / 四级 / 高考 …
  senses: { pos: string; cn: string }[];     // 注意：cn 是【字符串】，不是数组
  collocations?: { en: string; cn: string }[];
  examples?: DictExample[];
  fromApi?: boolean;
}
```

> ⚠️ **形状陷阱**：`WordCard.senses[].cn` 是 `string[]`，`DictEntry.senses[].cn` 是 `string`。
> 两套数据源，别混。查词浮层的数据来自本地词库 + dictionaryapi.dev，
> **不在书 JSON 里** —— 书不负责喂它。

---

## 3. 书封皮：`index.json`

```json
{
  "format": "flashcard.book.v3",
  "book_id": "english_zhenti_shengciben",
  "title": "英语一真题生词本",
  "subtitle": "江锋 · 历年真题生词分年收录",
  "template": "bubei_ref",
  "fields_order": ["word", "syllable", "phonetic", "senses", "sentence", "collocations", "derivatives", "synonyms", "antonyms", "root", "exams", "meaningDetails"],
  "defaults": { "tts": { "lang": "en-US", "rate": 0.95 } }
}
```

| 键 | 说明 |
|---|---|
| `format` | `flashcard.book.v3`（当前壳认这个；卡形归契约管，不靠 format 版本区分） |
| `book_id` | 目录名，壳主键 |
| `template` | 用哪个模板，如 `bubei_ref` |
| `fields_order` | 只当**壳拼空字段的种子**；`fromJson` 会把卡里所有键都收进 `fields`，不限于此 |
| `defaults.tts` | 语音默认参数 |

> `fields_order` 不是白名单 —— 卡里多出来的键照样进 `fields`。
> 它只决定「壳预置了哪些空键」。所以列全即可，漏了也不丢数据。

---

## 4. 章文件：`ch_XXXX.json`

```json
{
  "chapter_id": "ch_0001",
  "title": "第 1 章",
  "passage": { "title": "...", "text": "含 [word] 标记的短文", "cn": "译文" },
  "cards": [ { /* WordCard + id，平铺 */ } ]
}
```

- `cards[]` 里每张卡 = **平铺的 WordCard**，键直接在卡对象根上。
- `passage.text` 用 `[word]` / `[surface|lemma]` 标记（见 `book.dart` `Passage.parse`）。
- 章节唯一真源是目录里的 `ch_*.json`，`index.json` 不再列章节。

---

## 5. 壳怎么把卡喂给模板

```
ch_*.json 的 cards[]
   └─ FlashCard.fromJson  → fields = 卡所有键（去 id）
        └─ card.get / mountCard → { id, fields, state, kv, ... }
             └─ 模板读 card.fields.word / card.fields.senses / ...
```

所以模板侧拿到的是 `card.fields`，键名 = 契约字段名。**没有 `id` 之外的包裹层级**。

---

## 6. 老书 adapter：v3 → 本契约

老书（`schema 2`）不动文件。壳或模板在内存里归一化。规则：

| v3 字段 | → 本契约 | 转换规则 |
|---|---|---|
| `word` | `word` | 直通 |
| `phonetic_us` | `phonetic` | 取 us；空则取 uk；再去掉首尾 `/` 可保可去 |
| `phonetic_uk` | （丢弃） | 需要保留就另存扩展键，模板不读 |
| `senses[].cn: string` | `senses[].cn: string[]` | 按 `；`/`;` 拆；无分隔符则单元素 |
| `derivatives[{word, senses:[{pos,cn}]}]` | `derivatives[{word,pos,cn}]` | 取首个 sense；多义项用 `；` 连 |
| `synonyms[{word, senses}]` | `synonyms: string[]` | **只取 word，丢释义**（信息损失，需补） |
| `antonyms` | 同上 | 同上 |
| `sentence_en`（含 `<u>w</u>`） | `sentence.en` | **剥掉 `<u>`/`</u>`** |
| `sentence_cn` | `sentence.cn` | 直通 |
| `blocks[]` | 拆到 `collocations` / `root` / 留 `blocks` | 见 §6.1 |
| `exam_tag: string` | `exams[].src` | 只能当来源标签；**没有 `en` 句子，真题浮层照样空** |
| （无） | `syllable` | 缺 → 可留空或按音节生成 |
| （无） | `collocations` | 缺 → tab 空 |
| （无） | `root` / `rootSummary` | 从 `blocks`「词根助记」文本拆（脆，建议重做） |
| （无） | `meaningDetails` | 缺 → **例句轮播卡点不开** |
| （无） | `exams[].en` | 缺 → 真题浮层空 |
| （无） | `verified` | 缺 → 留空 |

### 6.1 `blocks[]` 的拆法（v3 唯一的结构化残留）

v3 `blocks` 是 `{type, title, text?|items?}`。按 `title` 关键字粗拆：

| block title 含 | → 目标字段 |
|---|---|
| 「词组」「搭配」 | `collocations`（`text`/`items` 逐行拆 `en`+`cn`） |
| 「词根」「助记」 | `root` + `rootSummary`（自由文本，拆不干净，能拆多少算多少） |
| 「柯林斯」 | 留 `blocks`（模板暂不渲染，或未来加 tab） |
| 「考点」「考频」 | 留 `blocks` |
| 「真题」 | 若含 `{en, src}` 则进 `exams`，否则留 `blocks` |

> **这块是"尽力而为"**，不是无损。v3 的「词根助记」是一坨自由文本
> （`〔李〕[re-;tail]...`），拆成 `{tag,text}` 会丢结构。**数据重做才是正解**。

---

## 7. 缺口：数据从哪来

现有 v3 书 **转不出**本契约的这几样，必须重做/补数据：

| 缺什么 | 影响 | 补法 |
|---|---|---|
| `collocations` | 词组 tab 空 | 从词典/LLM 批量抽 |
| `root[]` + `rootSummary` | 词根 tab 空 | 从「词根助记」自由文本结构化（LLM） |
| `exams[].en` + `src` | 真题浮层空 | 从真题原文抽句 + 标来源（LLM/脚本） |
| `meaningDetails` | **例句轮播卡废掉** | 按词义聚合例句（词书+柯林斯+听力），LLM 生成 `enDef`/`pattern` |
| `syllable` | 拆分助记关 | 轻量生成 |
| 近反义释义 | 只剩词，丢了「有缺陷的」这种释义 | 重抓 |

---

## 8. 壳 RPC 能力（模板可调）

web_session 模板靠这几条自己开车（`webview_bridge.dart`）：

| RPC | 入参 | 返回 | 用途 |
|---|---|---|---|
| `session.plan` | — | `{units:[{cards:[{id,word,modes}]}], ...}` | **拿当前这本书的队列**（不是全库！） |
| `card.get` | `{id}` | `{card:{id,fields,state,kv,...}}` | 取卡内容 |
| `card.due` | `{bookId?,limit?}` | `{ids,count}` | 复习队列（到期） |
| `card.new` | `{bookId?,limit?}` | `{ids,count}` | 新卡队列（**无 bookId = 全库**，慎用） |
| `review.commit` | `{id,rating}` | `{ok,state}` | 交评级（唯一动调度的入口） |
| `session.save` | `{workflow,cursor,session}` | `{ok}` | 断点 |
| `FC.tts(text,opts)` | — | — | 发音 |
| `FC.fs.read/write` | — | — | 笔记文件（`books/_notes/notes.json`） |

> ⚠️ `card.new` 不传 `bookId` 会跨书抓卡（踩过：打开测试书蹦出别本书的 `portray`）。
> 队列一律走 `session.plan`。

---

## 9. 与 test_incident 现有样例的差异（待修）

`books/test_incident/ch_0001.json` 是上一版模板 `normCard` 的输出形状，
**不完全符合本契约**，需修：

| 现样例 | 本契约 | 改法 |
|---|---|---|
| `root: {items:[...], summary:"..."}` | `root: [...]` + `rootSummary` | 拆开 |
| `derivatives[].cn: string[]` | `derivatives[].cn: string` | 合并成 `；` 连的字符串 |
| `senses[].primary: true` | 无此字段 | 删；主词义 = 第一个 sense 的第一个 cn |
| `exams[].level` | `level?` 可选 | 保留（扩展） |
| `tags: [...]` | 无此字段 | 删或另存扩展 |
| `blocks[].render` | 无此字段（v3 是 `type`） | 若模板不渲染则删 |

---

## 10. 待拍板（影响 adapter 与模板）

1. `phonetic` 只留一串（us），还是要 `phonetic_us`/`phonetic_uk` 双存？
   → 建议：主字段 `phonetic`（模板读），us/uk 作扩展键留着。
2. `derivatives[].cn` 用 `string`（源码）还是 `string[]`（更灵活）？
   → 建议：跟源码 `string`，模板内部需要再拆自己拆。
3. `exams` 的 `level` 要不要真驱动筛选条（源码里筛选条是硬编码的摆设）？
   → 建议：先存着，不驱动。
4. 老书 adapter 放**壳（Dart）** 还是**模板（JS normCard）**？
   → 建议：模板 `normCard` 兜（改 JS 不用重编 APK），壳只喂原始。
