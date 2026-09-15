let cookie = ttsrv.userVars['cookie']

let req = {}
var callback = null
let ws = null // Websocket
let conn_id = null
let sess_id = null
let step = 0 // 0: start, 1: wait_task, 2: wait_session, 3: tts_running
let taskSeq = 0 // 合成任务号，每次 +1
let curTask = 0 // 当前有效任务号；旧任务的回调发现对不上就整帧丢弃

function check() {
    cookie || function () { throw "未设置变量Cookie" }()
}

function md5(str) {
    // 简易 md5 或者用 uuid 生成 device_id 即可，因为在 JS 插件环境可能没有 crypto，我们用伪随机生成 19 位数字 ID
    let s = "";
    for (let i = 0; i < 19; i++) {
        s += Math.floor(Math.random() * 10);
    }
    return s;
}

function id() {
    return md5();
}

function guid() {
    function s4() {
        return Math.floor((1 + Math.random()) * 0x10000).toString(16).substring(1);
    }
    return s4() + s4() + '-' + s4() + '-' + s4() + '-' + s4() + '-' + s4() + s4() + s4();
}

var currentId = id()
function commonParams() {
    let web_tab_id = guid()
    return `&api_app_key=GOqQpfo1fO7slHv8&namespace=VoiceGenie&mode=0&language=zh&browser_language=zh-CN&device_platform=web&aid=497858&real_aid=497858&pkg_type=release_version&device_id=${currentId}&tea_uuid=${currentId}&web_id=${currentId}&is_new_user=0&region=CN&sys_region=CN&use-olympus-account=1&samantha_web=1&version=1.20.1&version_code=20800&pc_version=3.21.6&web_platform=browser&web_tab_id=${web_tab_id}`
}

// Protobuf varint 编解码 JS 实现
function encodeVarint(value) {
    let out = [];
    while (true) {
        let towrite = value & 0x7f;
        value >>>= 7;
        if (value > 0) {
            out.push(towrite | 0x80);
        } else {
            out.push(towrite);
            break;
        }
    }
    return out;
}

function decodeVarint(buffer, pos) {
    let val = 0;
    let shift = 0;
    while (true) {
        let b = buffer[pos];
        pos += 1;
        val |= (b & 0x7f) << shift;
        shift += 7;
        if (!(b & 0x80)) {
            break;
        }
    }
    return { value: val, nextPos: pos };
}

// 正经 UTF-8 编码：把 JS 字符串转成 UTF-8 字节数组
// (旧实现是 UTF-16BE 拆字节，纯 ASCII 时碰巧能用，中文就炸 → 服务端 40000012)
function stringToBytes(str) {
    let out = [];
    for (let i = 0; i < str.length; i++) {
        let code = str.charCodeAt(i);
        // 处理代理对（emoji 等补充平面字符）
        if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
            let next = str.charCodeAt(i + 1);
            if (next >= 0xDC00 && next <= 0xDFFF) {
                let cp = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00);
                out.push(0xF0 | (cp >> 18));
                out.push(0x80 | ((cp >> 12) & 0x3F));
                out.push(0x80 | ((cp >> 6) & 0x3F));
                out.push(0x80 | (cp & 0x3F));
                i += 1;
                continue;
            }
        }
        if (code < 0x80) {
            out.push(code);
        } else if (code < 0x800) {
            out.push(0xC0 | (code >> 6));
            out.push(0x80 | (code & 0x3F));
        } else {
            out.push(0xE0 | (code >> 12));
            out.push(0x80 | ((code >> 6) & 0x3F));
            out.push(0x80 | (code & 0x3F));
        }
    }
    return out;
}

function bytesToString(arr) {
    if (typeof arr === 'string') {
        return arr;
    }
    let str = '', _arr = arr;
    for (let i = 0; i < _arr.length; i++) {
        let one = _arr[i].toString(2),
            v = one.match(/^1+?(?=0)/);
        if (v && one.length == 8) {
            let bytesLength = v[0].length;
            let store = _arr[i].toString(2).slice(7 - bytesLength);
            for (let st = 1; st < bytesLength; st++) {
                store += _arr[st + i].toString(2).slice(2);
            }
            str += String.fromCharCode(parseInt(store, 2));
            i += bytesLength - 1;
        } else {
            str += String.fromCharCode(_arr[i]);
        }
    }
    return str;
}

