# flashcard · Web-first 大改造计划

> **状态**：待执行（2026-09-16 定稿，等考研节奏允许时推进）
> **前置**：2026-09-15 SPA 化重构、2026-09-16 拼写轮落地
> **一句话**：把「壳定义 workflow」翻过来，变成「Web 定义 workflow，壳只提供能力」。
> **不碰的东西**：FSRS 数学、TTS 引擎、UI 样式。这次只动**架构边界**。

---

## 一、为什么要改：现状的三处越权

### 1.1 壳越权定义 workflow

现在整个学习流程焊死在 Dart 里：

- `StudySession`（`models/study_session.dart`，509 行）定义阶段机：
  `passage → passageCloze → learn → choice/cloze → graduated`
- 轮次、重测池、毕业判定、`_modesFor` / `_allPassed` / `_startMode` 全在 Dart
- `StudyPlanner`（`services/study_plan.dart`）定义「今天背谁」
- 模板（`templates/bubei_dark/`）只能被动接受 `mountCard()` 灌进来的单卡数据

**后果**：想改学习流程（加一个考法、换个轮次策略、调暂停节奏），必须改 Dart 源码、重新编译 APK。热重载救不了，卡牌包作者完全没权限。这就是我们当初骂 Anki 的毛病，换了个壳又犯了一遍。

### 1.2 拼写轮已经偷跑，造成双 workflow 并存

2026-09-16 早场把拼写轮的循环（三次机会、错词放队尾、循环到全过）整个塞进了模板的 `script.js`（约 260 行 `srPool` 逻辑），Dart 侧只留 `spellPrompt` / `spell` 两个阶段和 `beginSpell()` / `endSpell()` 两个钩子。

结果是：

| 流程 | workflow 在哪 |
|---|---|
| 单选 / 填空重测 | Dart `StudySession` |
| 拼写轮 | 模板 `script.js` |

**同一件事，两套主人。** 这不是设计，这是工期妥协。

附带一个真实隐患：拼写轮状态全在 JS 内存里，用户拼到一半被系统杀后台，进度直接归零；拼错的字母、用掉的提示次数，原生侧一无所知，没法沉淀成学情。

### 1.3 桥是单向管道，不是 API

现在 `window.Flashcard` 只有这些（`services/template_engine.dart` 注入的 glue）：

```
getCard()        → 读预注入的 window.__FLASHCARD_CARD__（同步，切卡才更新）
answer(rating)   → postMessage 单向
tts / ttsSeq / ttsStop
getState(k) / setState(k,v)   → 只绑当前卡
undo / next / prev / ready    → 壳里全是 break;（空桩）
mountCard(json) / onMount(fn) → 壳 → JS 单向推
```

**问题**：

- 只有 push，没有 pull。模板想查「同书其它卡」「当前到期队列」「学情统计」——零接口。
- 调度器对模板黑盒。模板拿不到 `interval` / `due` / `R` / `S`。
- 插件系统（`docs/PLUGINS.md` 的 TTS / LLM provider）只在原生自嗨，模板调不到 `aiExplain` / `aiChat`。
- `undo` / `next` / `prev` 三个桩从没实现。
- 存储只有卡级 KV，没有全局 KV、没有命名空间。

---

## 二、目标架构：Web-first with Native Bridge

### 2.1 核心理念

**壳不定义流程，只提供能力。流程属于卡牌包。**

一句话类比：把壳从「导演」降级成「摄影棚 + 道具组」，剧本由 Web 层自己写。

### 2.2 三层划分

