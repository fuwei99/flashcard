# 壳 → 卡牌：原子能力清单（Shell as API）

> **核心理念：壳只出能力，不出流程。**
> 「下一张挂谁、什么时候算背完、什么时候重考」全部归卡牌包里的
> `workflow.js`；壳只提供一个个可以 await 的原子动作。
>
> 判断留在模板、读盘/落盘/调度留在壳 —— 两边都别越界。

调用方式（模板里）：

```js
var r = await window.Flashcard.call('card.get', { id: 'alpha' });
window.Flashcard.post('web.mount', { unit: 0, cardId: 'alpha', mode: 'read' });
```

---

## 1. 会话与计划

| 方法 | 入参 | 返回 | 说明 |
|---|---|---|---|
| `session.plan` | — | `{mode, book, title, engine, math, passageCloze, retestModes, units[]}` | 排好的今日单元序列。**只带决策要的**：`id / word / modes`，不带卡片字段（几百 KB 会炸 WebView）。渲染要的字段用 `card.get` 现取。`book/engine/math` 是给自驱模板定身份用的（去哪本书拉队列、跑哪个内核、公式定界符） |
| `session.save` | `{workflow, cursor, session}` | `{ok}` | 落断点。**只有一份**（单会话模型），杀后台重进原地续上 |
| `session.load` | — | `{workflow, cursor, session}` | 读断点。跨书/跨章脏断点由模板自己判（`savedBelongsToUnit`） |
| `session.clear` | — | `{ok}` | 清断点（本轮正常结束时调） |

## 2. 卡片内容与队列（只读）

> **两套引擎共用这一组端点。** 书/模板的 `engine` 决定背后跑哪个内核：
> `language` → FSRS-lite（管「词」，3 档，日粒度）；
> `srs_basic` → SM-2（管「知识点卡」，4 档，分钟级学习步）。
> 每个方法都可以显式传 `engine`（`sm2`/`srs_basic` 或 `fsrs`/`language`），
> 不传则用本会话的引擎。**没有独立的 `sm2.*` 命名空间** —— 形状一样，
> 差的只是内核，再开一套只会让模板作者记两遍。

| 方法 | 入参 | 返回 | 说明 |
|---|---|---|---|
| `card.get` | `{id, engine?}` | `{card:{id, fields, engine, state, kv}}` | 单卡完整数据，形状与 mount 灌进模板的一致。`state` 字段名不变，内容随引擎 |
| `card.due` | `{limit?, bookId?, engine?}` | `{ids[], count}` | 到期队列（已学 + 到期，按 due 升序）。**不读章节文件**，走 `index.json` 种子 |
| `card.new` | `{limit?, bookId?, engine?}` | `{ids[], count}` | 新卡队列（未学、未标熟） |
| `pool.get` | `{book}` | `{book, count, cards:[{id,word,senses[]}]}` | **整本书的干扰项精简池**。壳读一次 + 缓存；模板不再自己 `fs.list/fs.read` 整本书。改书后调 `book.reload` 让它失效 |
| `book.index` | `{book?}` | `{books:[{book_id,template,count,ids,chapters[]}]}` | 书索引（结构 + id），**不读章节内容** |
| `state.getReview` | `{id, engine?}` | `{is_new,is_learned,due_now?,known,state}` | 单卡调度状态 + 标熟位。模板判「学没学过 / 该不该复习」用。sm2 多一个 `due_now`（比的是**时刻**不是日期） |
| `state.kvGet` / `state.kvPut` | `{id,key(,value)}` | `{}` / `{ok}` | 卡级 KV（笔记 / 收藏 / 自定义标记）。**两套引擎共用一份 KV** |

## 3. 写（唯一会动调度数据的两条路）