// 把任意 buffer (ArrayBuffer / Uint8Array / number[] / 平台 Bytes) 统一转成 Uint8Array
function toUint8Array(buffer) {
    if (buffer instanceof Uint8Array) {
        return buffer;
    }
    if (buffer instanceof ArrayBuffer) {
        return new Uint8Array(buffer);
    }
    // 形如 {0: x, 1: y, ..., length: n} 的类数组，或原生数组
    if (typeof buffer === 'object' && buffer !== null) {
        let len = buffer.length;
        if (typeof len !== 'number' || len <= 0) {
            // 兜底：尝试用 byteLength
            len = buffer.byteLength || 0;
        }
        let u8 = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            u8[i] = buffer[i] & 0xff;
        }
        return u8;
    }
    // 数字数组
    if (typeof buffer === 'string') {
        let arr = [];
        for (let i = 0; i < buffer.length; i++) {
            arr.push(buffer.charCodeAt(i) & 0xff);
        }
        return new Uint8Array(arr);
    }
    logger.e("toUint8Array: 无法识别的 buffer 类型: " + (typeof buffer));
    return new Uint8Array(0);
}

// 封装发送的二进制帧
function encodeClientMessage(api_app_key, namespace, event, payload, connection_id) {
    let data = [];

    // Field 2: api_app_key (string)
    let keyBytes = stringToBytes(api_app_key);
    data = data.concat(encodeVarint((2 << 3) | 2));
    data = data.concat(encodeVarint(keyBytes.length));
    data = data.concat(keyBytes);

    // Field 3: namespace (string)
    let nsBytes = stringToBytes(namespace);
    data = data.concat(encodeVarint((3 << 3) | 2));
    data = data.concat(encodeVarint(nsBytes.length));
    data = data.concat(nsBytes);

    // Field 5: event (string)
    let evBytes = stringToBytes(event);
    data = data.concat(encodeVarint((5 << 3) | 2));
    data = data.concat(encodeVarint(evBytes.length));
    data = data.concat(evBytes);

    // Field 6: payload (string/bytes)
    let plBytes = stringToBytes(payload);
    data = data.concat(encodeVarint((6 << 3) | 2));
    data = data.concat(encodeVarint(plBytes.length));
    data = data.concat(plBytes);

    // Field 8: connection_id (string)
    if (connection_id) {
        let connBytes = stringToBytes(connection_id);
        data = data.concat(encodeVarint((8 << 3) | 2));
        data = data.concat(encodeVarint(connBytes.length));
        data = data.concat(connBytes);
    }

    // 在 Websocket 发送时通常需要 ArrayBuffer 或 Uint8Array
    let uint8 = new Uint8Array(data);
    return uint8;
}

// 解析接收到的二进制帧
function parseServerMessage(buffer) {
    let pos = 0;
    let fields = {};
    // 统一转成 Uint8Array 以兼容各插件平台
    let view = toUint8Array(buffer);
    logger.d("parseServerMessage: 收到 " + view.length + " 字节");
    while (pos < view.length) {
        let keyDec = decodeVarint(view, pos);
        let key = keyDec.value;
        pos = keyDec.nextPos;
        let wire_type = key & 0x7;
        let field_num = key >> 3;
        if (wire_type == 0) { // Varint
            let valDec = decodeVarint(view, pos);
            fields[field_num] = valDec.value;
            pos = valDec.nextPos;
        } else if (wire_type == 2) { // Length-delimited
            let lenDec = decodeVarint(view, pos);
            let length = lenDec.value;
            pos = lenDec.nextPos;
            let val = view.subarray(pos, pos + length);
            pos += length;
            fields[field_num] = val;
        } else {
            throw "Unsupported wire type " + wire_type + " at pos " + pos;
        }
    }
    return fields;
}

