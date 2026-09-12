# flashcard 架构说明

## 一句话

**原生是壳，卡牌是网页，桥是契约。**

---

## 1. 为什么是 WebView 壳，不是改 Anki

| 维度 | 改 Anki-Android | flashcard 壳 |
|---|---|---|
| 语言栈 | Kotlin + Rust（libanki）双栈 | Dart + HTML/CSS/JS |
| 仓库体量 | 121 MB | 卡牌包几十 KB |
| 卡牌自由度 | 受 Anki 模板系统限制 | 整个 WebView 随便写 |
| 原生按钮 | 焊死在 Reviewer 里 | 不存在，按钮在卡牌内 |
| TTS | 走 Anki 接口 | 直接 `flutter_tts` |
| 编译 | 一次五分钟 | 秒级热重载 |

参考项目：
- `reference/project/Anki-Android` —— Kotlin+Rust，调度器/同步/模板全绑死
- `reference/project/No_back_french` —— Flutter 实现，已验证「Flutter 壳 + FSRS + TTS」路线

---

## 2. 数据流

### 发牌

```
Deck + Template + Card
        │
        ▼
WebViewBridge.buildCardPage()
  ├─ TemplateEngine.render()   占位符替换
  ├─ 注入 window.__FLASHCARD_CARD__
  ├─ 注入 glue JS（定义 window.Flashcard）
  └─ 拼接 css / html / js
        │
        ▼
WebViewController.loadHtmlString(html)
```

### 收评分

```
卡牌脚本: Flashcard.answer('good')
        │  FCChannel.postMessage(JSON)
        ▼
WebViewBridge.handleMessage()
        │
        ▼
Scheduler.review(CardState, Rating)
        │
        ▼
CardStore.putState()  →  shared_preferences
        │
        ▼
UI 层收到 'answer' 消息 → 加载下一张
```

### TTS

```
卡牌脚本: Flashcard.tts('intensive', 'en-US')
        │
        ▼
WebViewBridge.handleMessage() → flutter_tts.speak()
```

---

## 3. 同步 API vs 异步 API 的取舍

**问题**：WebView 的 JS Channel 是异步的，但 `getCard()` 必须同步返回，
否则卡牌脚本启动时拿不到数据，得写一堆回调。

**方案**：数据**预注入**，动作**走 Channel**。

- 读操作（`getCard` / `getState`）→ 原生在组装 HTML 时把数据写进
  `window.__FLASHCARD_CARD__` / `window.__FLASHCARD_KV__`，同步读。
- 写操作（`answer` / `tts` / `setState`）→ `FCChannel.postMessage`，异步。

代价：`setState` 后立刻 `getState` 读到的是内存里的值（已更新），
落盘是异步的——这对卡牌场景完全够用。

---

## 4. 模板引擎

只做两件事，刻意做小：

1. `{{field}}` 变量替换
2. `{{#field}}...{{/field}}` / `{{^field}}...{{/field}}` 条件块

**列表字段不展开**（如 `phrases`）。原因：列表排版是卡牌作者的自由，
引擎强行展开只会限制设计。`script.js` 里读 `getCard().fields.phrases`
自己生成 DOM。

实现三份，逻辑一致：
- `core/template.py`（参考）
- `app/lib/services/template_engine.dart`（生产）
- `webpreview/index.html` 内联（预览）

---

## 5. 调度内核

FSRS-4.5 简化版，三个评分映射到 1/2/3。

核心公式：

```
可提取概率   R(t,S) = (1 + F·t/S)^(-0.5)
下次间隔     I(S)   = S/F · (r^(1/-0.5) - 1)
稳定性增长   S' = S · (1 + e^w8 · (11-D) · S^-w9 · (e^((1-R)·w10)-1) · …)
难度更新     D' = clamp(w7·D0 + (1-w7)·(D - w6·(rating-3)), 1, 10)
```

**踩过的坑**：新卡首次复习后必须把 `state` 从 `new` 翻成 `review`，
否则每次复习都走 `new` 分支、稳定性被重置为初始值，间隔永远卡死。
`core/fsrs.py` 和 `scheduler.dart` 都加了这行。

---

## 6. 扩展点

- **加模板**：`templates/<id>/` 放三件套 + manifest，卡组里 `"template": "<id>"`。
- **加卡组**：`decks/*.json`，`fields_order` 声明字段。
- **加 API**：`WebViewBridge.handleMessage` 加 case，glue JS 里加对应函数。
- **换存储**：`CardStore` 抽象了读写，换 sqflite 只改这一个类。
