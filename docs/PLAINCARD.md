# plaincard_v1 · 通用卡模板

> 服务对象：**知识点卡**，不是单词。
> 引擎：`srs_basic`（SM-2）。模板自带流程（`web_session: true`），壳不排课。

---

## 1. 为什么要有第二套引擎

单词卡的调度核心是「**词**」：一个词一个状态，三档自评，粒度到「天」就够。

知识点卡的核心是「**一张张卡**」：公式、概念、政治要点、英语长难句。
它和单词的差别不是皮肤，是**调度语义**：

| | `language`（FSRS-lite） | `srs_basic`（SM-2） |
|---|---|---|
| 管什么 | 词 | 卡 |
| 评分档位 | 3（again / hard / good） | 4（again / hard / good / easy） |
| 内部模型 | 连续的可提取概率 | 离散难度 + 学习步 |
| 到期粒度 | **日** | **分钟**（1min / 10min 学习步） |
| 状态 | `stability / difficulty / reps` | `phase / step / ease / interval` |

**它们不能合并。** FSRS 的 due 会被截断到「天」，而 SM-2 的 1 分钟学习步
一旦被塌成「明天见」，新卡第一次学就变成次日复习 —— 学习步这件事整个作废。

所以是**双引擎并存**，各跑各的，不换算、不合并：

```
app/lib/services/scheduler.dart       FSRS-lite   （词）
app/lib/services/scheduler_sm2.dart   SM-2 variant（卡）
webpreview/sm2.js                     JS 1:1 镜像（浏览器预览用）
app/lib/services/card_store.dart      同一份文档里 card_states / sm2_states 共存
```

改 `scheduler_sm2.dart` 或 `sm2.js` **任一边，必须同步另一边**，并跑：

```bash
node webpreview/sm2_test.js      # 45/45
```

---

## 2. 字段契约

`fields_order` 里的这些字段是模板认识的。全部按**宽容读取**处理 ——
缺字段给空值，不报错（卡组是手写/脚本生成的，字段缺一半是常态）。

| 字段 | 说明 |
|---|---|
| `type` | `qa` / `cloze` / `mask` / `point` / `sentence`。缺省 `qa`。只影响徽章和默认排布 |
| `front` | 正面：问题 / 题目。别名 `question` / `q` |
| `back` | 背面：答案 / 要点。别名 `answer` / `a` |
| `detail` | 可选。展开讲解、易错点。「详解」按钮点开才显示 |
| `cloze` | 挖空正文（`type: cloze`） |
| `cover` | 遮盖正文（`type: mask`） |
| `media` | `[{kind:"image"\|"audio", src, caption}]`，或直接给一个字符串（当图片） |
| `tags` | 数组或逗号分隔字符串。最多显示 4 个 |
| `source` | 出处，右上角小字 |
| `mnemonic` | 助记，展开时以琥珀色边条显示 |
| `html` | **逃生舱**。非空则整个内容区交给它，下面的结构化槽位全部不渲染 |

---

## 3. 内容作者的三档自由

### ① 结构化原语（90% 的卡）

```json
{ "type": "qa", "front": "什么是根切？", "back": "范成法加工时…", "tags": ["机械设计"] }
```

### ② markdown-lite（写在 `front` / `back` / `detail` 里）

| 写法 | 效果 |
|---|---|
| `**粗体**` | 加粗 |
| `==高亮==` | 青色荧光笔 |
| `` `代码` `` | 等宽底纹 |
| `- 项` | 无序列表 |
| `1. 项` | 有序列表 |
| 空行 | 分段 |

单行**不会**被包 `<p>` —— 否则一句话被挖空切成几段后，每段都变成块级元素、
整句硬断成三行。多行才走段落 / 列表。

### ③ HTML 逃生舱

`html` 字段非空时，模板把整个内容区交给它。公式照样渲染，顶栏 / 翻面 /
四档评分还是模板的 —— 只换内容。

**只把「排版本身很有信息量」的卡写成 HTML**（对比表、流程图）。
普通的问答继续用 `front`/`back`：内容和样式一耦合，换模板就不是换皮了。

---

## 4. 挖空与遮盖

复用 **Anki 同款语法** —— 生态里几十万张挖空卡都是这个格式，迁移脚本一行不用改。

| 写法 | 卡型 | 效果 |
|---|---|---|
| `{{c1::答案}}` | 任意 | 挖空，点击揭示 |
| `{{c1::答案::提示}}` | 任意 | 提示常显，答案藏 |
| `[[文字]]` | 任意 | 黑条遮盖，点击揭示 |
| `[[文字::提示]]` | 任意 | 同上，带提示 |

`c1`/`c2` 的分组语义**暂不使用**：一张卡 = 一个调度单元，而不是「一个空 =
一个调度单元」。所以同一张卡的所有空在翻面时一起揭示。

---

## 5. 公式（KaTeX）

所有文本字段都过一遍 KaTeX —— 公式是**能力**，不是卡型。

| 定界符 | 模式 |
|---|---|
| `$…$` | 行内 |
| `$$…$$` | 独立成行（居中） |
| `\(…\)` `\[…\]` | LaTeX 传统写法，同样支持 |

