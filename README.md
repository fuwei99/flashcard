# flashcard

> 卡牌即网页的极简背单词壳。
> 原生只干三件事：**发牌、收 API 回调、存调度结果**。
> 翻面、按钮、朗读、评分——全部由卡牌自己的 HTML/CSS/JS 说了算。

---

## 为什么要造这个轮子

AnkiDroid 的毛病不在算法，在**架构**：

- 卡牌被塞进一个固定模板系统里，原生 UI 的「认识/模糊/忘记」按钮焊死在界面上，卡牌作者想加个自定义按钮、换个交互，得去改原生代码。
- 一个 `.apkg` 动辄几百兆，大量重复的 CSS/JS/模板被每张卡重复打包。
- TTS、音频、扩展交互全要绕 Anki 自己的接口，不能直接调系统能力。

`flashcard` 反过来：**卡牌就是一个纯 WebView 页面**，原生只提供一组 JS API。
卡牌想画成什么样、放几个按钮、按钮点了触发什么，全在卡牌里定。

---

## 架构

```
┌─────────────────────────────────────────────┐
│              Flutter 原生壳                  │
│  ┌───────────────┐   ┌───────────────────┐  │
│  │  DeckRepository│   │   CardStore       │  │
│  │  读卡组/模板   │   │  调度状态 + 私有KV │  │
│  └───────┬───────┘   └────────┬──────────┘  │
│          │                    │              │
│  ┌───────▼────────────────────▼──────────┐  │
│  │           WebViewBridge               │  │
│  │  组装 HTML · 注入 glue · 收消息        │  │
│  └───────┬────────────────────┬──────────┘  │
│          │  loadHtmlString    │ FCChannel    │
│  ┌───────▼────────────────────▼──────────┐  │
│  │            WebView（全屏）             │  │
│  │   ┌─────────────────────────────────┐ │  │
│  │   │  卡牌包: template.html+css+js   │ │  │
│  │   │  window.Flashcard.getCard()     │ │  │
│  │   │  window.Flashcard.answer(...)   │ │  │
│  │   │  window.Flashcard.tts(...)      │ │  │
│  │   └─────────────────────────────────┘ │  │
│  └───────────────────────────────────────┘  │
│  ┌───────────────────────────────────────┐  │
│  │  Scheduler (FSRS-lite, Dart)          │  │
│  └───────────────────────────────────────┘  │
│  ┌───────────────────────────────────────┐  │
│  │  flutter_tts / just_audio             │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

---

## 卡牌包格式

一个卡牌包 = 一个目录：

```
bubei_dark/
├── manifest.json     # 元信息：id/name/fields/render_mode/tts
├── template.html     # 卡牌 DOM，用 {{field}} 占位
├── style.css         # 卡牌样式，全屏 WebView 里随便造
├── script.js         # 卡牌交互：翻面、按钮、调 API
└── (data.json)       # 可选：卡组数据（也可分离）
```

`manifest.json` 里 `files` 指定三段资源，`fields` 声明字段顺序，
`render_mode: "placeholder"` 表示用占位符渲染。

**卡组和模板解耦**：一个卡组 `"template": "bubei_dark"` 就绑定了模板。
换皮 = 换模板目录，数据一个字不用动。

---

## 卡牌 API 契约（`window.Flashcard`）

卡牌脚本只认识这一组函数，不关心原生是谁：

| API | 说明 |
|---|---|
| `getCard()` | 同步返回 `{fields, state, index, total}` |
| `answer('again'\|'hard'\|'good')` | 提交评分，原生据此跑调度 |
| `tts(text, lang)` | 调系统 TTS 朗读 |
| `getState(key)` / `setState(key, value)` | 卡牌私有 KV，持久化 |
| `undo()` / `next()` / `prev()` | 导航 |
| `ready()` | 告诉原生壳渲染完成 |

**关键设计**：`getCard()` 是同步的——原生在 `loadHtmlString` 之前就把卡片数据
注入成 `window.__FLASHCARD_CARD__`，所以卡牌脚本启动时立刻能拿到数据，
不用异步请求。`answer()` 等动作是异步的，通过 `FCChannel.postMessage` 发给原生。

---

## 三档评分 → 调度

| 按钮 | 评级 | FSRS rating | 行为 |
|---|---|---|---|
| 忘记 | again | 1 | 稳定性惩罚性下调，当天重学 |
| 模糊 | hard | 2 | 稳定性小幅上调 |
| 记得 | good | 3 | 稳定性正常上调 |

调度内核是 FSRS-4.5 简化版，`core/fsrs.py`（Python 参考实现）
和 `app/lib/services/scheduler.dart`（Dart 生产实现）逻辑一一对应。

---

## 书本结构（书 → 章 → 页）

**不是 Anki 那种树状牌组。** 一本卡组就是一本「书」，像实体书一样翻：

```
书架
 └── 📖 考研英语核心词            一本书
      ├── 📁 第一章 · 高频核心词   章节目录（文件夹）
      │    ├── 1  intensive      每一页 = 一张卡
      │    ├── 2  subtle
      │    └── ...
      └── 📁 第二章 · 进阶与熟词生义
           └── ...