```
┌─────────────────────────────────────────────────────────┐
│ Web 层（模板包）                                          │
│  · workflow.js —— 会话编排 / 队列 / 轮次 / 毕业判定       │
│  · 全部 UI 与交互（现有 script.js + style.css）           │
│  · 拼写轮、语篇流程、自定义考法                            │
│  通过 RPC 调壳，不直接碰存储                              │
└────────────────────────┬────────────────────────────────┘
                         │ 双向 RPC（WebMessageChannel）
┌────────────────────────▼────────────────────────────────┐
│ 桥接层 Bridge                                            │
│  · 请求/响应 RPC（带 id、超时、错误码）                    │
│  · 事件推送（pause/resume/tts.done…）                     │
│  · 不再用字符串拼 JS eval                                  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│ 壳核心 Native Core                                       │
│  · 持久化：SQLite（states / kv / global / session）       │
│  · 调度内核：FSRS 纯函数（只在 Dart，唯一实现）            │
│  · 系统能力：TTS / LLM / 文件 / 通知 / 触感 / 网络         │
│  · 生命周期：pause / resume / 后台保活                     │
└─────────────────────────────────────────────────────────┘
```

### 2.3 三条铁律

1. **壳不定义流程。** 壳里不再有 `StudySession` 阶段机、不再有重测池。壳只暴露「取卡 / 提交评级 / 查状态」这类原子操作。
2. **状态机在 Web 层，但状态必须可持久化、可重放。** 每完成一步调 `session.save()`，杀后台重进能续上。
3. **两样东西绝不进 Web 层：持久化、FSRS。** 前者因为 WebView 会被杀，后者因为纯函数该待在能被单元测试的语言里，不能出现第三份实现。

---

## 三、API 契约设计

### 3.1 从单向管道升级为双向 RPC

```js
// Web → 壳：请求/响应
const card  = await Flashcard.call('card.get',   { id: 'kaoyan_core:ch01:12' });
const due   = await Flashcard.call('card.due',   { limit: 20, bookId: 'kaoyan_core' });
const fresh = await Flashcard.call('card.new',   { limit: 40, bookId: 'kaoyan_core' });
const next  = await Flashcard.call('review.commit', { id, rating: 'good' });
const prev  = await Flashcard.call('review.preview', { id, rating: 'hard' });
await Flashcard.call('state.put', { id, key: 'known', value: true });
await Flashcard.call('session.save', { workflow: 'word_learn', cursor: {...} });

// 壳 → Web：事件
Flashcard.on('lifecycle.pause',  () => saveAll());
Flashcard.on('lifecycle.resume', () => restoreAll());
Flashcard.on('tts.done',         (d) => {});
```

底层实现：Android 用 `WebMessageChannel` 或 `addJavaScriptChannel` + 原生回调注册表（`Map<requestId, Completer>`），彻底告别 `runJavaScript("mountCard('...')")` 这种字符串 eval。

### 3.2 方法清单（按域）

#### card 域
| 方法 | 说明 | 返回 |
|---|---|---|
| `card.get({id})` | 单卡完整数据（字段 + state + kv） | `Card` |
| `card.due({limit, bookId?, chapterId?})` | 到期队列（已学 + 到期，排除标熟） | `CardRef[]` |
| `card.new({limit, bookId?, chapterId?})` | 新卡队列（未学、未标熟） | `CardRef[]` |
| `card.list({bookId, chapterId})` | 章节卡片列表（懒加载整章） | `CardRef[]` |
| `card.byLemma({lemma, bookId?})` | 按 lemma 反查（跨书） | `Card[]` |
| `card.stats({bookId?})` | 学情：已学 / 到期 / 标熟 / 连续天数 | `Stats` |

#### review 域
| 方法 | 说明 |
|---|---|
| `review.commit({id, rating})` | 跑 FSRS → 落盘 → 返回新 `CardState`（含 nextDue） |
| `review.preview({id, rating})` | 只算不写，给「预计下次 X 天后」这类 UI 用 |
| `review.undo()` | 撤销上一次 commit（**把空桩补上**） |
| `review.history({id, limit})` | 该卡评分历史（来自事件日志） |