定界符在 `manifest.json` 的 `math.delimiters` 里声明，壳通过 `session.plan`
递给模板 —— **模板作者可以改，不用碰 Dart**。

### 字体怎么进 WebView

模板是 `loadHtmlString(html)` 灌进去的，**页面没有 baseUrl**，
`url(fonts/x.woff2)` 这种相对路径一定 404。三条路里选了第三条：

1. ~~CDN~~ → 自习室没网就白板
2. ~~`loadHtmlString(baseUrl:)`~~ → 要改壳、要保证字体被铺到公共目录、还要处理没授权时的私有兜底目录
3. **字体 base64 内嵌** → KaTeX 的 woff2 全集只有 296 KB，base64 后 ~395 KB

`tools/vendor_katex.py` 负责把 `katex.min.css` 里的 `src:` 改写成 data-uri，
顺手删掉 `woff` / `ttf` 两条回退（现代 WebView 全支持 woff2 子集，
留着只是让 CSS 白白大一倍）。

产物落在模板目录的 `vendor/` 下，`manifest.vendor` 声明，**壳负责读成字符串
内联进页面**（`<script src>` 同样是相对路径 404 的坑）。

---

## 6. 图片

- `data:` / `https:` 开头 → 模板直接用
- 相对路径（如 `media/gearbox.png`，相对 `Documents/Flashcard/`）
  → 调 `media.get` 让壳读成 data-uri

`media.get` 的路径规范化 + 白名单跟 `fs.*` 同一套边界，上限 6MB。

---

## 7. 布局契约（「问答卡不好排」的解法）

```html
<header class="pc-head">      固定：标签 / 出处
<main   class="pc-body">      可滚：内容区
<footer class="pc-actions">   固定：翻面 / 四档自评
```

关键在于这两行 CSS：

```css
.pc-body  { display: grid;  overflow-y: auto; }   /* 唯一会滚的部分 */
.pc-inner { margin: auto; }                       /* 短内容居中、长内容从头滚 */
```

flex 的 `justify-content: center` 在内容溢出时会把**顶部**裁掉 ——
滚动条拉到最上面也看不全第一行。`grid` + `margin:auto` 没有这个病。

效果：答案短的卡垂直居中好看，答案长的卡（政治大题要点）正常从第一行开始滚，
而**按钮永远在底部**，不会被内容挤走。

---

## 8. 流程归 `workflow.js`

模板声明 `web_session: true` 之后，壳不排课、不挂卡、不推进，
只执行模板发来的指令。`workflow.js` 干这些：

1. `session.plan` → 拿 `book / engine / math` 定身份
2. `session.load` → 同一本书就续断点，否则重新排队
3. 排队：`card.due`（到期，分钟粒度）→ `card.new`（按今日剩余额度截断）
4. 出牌：`card.get` 取字段 → `PC.mount` 渲染；`review.preview` 写按钮小字
5. 交卷：`review.commit`（四档 → SM-2）→ `stats.markDone` 记今日
6. `again` 的卡按学习步塞回**队尾**（本场再见一次，最多 3 次，防死循环）
7. `web.progress` / `web.finish` / `session.save` 断点

「今日还能塞几张新卡」由模板算（`stats.get` 的 `card_limit − card_done`），
不由壳算 —— 因为「今天算多少个」是流程问题。

---

## 9. 自测

```bash
node webpreview/plaincard_test.js    # 38/38  渲染层纯函数
node webpreview/sm2_test.js          # 45/45  SM-2 内核
```

`plaincard_test.js` 里有一类是**红线测试**，比如：

> 「挖空的答案在文档里只能出现一次，而且必须在 `.pc-val` 里」

因为一旦答案同时出现在普通文本节点里，就等于把答案写在脸上；
而这种错误在手机上只是「看着有点怪」，肉眼验收一定会漏。

### 浏览器预览

```bash
python3 -m http.server 8080        # 仓库根目录
# 打开 http://localhost:8080/webpreview/general.html
```

`webpreview/general.js` 在浏览器里 **1:1 扮演 Flutter 壳**（RPC / SM-2 存储 /
会话计划 / 进度上报），iframe 里加载的是 `templates/plaincard_v1/` 下的
**真模板真 workflow**，不是复制粘贴的副本 —— 改模板刷页面就生效，
不存在两份代码漂移。

---

## 10. 演示卡组

`decks/general_demo.json`（25 张，四章）：

- 机械设计 · 概念卡 10（含挖空、遮盖、要点、内联 SVG 图片）
- 政治 · 知识点 8（政治大题那种要点排版）
- 英语 · 长难句 3
- 高等数学 · 公式卡 4（KaTeX 公式 + HTML 逃生舱示例）

---

## 11. 目录

```
templates/plaincard_v1/          ← 真源（CI 同步进 app/assets/）
├── manifest.json                engine / fields / srs 参数 / math / vendor
├── template.html                三层 DOM 骨架
├── style.css                    主题 + 布局契约
├── script.js                    渲染层（字段 → DOM，不认识队列和调度）
├── workflow.js                  流程层（排队 / 交卷 / 断点）
└── vendor/                      KaTeX（由 tools/vendor_katex.py 生成，别手改）
    ├── katex.min.js
    ├── auto-render.min.js
    ├── katex.css                字体已 data-uri 化
    └── VERSION.txt
```