| 方法 | 入参 | 返回 | 说明 |
|---|---|---|---|
| `review.commit` | `{id, rating, engine?}` | `{ok, id, engine, rating, state, due_in?}` | 交评级 → 按引擎跑调度 → 落盘。fsrs 收 `again/hard/good`，sm2 收 `again/hard/good/easy`。**非法值直接报错，绝不兜底成 good** |
| `review.preview` | `{id, engine?}` | `{ok, engine, phase, ratings:{again,hard,good,easy}}` | 四档的「下次间隔」预览（按钮上的小字）。**纯计算不落盘** —— 为一个实时预览写盘不值得 |
| `card.markKnown` | `{id, known}` | `{ok,id,known}` | 标熟 / 取消标熟。**只落卡级 KV，不碰调度状态** |
| `stats.markDone` | `{n?, card?}` | `{ok}` | 今日背诵量 +n（默认 1）。壳只出这一个计数入口，**「什么时候算背下一个」归模板** |

> **两条铁律**
> 1. **只有「毕业」才 `review.commit`。** 自评「不认识 / 模糊」时不许提前 commit ——
>    一 commit 这张卡就被写成「已学」、due 推到明天，没考过选词也算背过了。
>    （sm2 例外：它的 `again` 是有语义的「回学习步」，那本身就该 commit。）
> 2. **`review.commit` 不计数。** 计数只认 `stats.markDone`，由模板在毕业那一刻显式调。
>    （历史上壳按 `prev.isNew` 自动 +1，于是「点一下不认识」也能涨今日背词量。）

## 4. 统计与界面

| 方法 | 入参 | 返回 | 说明 |
|---|---|---|---|
| `stats.get` | — | `{today{}, streak_days, word_passed, …}` | 今日 / 累计统计的只读副本 |
| `ui.setChrome` / `ui.getChrome` | `{top}` | `{ok,top}` | 原生顶部栏显隐（落盘，下次启动直接读） |

## 5. 文件与插件（白名单内）

| 方法 | 说明 |
|---|---|
| `fs.info/list/read/write/append/delete/move/copy/mkdir/stat/exists` | 路径相对 `Documents/Flashcard/`，规范化后必须落在白名单内；写用 `.tmp` + rename 原子替换 |
| `media.get` | `{path}` → `{ok, mime, bytes, data_uri}`。本地图片转 data-uri。**卡里不能写相对路径的 `<img src>`** —— 模板是 `loadHtmlString` 灌进去的、页面没有 baseUrl，相对路径一定 404（跟 KaTeX 字体同一个坑）。上限 6MB |
| `book.reload` | 模板改完书文件后让壳丢掉缓存（书列表 + 干扰池） |
| `plugin.list/call` | 通用插件系统（工具插件 / TTS 插件） |

## 6. 壳 → Web（事件）

| 事件 | 载荷 | 说明 |
|---|---|---|
| `web.start` | — | 骨架页就绪，模板可以拉 `session.plan` 自己开跑 |
| `web.spellDecision` | `{go}` | 壳对「要不要拼写」的回执（老路径兼容） |
| `lifecycle.pause` / `lifecycle.resume` | — | 进后台 / 回前台。模板收 `pause` 立刻 `session.save` |

## 7. Web → 壳（不需要回执的指令）

| type | 载荷 | 说明 |
|---|---|---|
| `web.mount` | `{unit, cardId, mode, index, total, round}` | 要挂某张卡 / 某个语篇。**`index/total` 语义 = 本单元已背完 N / 共 M**（进度条口径），不是「第几张 / 本轮几张」 |
| `web.progress` | `{phase, done, total, graduated}` | 原生顶部进度条 |
| `web.finish` | `{graduated}` | 本轮清空 |
| `answer` | `{rating}` | 评分（web 驱动模式下由 workflow 接管，不再发这条） |
| `tts` / `ttsSeq` / `ttsStop` | `{text,lang,…}` / `{items[]}` | 朗读。**存取策略（cache / play / dir / sidecar）由模板声明**，壳不推断 |