#### state 域
| 方法 | 说明 |
|---|---|
| `state.get({id})` | FSRS 状态 |
| `state.kvGet({id, key})` / `state.kvPut({id, key, value})` | 卡级 KV（标熟、收藏、笔记） |
| `global.get({key})` / `global.put({key, value})` | **全局 KV**（新）：模板配置、UI 偏好、拼写偏好 |

#### book 域
| 方法 | 说明 |
|---|---|
| `book.list()` | 书架 |
| `book.get({id})` | 书元信息 + 章节目录（index.json） |
| `book.chapter({bookId, chapterId})` | 整章卡片 + 语篇 |

#### session 域（断点续学）
| 方法 | 说明 |
|---|---|
| `session.load()` | 读上次未完成的会话状态（workflow 名 + cursor） |
| `session.save({workflow, cursor})` | 存当前 workflow 进度 |
| `session.clear()` | 会话正常结束，清掉断点 |

#### sys 域（系统能力）
| 方法 | 说明 |
|---|---|
| `sys.tts({text, lang, opts})` | 现有 tts，保留 |
| `sys.ttsSeq({items})` | 顺序朗读 |
| `sys.ttsStop()` | 停止 |
| `sys.ai({prompt, ctx})` | **新增**：唤起已配置的 LLM provider，返回文本 |
| `sys.notify({title, body})` | 系统通知 |
| `sys.haptic({type})` | 触感反馈 |
| `sys.openUrl({url})` | 外链 |

### 3.3 事件清单（壳 → Web）

| 事件 | 触发 |
|---|---|
| `lifecycle.pause` | App 进后台（Web 层立刻 `session.save()`） |
| `lifecycle.resume` | 回前台 |
| `tts.done` / `tts.error` | 朗读结束 |
| `network.change` | 网络变化（未来云同步用） |
| `update.available` | 有新版 |

---

## 四、迁移路线（分阶段，每阶段可独立上线）

> 原则：**每阶段结束时 App 必须能正常背词**，不允许出现中间态坏版本。

### 阶段 0 · 桥接层升级（不动行为，只换管道）
- 引入 RPC 请求/响应机制（requestId + Completer）
- 用 `WebMessageChannel` 或等价方案替换字符串拼 JS eval
- 旧 `window.Flashcard` 方法全部保留为兼容层（内部转成 RPC）
- 补上 `undo` 真实实现（先接 `CardStore` 回滚）

**验收**：现有模板一行不改，全套流程照跑；`mountCard` 白屏隐患消除。

### 阶段 1 · 存储层换 SQLite
- 建表：

```sql
CREATE TABLE card_states (
  card_id TEXT PRIMARY KEY,
  stability REAL, difficulty REAL,
  reps INTEGER, lapses INTEGER,
  due TEXT, last_review TEXT, state TEXT
);
CREATE INDEX idx_card_due ON card_states(due);

CREATE TABLE card_kv (
  card_id TEXT, key TEXT, value TEXT,
  PRIMARY KEY (card_id, key)
);

CREATE TABLE global_kv (
  key TEXT PRIMARY KEY, value TEXT
);

CREATE TABLE session_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  workflow TEXT, cursor TEXT, updated_at TEXT
);
```

- 首次启动检测 `progress.json` / `progress.log.jsonl`，一次性导入 SQLite，旧文件归档
- `CardStore` 抽出接口，SQLite 实现替换 JSONL 实现
- 保留 `progress.json` 作为外部 Agent 只读快照（`status.json` 同义），写由壳负责

**验收**：6000 词库 `card.due` 查询 < 10ms；强杀进程不丢数据。

### 阶段 2 · Query API 上线
- 实现 `card.*` / `state.*` / `global.*` 全套读接口
- 模板开始能主动拉数据（先在 `CardPreviewScreen` 试点）

**验收**：模板里能写出「查同书其它词」的代码。

### 阶段 3 · workflow.js 试点（拿拼写轮开刀）
- 新建 `templates/<id>/workflow.js`，声明这个卡牌包的学习流程
- 把拼写轮的 `srPool` 循环从 `script.js` 搬进 `workflow.js`，状态每步 `session.save`
- 壳侧删掉 `SessionPhase.spellPrompt` / `spell` 和 `beginSpell` / `endSpell` / `_spellCards` 一整套