```

- 书**有章** → 点进去先看到章节目录（文件夹）
- 书**没章** → 点进去直接看到页面列表
- **每页都有自己的名字**：单词卡就用单词本身当标题
- 页面列表顶部选 **顺序背诵 / 乱序背诵** 进背诵模式
- 背诵页顶部显示 **已背 X / Y**（本组进度）+ **今日 X / 目标**

书本 JSON 格式：

```json
{
  "book_id": "kaoyan_core",
  "title": "考研英语核心词",
  "template": "bubei_dark",
  "fields_order": ["word", "..."],
  "chapters": [
    { "chapter_id": "ch01", "title": "第一章 · 高频核心词", "cards": [...] },
    { "chapter_id": "ch02", "title": "第二章 · 进阶与熟词生义", "cards": [...] }
  ]
}
```

没有章节时，去掉 `chapters`，把卡片直接放顶层 `cards` 数组即可。

---

## 设置界面

书架右上角齿轮 → 设置页：

- **每日背诵量**：滑块 5~200，或点预设 10 / 20 / 30 / 50 / 80 / 100
- **今日进度**：已背多少、一键重置
- 跨天自动归零

---

## 目录结构

```
flashcard/
├── README.md
├── ARCHITECTURE.md
├── core/
│   └── fsrs.py              # FSRS-lite 参考实现 + 自测
├── decks/
│   └── kaoyan_20.json       # 20 词考研测试牌组
├── templates/
│   └── bubei_dark/          # 不背单词暗黑极简模板
├── webpreview/
│   ├── index.html           # 浏览器预览壳（1:1 模拟原生 API）
│   └── serve.sh             # 起静态服务
├── app/                     # Flutter 原生壳
│   ├── pubspec.yaml
│   ├── assets/              # decks + templates 打包进 app
│   └── lib/
│       ├── main.dart
│       ├── models/deck.dart
│       ├── screens/
│       │   ├── deck_list_screen.dart
│       │   └── review_screen.dart
│       └── services/
│           ├── scheduler.dart
│           ├── template_engine.dart
│           ├── deck_repository.dart
│           ├── card_store.dart
│           └── webview_bridge.dart
└── reference/project/       # 参考项目（Anki-Android, No_back_french）
```

---

## 立刻看效果（不用装 Flutter）

```bash
cd flashcard
bash webpreview/serve.sh 8080
# 浏览器打开 http://localhost:8080/webpreview/
```

预览壳用 `localStorage` 存进度、`Web Speech API` 做 TTS，
交互和真实 Flutter 壳里一模一样。

---

## 跑 Flutter 壳

```bash
cd app
flutter pub get
flutter run          # 接安卓机
flutter build apk    # 出安装包
```

---

## 待办 / 路线

- [ ] 卡组包 `.fcpkg`（zip）导入导出
- [ ] 音频字段接 `just_audio`
- [ ] sqflite 替换 shared_preferences（大卡组性能）
- [ ] FSRS 参数可调（目标保留率、最大间隔）
- [ ] 云同步（可选，WebDAV）