let PluginJS = {
    "name": "豆包修复版",
    "id": "doubao.com",
    "author": "TTS Server",
    "version": 5,
    'iconUrl': `https://lf-flow-web-cdn.doubao.com/obj/flow-doubao/doubao/web/logo-icon.png`,
    'vars': {
        cookie: { label: "Cookie", hint: "完整的请求头Cookie", loginUrl: 'https://www.doubao.com/chat', binding: 'cookies', ua: "mobile" },
    },

    "onStop": function () {
        // 作废在途任务：旧回调全部失效，关掉它的 ws
        curTask = ++taskSeq
        if (ws != null) {
            try { ws.cancel() } catch (e) {}
            ws = null
        }
        step = 0
    },


    "getAudioV2": function (request, callback2) {
        check()

        // 打断上一次未完成的合成：旧 ws 作废、旧回调失效。
        // 否则上一条词的音频帧会写进本次 callback ——「读成上一个词」的根因。
        curTask = ++taskSeq
        if (ws != null) {
            try { ws.cancel() } catch (e) {}
            ws = null
        }

        let rate = request.rate / 50.0  // 转换成 1.0 左右的倍率
        if (rate <= 0) rate = 1.0;
        let pitch = (request.pitch - 50) / 10.0 // 转换成偏音调

        callback = callback2
        text = request.text
        speaker = request.voice

        req = {
            'text': text,
            'speaker': speaker,
            'rate': rate,
            'pitch': pitch,
        }

        conn_id = null
        sess_id = null
        step = 0
        getAudio(curTask)
    },
}

function getAudio(myTask) {
    if (ws == null) {
        logger.i("init Websocket")
        let url = `wss://frontier-audio-web-ws.doubao.com/api/v2/sami/voicegenie?` + commonParams()
        let headers = {
            "Cookie": cookie,
            "Origin": "chrome-extension://capohkkfagimodmlpnahjoijgoocdjhd",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36 Edg/133.0.0.0"
        }
        ws = new Websocket(url, headers)

        ws.on('close', function (code, reason) {
            if (myTask !== curTask) return
            ws = null
            if (code == 1000) {
                callback.close()
            } else {
                callback.error(reason)
            }
        })

        ws.on('error', function (err, resp) {
            if (myTask !== curTask) return
            ws = null
            console.error(resp.text())
            callback.error(err)
        })

        ws.on('binary', function (buffer) {
            if (myTask !== curTask) return
            try {
                let fields = parseServerMessage(buffer);
                let eventBytes = fields[4];
                let event = eventBytes ? bytesToString(eventBytes) : "";
                let statusCode = fields[5];
                logger.d("binary event=" + event + " status=" + statusCode);

                if (event === "TaskStarted") {
                    let connBytes = fields[1];
                    conn_id = connBytes ? bytesToString(connBytes) : "";
                    logger.i("Received Connection ID: " + conn_id);
                    step = 1;
                    nextStep();
                } else if (event === "SessionStarted") {
                    let sessBytes = fields[2];
                    sess_id = sessBytes ? bytesToString(sessBytes) : "";
                    logger.i("Received Session ID: " + sess_id);
                    step = 2;
                    nextStep();
                } else if (event === "TTSResponse") {
                    let audioBytes = fields[8];
                    if (audioBytes) {
                        // 拷贝成独立 Uint8Array，避免 subarray 引用被复用
                        let len = audioBytes.length;
                        let out = new Uint8Array(len);
                        for (let i = 0; i < len; i++) {
                            out[i] = audioBytes[i];
                        }
                        callback.write(out);
                    }
                } else if (event === "TTSEnded" || event === "TTSSentenceEnd") {
                    logger.i("TTS finished cleanly: " + event);
                    if (ws != null) { ws.cancel(); ws = null; }
                    callback.close();
                } else if (event === "SessionFailed" || (statusCode && statusCode !== 20000000)) {
                    let errMsgBytes = fields[6];
                    let errMsg = errMsgBytes ? bytesToString(errMsgBytes) : "Unknown error";
                    callback.error("SAMI Error (" + statusCode + "): " + errMsg);
                    if (ws != null) { ws.cancel(); ws = null; }
                }
            } catch (e) {
                logger.e("Error parsing binary frame: " + e);
                if (myTask === curTask) callback.error(e);
            }
        })

        ws.on('text', function (msg) {
            if (myTask !== curTask) return
            console.log(msg)
        })

        ws.on('open', function () {
            if (myTask !== curTask) return
            logger.d("open")
            nextStep()
        })

        return
    }

    nextStep()

    function nextStep() {
        if (step === 0) {
            logger.i("Sending StartTask...");
            sendBinary(encodeClientMessage("GOqQpfo1fO7slHv8", "VoiceGenie", "StartTask", "{}"));
        } else if (step === 1) {
            logger.i("Sending StartSession...");
            let session_config = {
                "business": 1,
                "tts": {
                    "speaker": req.speaker,
                    "audio_config": {
                        "bit_rate": 32000,
                        "format": "aac",
                        "sample_rate": 24000
                    },
                    "extra": {
                        "post_process": {
                            "pitch": parseFloat(req.pitch),
                            "speech_rate": parseFloat(req.rate)
                        }
                    }
                },
                "extra": {
                    "enable_latex_tn": true,
                    "disable_markdown_filter": false,
                    "enable_language_detector": true
                }
            };
            sendBinary(encodeClientMessage("GOqQpfo1fO7slHv8", "VoiceGenie", "StartSession", JSON.stringify(session_config), conn_id));
        } else if (step === 2) {
            logger.i("Sending BidirectionalTTS and EndTTS...");
            let tts_payload = { "text": req.text };
            sendBinary(encodeClientMessage("GOqQpfo1fO7slHv8", "VoiceGenie", "BidirectionalTTS", JSON.stringify(tts_payload), sess_id));
            sendBinary(encodeClientMessage("GOqQpfo1fO7slHv8", "VoiceGenie", "EndTTS", "{}", sess_id));
            step = 3;
        }
    }

    function sendBinary(uint8) {
        // 优先尝试直接发送 Uint8Array；若平台只接受 ArrayBuffer，再退回 .buffer
        let ok = false;
        try {
            ok = ws.send(uint8);
        } catch (e1) {
            logger.d("send Uint8Array 失败，尝试 ArrayBuffer: " + e1);
            try {
                ok = ws.send(uint8.buffer);
            } catch (e2) {
                logger.e("send ArrayBuffer 也失败: " + e2);
                ok = false;
            }
        }
        if (!ok) {
            callback.error("send binary message failed")
        }
    }
}


