# flashcard 插件系统

> 一切皆插件：TTS、LLM provider 都走这一套。2026-09-15 落地。

## 1. 目录结构

```
<公共目录>/Flashcard/plugins/
  ├── tts/<插件id>/
  │     ├── manifest.json      清单（必须）
  │     └── plugin.js          脚本（engine = js 时）
  └── llm/<插件id>/
        └── manifest.json
```

- **内置插件**打包在 APK 的 `assets/plugins/` 下（当前：`tts/openai`、`tts/doubao`、`llm/openai`）。
- **用户插件**放公共目录，同名 `id` 会覆盖内置。
- 状态存在 `<公共目录>/Flashcard/plugins.json`（当前选中 + 各插件配置值）。

## 2. manifest.json

```json
{
  "id": "doubao",
  "name": "豆包 SAMI（JS 插件）",
  "type": "tts",                 // tts | llm
  "engine": "js",                // openai-tts | openai-chat | js
  "author": "TTS Server",
  "version": 5,
  "entry": "plugin.js",          // engine=js 时的脚本名
  "defaults": { "audio_format": "aac" },
  "vars": [
    { "key": "cookie", "label": "Cookie", "secret": true },
    { "key": "voice",  "label": "音色 speaker" },
    { "key": "rate",   "label": "语速倍率", "default": "1.0" }
  ]
}
```

`vars` 里每一项就是设置页上的一个输入框，存进 `plugins.json`。

## 3. engine = openai-tts（声明式）

宿主直接 `POST {base_url}/audio/speech`，body：
`model / input / voice / response_format / speed`。配置项即 `vars`：
`base_url / api_key / model / voice / format / speed`。

## 4. engine = js（脚本插件）

跑在内置 QuickJS（`flutter_js`）上，宿主给插件喂这些 API：

| 宿主 API | 说明 |
|---|---|
| `ttsrv.userVars` | 配置值对象（如 `userVars['cookie']`） |
| `logger.i/d/w/e(msg)` | 日志，落 `logs/tts/` |
| `console.log` | 由 flutter_js 自带 |
| `Websocket(url, headers)` | `.on('open'\|'binary'\|'text'\|'close'\|'error')` / `.send()` / `.cancel()`，**支持自定义请求头 + 二进制帧**（浏览器 WebSocket 做不到，只有宿主能做） |
| `fs.exists/readText/writeFile` | 落在 `plugins/.cache/` |
| `http.post/get` | v1 未实现（记日志后跳过） |

插件要实现的入口（同 TTS Server 规范）：

```js
let PluginJS = {
  onStop: function () { /* 打断时 */ },
  getAudioV2: function (request, callback) {
    // request = { text, voice, rate(0~100,50=正常), pitch(0~100,50=正常) }
    // callback.write(Uint8Array)  吐音频字节
    // callback.close()            正常结束
    // callback.error(msg)         失败
  }
};
```

宿主把 `callback.write` 的字节转 base64 过桥，Dart 侧落盘/流式播放。

## 5. 加一个新插件

- **OpenAI 兼容服务**：复制 `tts/openai` 改 `id`/`name`/默认 `base_url` 即可。
- **JS 脚本**：新建目录放 `manifest.json` + `plugin.js`，`engine` 写 `js`。
  也可以 App 里「插件管理 → 安装（选 .js）」，会自动生成一份带 `cookie/voice/rate` 的清单。

## 6. 模板怎么调 TTS（2026-09-20 起）

模板 `script.js` 通过注入的 `window.Flashcard` 调用，**第二参从 lang 升级为 lang 或 options 对象**，老写法完全兼容。

> **壳是执行器，不是判断器。** 「这是单词 / 词组 / 句子」、读不读、存不存、存哪里、怎么存，
> 全部是模板自己的事 —— 模板用下面的参数告诉壳，壳不看文本内容、不猜类别，来什么读什么。
> （2026-09-20 之前壳里有个 `isSingleWord()` 正则在做这个判断，已从壳里删除。）

```js
FC.tts("word");                          // 老写法：当前选中插件，play 缺省 = "stream"

// 新写法：逐条指定
FC.tts("high street", {                  // 词组照样由模板说了算
  plugin: "doubao",      // 用哪个 TTS 插件；"system" = 系统 TTS；缺省 = 当前选中
  voice:  "zh_female_wenroutaozi_v2_mars_bigtts",
  rate:   1.2,           // 语速倍率，1.0 正常
  pitch:  0.9,           // 音调倍率，1.0 正常
  play:   "file",        // 出声方式，见下
  cache:  true,          // 存不存 + 文件名主干，见下
  dir:    "tts",         // 存哪里：cache/<dir>/，缺省 tts
  sidecar: false,        // 怎么存：要不要旁挂 .txt（全文 + 参数）
  ttlDays: 7,            // 存多久（天），缺省永久
  extra:  { style: "chat" }  // 附件参数，原样并进插件 getAudioV2 的 request
});

// 顺序朗读：每条各用各的插件 / 音色 / 策略
FC.ttsSeq([
  { text: "word",     plugin: "doubao",     voice: "A", play: "file",   cache: true  },
  { text: "sentence", plugin: "openai-tts", voice: "alloy", rate: 0.9, play: "stream", cache: false }
]);
```

### 出声方式（play）

| 写法 | 行为 |
|---|---|
| `play: "file"` | 收全整段 →（要存就落盘）→ 文件播放。短音频 / 词条最稳；起播前要等一次完整合成 |
| `play: "stream"` | 引擎字节流直接喂播放器，边收边播；要存就播完搭车落盘。长句 / 语篇首字最快 |
| `play: false`（或 `"none"`） | 只把音频取回来落盘，不出声（后台串行预取）；`cache:false` 时等于什么都不做 |
| 不传 | 等同 `"stream"` |

### 存取（cache / dir / sidecar）

| 写法 | 行为 |
|---|---|
| 不传 | **不落盘** |
| `cache: true` | 落盘 |
| `cache: "name"` | 落盘，文件名主干用 `name` |
| `cache: {name:"x"}` | 同上，对象写法 |
| `cache: false` | 不落盘 |
| `dir` | 存哪里：`cache/<dir>/`，缺省 `tts` |
| `sidecar: true` | 怎么存：额外旁挂 `.txt`（全文 + 参数） |

### 缓存文件名

```
单词：  intensive-zh_female_xxx-3f9c1a2b7d40.aac
长句：  The quick brown fo-zh_female_xxx-9b2e11aa33cc.aac
        The quick brown fo-zh_female_xxx-9b2e11aa33cc.txt   ← 旁挂，存全文 + 参数
```

- 主干：自定义 `cache.name` > 文本本身；长文本只取前 20 字。
- 尾巴：`sha1(plugin|text|lang|voice|rate|pitch|extra)` 前 12 位。
- **判定复用只看 hash，不看文件名**：参数任意一项变了 hash 就变，生成新文件；完全一致才命中。

### 系统 TTS

`plugin: "system"` 直接走 `flutter_tts`，不吃缓存。省略 `plugin` 且没有可用插件时也会自动兜底到它。