**验收**：拼到一半杀后台，重进能续上；`StudySession` 里拼写相关代码全删。

### 阶段 4 · StudySession 整体迁移
- `workflow.js` 接管：单元顺序、语篇流程、逐卡学习、重测轮、毕业判定
- 壳只保留 `StudyPlanner` 的**编排建议**能力（`planner.suggest()` 返回「建议今天背哪些」，Web 层可以采纳或改写）
- `ReviewScreen` 退化成「WebView 容器 + 顶栏进度」，不再驱动状态机

**验收**：改 workflow 只需改 `workflow.js`，热重载即生效，不重编译 APK。

### 阶段 5 · 清理
- 删 `StudySession` / `SessionPhase` / `StudyMode.spell`（死枚举）
- 删 `ReviewScreen` 里的 `_session` 驱动逻辑
- 删单向 push 老路径、`__FLASHCARD_CARD__` 预注入机制
- 文档重写：`ARCHITECTURE.md` / `docs/WORKFLOW.md` 按新分层重写

---

## 五、风险与对策

| 风险 | 对策 |
|---|---|
| WebView 杀后台丢 workflow 状态 | 每步操作后 `session.save`；状态设计成幂等可重放 |
| Web 层数据量爆炸（6000 词进 DOM） | 数据留壳，**视图按需 mount**；列表用虚拟滚动 |
| FSRS 出现第三份实现 | 铁律：FSRS 只在 Dart，Web 一律走 `review.*` RPC |
| 迁移期数据损坏 | SQLite 事务 + 迁移前自动快照 + 保留旧文件 N 天 |
| RPC 超时 / 丢消息 | 请求带 id + 超时 + 重试；关键操作幂等 |
| 回归 | 阶段 0-2 全程 feature flag，旧路径可一键切回 |
| JS 调试黑洞 | 阶段 0 顺带做：RPC 层统一日志、错误上报到原生 `SwitchLog` |

---

## 六、验证清单（每阶段必过）

- [ ] 幽灵连击：切卡后 250ms 内点击无效
- [ ] 崩溃落盘：学习中断 → 强杀 → 重进，进度不丢
- [ ] 性能：6000 词 `card.due` < 10ms
- [ ] 热更新：改 `workflow.js` 不重编译，重启 App 生效
- [ ] 双向 RPC：模板能主动查任意卡、任意状态
- [ ] 插件可达：模板能调 `sys.ai`
- [ ] 数据一致：SQLite 与旧 JSONL 导入后逐卡比对一致

---

## 七、和现有 roadmap 的关系

这份 plan 是 **roadmap 的架构底座**。

- roadmap P2「词条库按 lemma 主键」→ 依赖阶段 1 的 SQLite 分表
- roadmap P2「status.json 外部监督快照」→ 阶段 1 顺带做掉
- roadmap P3「文章牌组 article_reader」→ 依赖阶段 3 的 workflow.js（文章流程是另一个 workflow）
- roadmap P3「拼写题 StudyMode.spell」→ 阶段 3 之后，这个枚举该直接删掉，由 workflow.js 定义

**顺序建议**：阶段 0 → 1 → 2 是硬骨头但收益最大，先把底座铺好；阶段 3 拿拼写轮试水，验证 Web-first 可行性；阶段 4 是总攻。

---

## 附：不做什么（划清边界）

- **不动 FSRS 数学。** 参数、公式、`kMaxInterval` 保持现状。
- **不动 TTS 引擎抽象。** `TtsService` / `TtsEngine` 保持。
- **不动 UI 样式。** 这次是管道工程，不是换皮。
- **不做云同步。** 那是另一个 plan。
- **不追求「一次到位」。** 每阶段都能独立跑，随时可停。