let locales = []
let voices = []
let EditorJS = {
    "getAudioSampleRate": function (locale, voice) {
        return 24000
    },

    "getLocales": function () {
        return locales
    },

    "getVoices": function (locale) {
        let mm = new Map()
        voices.forEach(v => {
            let tag = v.tag_list.map(t => t.tag_value).join("|")
            mm[v.style_id] = {
                name: v.name + " " + tag,
                iconUrl: v.icon.url
            }
        });


        return mm
    },

    // 加载本地或网络数据，运行在IO线程。
    "onLoadData": function () {
        check()
        let url = `https://www.doubao.com/alice/user_voice/recommend?language=zh&browser_language=zh-CN&mode=0&language=zh&browser_language=zh-CN&device_platform=web&aid=586861&real_aid=586861&pkg_type=release_version&device_id=${currentId}&tea_uuid=${currentId}&web_id=${currentId}&is_new_user=0&region=CN&sys_region=CN&use-olympus-account=1&samantha_web=1&version=1.20.1&version_code=20800&pc_version=1.20.1`
        let headers = {
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36 Edg/133.0.0.0"
        }

        function load(type, tab) {
            function verify(data) {
                if (data.code != 0) {
                    throw '获取失败(请尝试清缓存): ' + data.msg
                }
            }

            let filename = `voices_${type}_${tab}.json`
            let data= null 
            if (fs.exists(filename)) {
                data = JSON.parse(fs.readText(filename))
                verify(data)
            } else {
                let body = `{"page_index":1,"page_size":200,"recommend_type":${type},"tab_key": "${tab}"}`
                console.log(body)
                txt = http.post(url, body, headers).text()
                data = JSON.parse(txt)
                verify(data)
                fs.writeFile(filename, txt)
            }

            data.data.ugc_voice_list.forEach(v => {
                voices.push(v)
                console.log(voices[voices.length - 1].name)

                locales.includes(v.language_code) || locales.push(v.language_code)
            })
        }


        load(1, "")
        load(10, "female")
        load(10, "male")
        load(10, "characters")
        load(10, "accent")
    },

    "onLoadUI": function (ctx, linerLayout) {

    },

    "onVoiceChanged": function (locale, voiceCode) {

    }

}
