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
