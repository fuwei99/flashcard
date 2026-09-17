// 有道词典 · 宿主插件
// ---------------------------------------------------------------
// 壳只给原语（logger / http / kv / registerPlugin），业务全在这。
// 换 key、改解析、加字段 —— 改这个文件就行，不用动壳、不用重编 APK。
//
// 依赖宿主原语：
//   kv.get(key) / kv.set(key, val)      存 appKey / appSecret
//                                       （落 Flashcard/plugins/youdao/kv.json）
//   http.post(url, {contentType, body}, cb)
//
// 有道智云 v3 签名：sha256(appKey + input + salt + curtime + appSecret)
//   input = q 长度 <= 20 ? q : q[:10] + len(q) + q[-10:]

/* ---- SHA-256（纯 JS，QuickJS 没有 WebCrypto）---- */
var _K = [
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
];

function _sha256(s) {
  var H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  function rr(x, n) { return (x >>> n) | (x << (32 - n)); }

  // UTF-8
  var bytes = [];
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) { bytes.push(c); }
    else if (c < 0x800) { bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63)); }
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      var n2 = s.charCodeAt(++i);
      var cp = 0x10000 + ((c - 0xd800) << 10) + (n2 - 0xdc00);
      bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63),
                 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    } else {
      bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
  }
  var bl = bytes.length;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  bytes.push(0, 0, 0, 0);                       // 长度高 32 位（我们的量级永远为 0）
  bytes.push((bl >>> 24) & 255, (bl >>> 16) & 255, (bl >>> 8) & 255, bl & 255);

  for (var off = 0; off < bytes.length; off += 64) {
    var w = new Array(64);
    for (var a = 0; a < 16; a++) {
      w[a] = (bytes[off + a*4] << 24) | (bytes[off + a*4 + 1] << 16)
           | (bytes[off + a*4 + 2] << 8) | bytes[off + a*4 + 3];
    }
    for (var b = 16; b < 64; b++) {
      var s0 = rr(w[b-15], 7) ^ rr(w[b-15], 18) ^ (w[b-15] >>> 3);
      var s1 = rr(w[b-2], 17) ^ rr(w[b-2], 19) ^ (w[b-2] >>> 10);
      w[b] = (w[b-16] + s0 + w[b-7] + s1) | 0;
    }
    var h0=H[0],h1=H[1],h2=H[2],h3=H[3],h4=H[4],h5=H[5],h6=H[6],h7=H[7];
    for (var c2 = 0; c2 < 64; c2++) {
      var S1 = rr(h4,6) ^ rr(h4,11) ^ rr(h4,25);
      var ch = (h4 & h5) ^ (~h4 & h6);
      var t1 = (h7 + S1 + ch + _K[c2] + w[c2]) | 0;
      var S0 = rr(h0,2) ^ rr(h0,13) ^ rr(h0,22);
      var maj = (h0 & h1) ^ (h0 & h2) ^ (h1 & h2);
      var t2 = (S0 + maj) | 0;
      h7=h6; h6=h5; h5=h4; h4=(h3+t1)|0; h3=h2; h2=h1; h1=h0; h0=(t1+t2)|0;
    }
    H[0]=(H[0]+h0)|0; H[1]=(H[1]+h1)|0; H[2]=(H[2]+h2)|0; H[3]=(H[3]+h3)|0;
    H[4]=(H[4]+h4)|0; H[5]=(H[5]+h5)|0; H[6]=(H[6]+h6)|0; H[7]=(H[7]+h7)|0;
  }

  var out = '';
  for (var d = 0; d < 8; d++) {
    for (var e = 3; e >= 0; e--) {
      var by = (H[d] >> (e * 8)) & 255;
      out += (by < 16 ? '0' : '') + by.toString(16);
    }
  }
  return out;
}

function _sign(q, salt, curtime, appKey, appSecret) {
  var len = q.length;
  var input = len <= 20 ? q : (q.substring(0, 10) + len + q.substring(len - 10));
  return _sha256(appKey + input + salt + curtime + appSecret);
}

/* ---- 有道返回 → 模板要的 dictEntry 形状 ---- */
function _normalize(j) {
  var basic = j.basic || {};
  var phonetic = basic['us-phonetic'] || basic['phonetic'] || '';
  var senses = [];
  var ex = basic['explains'];
  if (ex && ex.length) {
    for (var i = 0; i < ex.length; i++) {
      var s = String(ex[i]).trim();
      if (!s) continue;
      var m = s.match(/^([a-zA-Z]+\.)\s*(.+)$/);
      if (m) senses.push({ pos: m[1], cn: m[2] });
      else senses.push({ pos: '', cn: s });
    }
  }
  if (!senses.length && j.translation && j.translation.length) {
    for (var t = 0; t < j.translation.length; t++) {
      var ts = String(j.translation[t]).trim();
      if (ts) senses.push({ pos: '', cn: ts });
    }
  }
  var examples = [];
  if (j.web && j.web.length) {
    for (var w = 0; w < j.web.length && examples.length < 3; w++) {
      var it = j.web[w] || {};
      var k = String(it.key || '').trim();
      var v = (it.value && it.value[0]) || '';
      if (k && v) examples.push({ en: k, cn: String(v), src: '网络释义' });
    }
  }
  return {
    word: String(j.query || ''),
    phonetic: phonetic,
    level: '',
    senses: senses,
    collocations: [],
    examples: examples,
    fromApi: true,
    source: 'youdao'
  };
}

registerPlugin({
  id: 'youdao',
  name: '有道词典',
  methods: {
    lookup: function (args, cb) {
      var q = String((args && (args.w || args.word)) || '').trim();
      if (!q) { cb('空词'); return; }
      var appKey = kv.get('appKey') || '';
      var appSecret = kv.get('appSecret') || '';
      if (!appKey || !appSecret) {
        cb('未配置有道 appKey / appSecret（设置页填写）');
        return;
      }
      var salt = String(Date.now());
      var curtime = String(Math.floor(Date.now() / 1000));
      var sgn = _sign(q, salt, curtime, appKey, appSecret);
      var body = 'q=' + encodeURIComponent(q)
        + '&from=en&to=zh-CHS'
        + '&appKey=' + encodeURIComponent(appKey)
        + '&salt=' + encodeURIComponent(salt)
        + '&sign=' + sgn
        + '&signType=v3'
        + '&curtime=' + curtime;
      http.post('https://openapi.youdao.com/api', {
        contentType: 'application/x-www-form-urlencoded',
        body: body
      }, function (err, res) {
        if (err) { cb('网络错误: ' + err); return; }
        var j = res.json();
        if (!j) { cb('响应解析失败'); return; }
        if (String(j.errorCode) !== '0') { cb('有道错误码 ' + j.errorCode); return; }
        cb(null, _normalize(j));
      });
    },
    getConfig: function (args, cb) {
      cb(null, {
        appKey: kv.get('appKey') || '',
        hasSecret: !!(kv.get('appSecret') || '')
      });
    },
    setConfig: function (args, cb) {
      kv.set('appKey', String((args && args.appKey) || ''));
      kv.set('appSecret', String((args && args.appSecret) || ''));
      cb(null, { ok: true });
    }
  }
});
