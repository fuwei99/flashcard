# bubei_build_v1 · 模板构建源

「不背单词 · 新版复刻」（React + Vite）源码，build 成 flashcard 模板。

## 这是什么

`templates/bubei_build_v1/` 里那三个文件（`script.js` / `style.css` /
`template.html`）是**产物**，不是手写的。真源在这里。

改 UI / 交互 → 改这里的 `src/` → 跑 `build.sh` → 产物更新。

## 构建

```bash
bash templates_src/bubei_build_v1/build.sh
```

产物落到 `templates/bubei_build_v1/`，然后同步设备：

```bash
cp templates/bubei_build_v1/* /mnt/Flashcard/templates/bubei_build_v1/
```

## 相对原参考项目改了什么

源来自 `/mnt/Flashcard/reference/最新不背单词复刻源码/`（React+Vite demo）。
改成模板，动了这几处：

| 文件 | 改动 | 为什么 |
|---|---|---|
| `src/bridge.ts` | **新增** | 壳桥接层：`session.plan` 拉队列、`card.get` 取卡、`review.commit` 交评级、`FC.tts` 发音、`web.progress/finish` 上报 |
| `src/entry.tsx` | **新增** | 挂载到 `#app`，全屏（原 `main.tsx` 套了手机外壳） |
| `src/index.css` | 改 | 加 `#app{position:fixed;inset:0}` 铺满 WebView |
| `src/flashcard/data.ts` | 改 | `DECK` 从硬编码改成空数组 + `setDeck()`；样本挪到 `SAMPLE_DECK`（浏览器直开兜底） |
| `src/flashcard/tts.ts` | 改 | `speak` 转发到 `bridge.speak`（优先壳 TTS） |
| `src/flashcard/dict.ts` | 改 | DECK 词库改成运行时合并（`mergeDeckInto`），因为 DECK 启动才灌入 |
| `src/flashcard/FlashcardApp.tsx` | 改 | 启动 `boot()` 拉队列；`flip`/`markKnownTop`/`pick` 等接 `review.commit`；完成上报 `web.finish`；`castle.jpg` 改 import |
| `vite.config.ts` | 改 | lib 模式出 IIFE、`assetsInlineLimit` 内联图片、`cssTarget: chrome80` 降级 |
| `package.json` | 改 | 加 `lightningcss` 依赖 |

## 壳侧硬要求（build 配置就是为这三条）

1. **`script.js` 必须是普通脚本，不是 module**
   壳 `template_engine.dart` 直接 `<script>$js</script>` 内联。
   → vite `lib` 模式 `formats:["iife"]`。

2. **图片必须内联**
   `loadHtmlString` 是 `about:blank` 起源，没有 baseURL，相对路径图必裂。
   → `assetsInlineLimit: 100MB`。

3. **CSS 不能裸奔现代特性**
   老 Android WebView 不认 `oklch`/`color-mix`/`@property`。
   → `cssTarget: "chrome80"` + lightningcss。
   产物里 `color-mix` 只在 `@supports` 保护块内，外面配了 hex 回退，安全。

## 已知取舍

- 体积：`script.js` ~1MB（含 React 运行时 + 内联图片 base64），
  比手写 vanilla 模板（~26KB）大 40 倍。换来的是视觉/交互 1:1 保真。
- 上游跟随：参考项目更新了，重跑 `build.sh` 即可，不手抄。
