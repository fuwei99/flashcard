/* ============================================================
   workflow.js —— bubei_dark 的学习流程定义（Web-first 试点 · 阶段 3）
   ------------------------------------------------------------
   这一层属于「卡牌包」，不属于壳：
     · 决定「学完一轮要不要拼写、怎么拼、错词怎么办」
     · 每一步调 session.save 落盘，杀后台重进能续上
   壳只提供原子能力（Flashcard.call），不定义流程。

   依赖 script.js 通过 FC.helpers 暴露的渲染原语：
     speak / blankSentence / ttsWord
   ============================================================ */
(function () {
  "use strict";

  var FC = window.Flashcard;
  if (!FC) return;
  var WF = (window.FlashcardWorkflow = window.FlashcardWorkflow || {});
  var H = FC.helpers || {};
  var root = document.querySelector(".fc-root");
  if (!root) return;

  // ---------- 渲染原语（模板提供，缺了就退化）----------
  function speak(text, lang, opts) {
    if (H.speak) { H.speak(text, lang, opts); return; }
    if (FC.tts) FC.tts(text, opts || lang);
  }
  function blankSentence(raw, word) {
    if (H.blankSentence) return H.blankSentence(raw, word);
    return { text: String(raw || ""), answer: String(word || "") };
  }
  var TTS_WORD = H.ttsWord || { cache: true };
  var TTS_SENTENCE = H.ttsSentence || {
    plugin: "doubao", voice: "zh_male_cixingjunyu_uranus_bigtts", cache: false
  };

  // ---------- TTS 预取（阶段 5）：把「后面几张」的单词+例句先落盘 ----------
  // 接口是合并的：play:false = 只取音频落盘、不出声；ttlDays = 存多久（0/缺省=永久）。
  // 壳那边有后台串行队列，会自动让路给正在播放的朗读（豆包单会话，并发会互相 cancel）。
  // 播放时 _speakOne 第一步就查本地文件 —— 命中即秒播，不再等豆包 TTFB。
  var PF_TTL = 7;      // 落盘有效期（天）；设 0 = 永久
  var PF_AHEAD = 12;   // 每次往后看几张
  var _pfDone = {};    // 本次会话已排过的 cardId

  // 重测轮上限：一个单元内最多重来这么多轮，到顶就把剩下的卡放行。
  // 防死循环的最后一道保险（与 Dart 端 study_session.dart 的 kMaxRetestRound 对齐）。
  var MAX_RETEST_ROUND = 10;

  /// 把「播放配置」改成「只要落盘」：不出声 + 强制存 + 带 TTL
  function pfOpts(base, lang) {
    var o = {};
    for (var k in base) {
      if (Object.prototype.hasOwnProperty.call(base, k)) o[k] = base[k];
    }
    o.play = false;
    o.cache = true;
    o.ttlDays = PF_TTL;
    o.lang = lang || "en-US";
    return o;
  }

  function prefetchOne(id) {
    if (!FC.tts || !id || _pfDone[id]) return;
    _pfDone[id] = 1;

    // 单词：plan 里就有，零额外 IO
    var meta = cardMeta(id);
    var word = meta && meta.word;
    if (word) {
      try {
        FC.tts(word, pfOpts(TTS_WORD, "en-US"));
        log("[PF] word " + id + " «" + word + "»");
      } catch (e) { log("[PF] word 抛错 " + id + " " + e); }
    } else {
      log("[PF] 无 word " + id + " meta=" + (meta ? "有" : "null"));
    }

    // 例句：SessionPlan 只带 {id, word, modes}，得单独取卡；取不到就只预取单词
    if (!FC.call) { log("[PF] 无 FC.call，跳过例句"); return; }
    try {
      FC.call("card.get", { id: id }).then(function (r) {
        var c = r && r.card;
        var f = c && c.fields;
        var s = f ? String(f.sentence_en || "").replace(/<[^>]+>/g, "").trim() : "";
        if (!s) {
          log("[PF] 无例句 " + id + " card=" + (c ? "有" : "null") +
              " fields=" + (f ? Object.keys(f).join(",") : "null"));
          return;
        }
        try {
          FC.tts(s, pfOpts(TTS_SENTENCE, "en-US"));
          log("[PF] sent " + id + " «" + s.slice(0, 36) + "»");
        } catch (e) { log("[PF] sent 抛错 " + e); }
      }).catch(function (e) { log("[PF] card.get 失败 " + id + " " + e); });
    } catch (e) { log("[PF] 异常 " + e); }
  }

  /// 往后预取 PF_AHEAD 张：跟着当前队列走，天然按学习顺序
  function prefetchAhead() {
    if (!S || !S.queue || !S.queue.length) return;
    var n = 0;
    for (var i = 0; i < S.queue.length && n < PF_AHEAD; i++) {
      var id = S.queue[i].cardId;
      if (_pfDone[id]) continue;
      n++;
      prefetchOne(id);
    }
    if (n) {
      log("[PF] 本轮排 " + n + " 张 queue=" + S.queue.length +
          " 累计已排=" + Object.keys(_pfDone).length);
    }
  }

  // ---------- JSlogs：模板层诊断输出（落 logs/js/）----------
  function log(msg) { if (FC.log) { try { FC.log("[WF]", msg); } catch (e) {} } }

  // ---------- 会话断点 ----------
  var WF_NAME = "bubei_dark.word";
  var _cursor = null;
  var _timer = null;

  function saveNow(cursor) {
    if (cursor) _cursor = cursor;
    if (!_cursor || !FC.call) return;
    try {
      FC.call("session.save", { workflow: WF_NAME, cursor: _cursor })
        .catch(function () {});
    } catch (e) {}
  }
  function saveSoon(cursor) {
    if (cursor) _cursor = cursor;
    if (_timer) return;
    _timer = setTimeout(function () { _timer = null; saveNow(null); }, 400);
  }
  function clearSaved() {
    _cursor = null;
    if (FC.call) {
      try { FC.call("session.clear", {}).catch(function () {}); } catch (e) {}
    }
  }

  WF.name = WF_NAME;
  WF.saveNow = saveNow;
  WF.saveSoon = saveSoon;
  WF.clear = clearSaved;
  WF.version = "0.1.0";

  // ---------- 生命周期事件（壳 → Web）----------
  if (FC.on) {
    FC.on("lifecycle.pause", function () { saveNow(null); });
  }

  // ============================================================
  //  拼写轮 —— 状态机归 workflow.js（从 script.js 迁入）
  //  一轮走完由原生弹窗触发；三种形态 / 三次机会 / 错词放回队尾。
  //  不写 FSRS：纯加练，循环到全过（或用户点「结束拼写」）。
  // ============================================================
  var SR_MAX_TRIES = 3;
  var srOn = false;
  var srPool = [];        // 待拼条目，队首 = 当前
  var srTotal = 0;
  var srDone = 0;
  var srCur = null;
  var srAnswer = "";
  var srTyped = "";
  var srTries = 0;
  var srRevealed = false;
  var srPending = null;   // 'skip' | 'forget'

  function srQ(sel) { return root.querySelector(sel); }

  function srSnapshot() {
    return { kind: "spell", pool: srPool.slice(), done: srDone, total: srTotal };
  }

  function srStart(items) {
    srPool = (items || []).slice();
    srTotal = srPool.length;
    srDone = 0;
    srPending = null;
    srRevealed = false;
    srOn = srTotal > 0;
    var s = srQ(".fc-spellround");
    if (s) s.hidden = !srOn;
    if (!srOn) { clearSaved(); if (FC.spellDone) FC.spellDone(); return; }
    saveSoon(srSnapshot());
    srNext();
  }

  function srFinish() {
    srOn = false;
    srPool = [];
    srCur = null;
    srPending = null;
    var s = srQ(".fc-spellround");
    if (s) s.hidden = true;
    clearSaved();
    if (FC.spellDone) FC.spellDone();
  }

  function srProgress() {
    var el = srQ(".fc-sr-progress");
    if (el) el.textContent = srDone + " / " + srTotal;
    if (FC.spellProgress) FC.spellProgress(srDone, srTotal);
    saveSoon(srSnapshot());
  }

  function srNext() {
    if (!srPool.length) { srFinish(); return; }
    srCur = srPool[0];
    srTries = 0;
    srTyped = "";
    srRevealed = false;
    srPending = null;
    srRender();
    srFocus();
    saveSoon(srSnapshot());
  }

  function srFocus() {
    var inp = srQ(".fc-sr-input");
    if (!inp) return;
    setTimeout(function () { try { inp.focus(); } catch (e) {} }, 40);
  }

  /// 语篇里的目标词抠成 ______（返回题干 + 要拼的答案）
  function srBlankPassage(text, surface) {
    var src = String(text || "");
    var s = String(surface || "").trim();
    if (!s) return { text: src, answer: "" };
    var safe = s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    var re = null;
    try { re = new RegExp("\\b" + safe + "\\b", "i"); } catch (e) { re = null; }
    var hit = re ? src.match(re) : null;
    if (!hit) {
      var i = src.toLowerCase().indexOf(s.toLowerCase());
      if (i < 0) return { text: src, answer: "" };
      return {
        text: src.slice(0, i) + "______" + src.slice(i + s.length),
        answer: src.slice(i, i + s.length)
      };
    }
    return {
      text: src.slice(0, hit.index) + "______" + src.slice(hit.index + hit[0].length),
      answer: hit[0]
    };
  }

  function srRender() {
    var it = srCur;
    if (!it) return;

    var kindEl = srQ(".fc-sr-kind");
    if (kindEl) {
      kindEl.textContent = it.kind === "sentence" ? "句子拼写"
                         : it.kind === "passage" ? "语篇拼写" : "单词拼写";
    }
    var cnEl = srQ(".fc-sr-cn");
    if (cnEl) cnEl.textContent = it.cn || "";

    var prompt = "";
    var answer = "";
    if (it.kind === "sentence") {
      var r = blankSentence(it.sentence || "", it.word || "");
      prompt = r.text;
      answer = r.answer || it.word || "";
    } else if (it.kind === "passage") {
      var r2 = srBlankPassage(it.passage || "", it.surface || it.word || "");
      prompt = r2.text;
      answer = r2.answer || it.surface || it.word || "";
    } else {
      answer = it.word || "";
    }
    srAnswer = String(answer || "").trim();
    srTyped = "";

    var box = srQ(".fc-sr-prompt");
    if (box) {
      box.innerHTML = "";
      var shown = String(prompt || "").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
      if (shown && shown.indexOf("______") >= 0) {
        var parts = shown.split("______");
        box.appendChild(document.createTextNode(parts[0]));
        var sl = document.createElement("span");
        sl.className = "fc-sr-slots";
        box.appendChild(sl);
        var rest = parts.slice(1).join("______");
        if (rest) box.appendChild(document.createTextNode(rest));
      } else {
        if (shown) box.appendChild(document.createTextNode(shown));
        var sl2 = document.createElement("span");
        sl2.className = "fc-sr-slots fc-sr-slots-block";
        box.appendChild(sl2);
      }
    }

    srPaint();
    srSetResult("", "");
    srHintLeft();
    srUpdateBtns();
    srProgress();
  }

  /// 画格子：几个字母几格，不给首字母
  function srPaint() {
    var host = srQ(".fc-sr-slots");
    if (!host) return;
    host.innerHTML = "";
    for (var i = 0; i < srAnswer.length; i++) {
      var cell = document.createElement("span");
      cell.className = "fc-sr-slot";
      var ch = srTyped.charAt(i);
      if (ch) { cell.textContent = ch; cell.classList.add("is-filled"); }
      host.appendChild(cell);
    }
  }

  function srSyncInput() {
    var inp = srQ(".fc-sr-input");
    if (inp) inp.value = srTyped;
  }

  function srSetResult(txt, cls) {
    var el = srQ(".fc-sr-result");
    if (!el) return;
    el.textContent = txt || "";
    el.className = "fc-sr-result" + (cls ? " " + cls : "");
  }

  function srHintLeft() {
    var el = srQ(".fc-sr-tries");
    if (!el) return;
    var left = SR_MAX_TRIES - srTries;
    if (left < 0) left = 0;
    el.textContent = "剩余机会 " + left + " / " + SR_MAX_TRIES;
  }

  /// 揭晓答案后：藏起三个动作按钮，亮出「继续」
  function srUpdateBtns() {
    var row = srQ(".fc-sr-actions");
    if (row) {
      row.querySelectorAll("[data-sr]").forEach(function (b) {
        var k = b.getAttribute("data-sr");
        if (k === "quit") return;
        if (k === "next") { b.style.display = srPending ? "" : "none"; return; }
        b.style.display = srPending ? "none" : "";
      });
    }
    var inp = srQ(".fc-sr-input");
    if (inp) inp.disabled = !!srPending;
  }

  function srOnInput() {
    if (!srOn || srRevealed || srPending) return;
    var inp = srQ(".fc-sr-input");
    if (!inp) return;
    var v = String(inp.value || "").replace(/[^A-Za-z'’-]/g, "");
    if (v.length > srAnswer.length) v = v.slice(0, srAnswer.length);
    srTyped = v;
    inp.value = v;
    srPaint();
    if (srAnswer.length && v.length >= srAnswer.length) srCheck();
  }

  function srShake() {
    var host = srQ(".fc-sr-slots");
    if (!host) return;
    host.classList.add("is-wrong");
    setTimeout(function () { host.classList.remove("is-wrong"); }, 480);
  }

  function srCheck() {
    if (!srOn || srRevealed || srPending) return;
    if (!srTyped) return;

    if (srTyped.toLowerCase() === srAnswer.toLowerCase()) {
      srRevealed = true;
      srSetResult("✓ " + srAnswer, "is-right");
      speak(srAnswer, "en-US", TTS_WORD);
      srUpdateBtns();
      srDone++;
      srProgress();
      setTimeout(function () {
        if (!srOn || !srRevealed) return;
        srPool.shift();
        srNext();
      }, 650);
      return;
    }

    // 拼错：还有机会就红一下清空重输，没机会就揭答案放回队尾
    srTries++;
    srHintLeft();
    srShake();
    srTyped = "";
    srSyncInput();
    srPaint();
    if (srTries >= SR_MAX_TRIES) {
      srPending = "forget";
      srReveal("三次机会用完");
      srUpdateBtns();
    }
  }

  function srReveal(reason) {
    srRevealed = true;
    srTyped = srAnswer;
    srSyncInput();
    srPaint();
    srSetResult("✕ 正确拼写：" + srAnswer + (reason ? "（" + reason + "）" : ""), "is-wrong");
    speak(srAnswer, "en-US", TTS_WORD);
  }

  function srAction(k) {
    if (!srOn) return;
    if (k === "quit") { srFinish(); return; }

    // 揭晓后只认「继续」
    if (srPending) {
      if (k !== "next") return;
      var p = srPending;
      srPending = null;
      if (p === "skip") {
        srPool.shift();
        srDone++;
        srProgress();
        srNext();
      } else {
        var it = srPool.shift();
        if (it) srPool.push(it);   // 忘记 -> 放回队尾，后面再来
        srNext();
      }
      return;
    }

    if (k === "skip") { srPending = "skip"; srReveal(""); srUpdateBtns(); return; }
    if (k === "forget") { srPending = "forget"; srReveal(""); srUpdateBtns(); return; }
    if (k === "hint") {
      srTries++;
      srHintLeft();
      speak((srCur && srCur.word) || srAnswer, "en-US", TTS_WORD);
      if (srTries >= SR_MAX_TRIES) {
        srPending = "forget";
        srReveal("提示次数用满");
      }
      srUpdateBtns();
      srFocus();
      return;
    }
  }

  // ---------- 事件绑定（只在拼写轮块内）----------
  var srSec = srQ(".fc-spellround");
  if (srSec) {
    srSec.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-sr]");
      if (btn) {
        e.preventDefault();
        e.stopPropagation();
        srAction(btn.getAttribute("data-sr"));
        return;
      }
      srFocus();   // 点题干 / 格子 = 把键盘唤回来
    });
  }
  var srInputEl = srQ(".fc-sr-input");
  if (srInputEl) {
    srInputEl.addEventListener("input", srOnInput);
    srInputEl.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.code === "Enter") {
        e.preventDefault();
        if (srOn && !srRevealed && !srPending) srCheck();
      }
    });
  }

  // ---------- 拼写前确认浮层（容器内，不再问壳）----------
  // 以前：workflow 发 web.spellPrompt → Dart 弹 AlertDialog → 回 web.spellDecision。
  // 现在：直接在这层弹，改文案 / 样式不用重编 APK —— 符合「一切都是 API」。
  function srAskEl() { return srQ(".fc-spell-ask"); }

  function srAskShow(n) {
    var el = srAskEl();
    if (!el) return;
    var sub = el.querySelector(".fc-sa-sub");
    if (sub) sub.textContent = n + " 个词 · 拼错回队尾重来，不计入复习进度";
    el.hidden = false;
  }

  function srAskHide() {
    var el = srAskEl();
    if (el) el.hidden = true;
  }

  (function bindAsk() {
    var el = srAskEl();
    if (!el) return;
    el.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-sa]");
      if (!btn) return;
      e.preventDefault();
      e.stopPropagation();
      var k = btn.getAttribute("data-sa");
      srAskHide();
      if (k === "go") beginSpell(); else endSpell();
    });
  })();

  // ---------- 这一轮考哪些词（原 Dart _buildSpellItems，搬进容器内）----------
  // 有例句 → 句子拼写；没例句 → 单词拼写；在语篇里出现过 → 语篇拼写（排最后）。
  // 标熟的跳过。cn 从 fields.senses 拼（复刻 script.js 的 spellCnText 口径）。
  function spellCnOf(fields) {
    var raw = fields && fields.senses;
    var parts = [];
    if (Array.isArray(raw)) {
      for (var i = 0; i < raw.length; i++) {
        var s = raw[i];
        if (!s || typeof s !== "object") continue;
        var cn = String(s.cn || s.meaning || "")
          .replace(/[（(][^（()）]*[)）]/g, "").trim();
        if (!cn) continue;
        var pos = String(s.pos || "").trim();
        parts.push((pos ? pos + " " : "") + cn);
      }
    }
    if (!parts.length) {
      var m = String((fields && fields.meaning) || "").trim();
      if (m) parts.push(m);
    }
    return parts.join("；");
  }

  // plan 里的语篇是 {title, cn, segments:[{w,lemma,pos,meaning,plain,blank}|{t}]}
  function passagePlainOf(p) {
    var out = "";
    var segs = (p && p.segments) || [];
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i] || {};
      out += (s.w != null) ? String(s.w) : (s.t != null ? String(s.t) : "");
    }
    return out;
  }

  function passageSurfaceOf(p, word) {
    var lemma = String(word || "").trim().toLowerCase();
    var segs = (p && p.segments) || [];
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i] || {};
      if (s.w == null) continue;                       // 非词段
      if (String(s.lemma || "").trim().toLowerCase() === lemma) {
        return String(s.w || "").trim();
      }
    }
    return null;
  }

  /// 异步组条目：plan 只带 {id, word, modes}，释义 / 例句得现取。
  function buildSpellItems(ids) {
    var passageOf = {};
    for (var i = 0; i < S.units.length; i++) {
      var u = S.units[i];
      if (!u || !u.hasPassage || !u.passage) continue;
      var cs = u.cards || [];
      for (var j = 0; j < cs.length; j++) passageOf[cs[j].id] = u.passage;
    }

    var jobs = (ids || []).map(function (id) {
      var meta = cardMeta(id);
      var w = meta && meta.word ? String(meta.word).trim() : "";
      if (!w) return Promise.resolve(null);
      return FC.call("card.get", { id: id }).then(function (r) {
        var c = r && r.card;
        if (!c) return null;
        if (c.kv && c.kv.known) return null;           // 标熟 = 跳过拼写
        var f = c.fields || {};
        var cn = spellCnOf(f);
        var sent = String(f.sentence_en || "").trim();
        var main = sent
          ? { kind: "sentence", id: id, word: w, cn: cn, sentence: sent }
          : { kind: "word", id: id, word: w, cn: cn };
        var p = passageOf[id];
        var pas = null;
        if (p) {
          var surface = passageSurfaceOf(p, w);
          if (surface) {
            pas = {
              kind: "passage", id: id, word: w, cn: cn,
              passage: passagePlainOf(p), surface: surface
            };
          }
        }
        return { main: main, pas: pas };
      }).catch(function () { return null; });
    });

    return Promise.all(jobs).then(function (rs) {
      var sent = [], single = [], pas = [];
      for (var i = 0; i < rs.length; i++) {
        var r = rs[i];
        if (!r) continue;
        if (r.main.kind === "sentence") sent.push(r.main);
        else single.push(r.main);
        if (r.pas) pas.push(r.pas);
      }
      return sent.concat(single, pas);
    });
  }

  // 原生侧：开一轮拼写（覆盖 script.js 的默认实现）
  FC.startSpellRound = function (jsonStr) {
    var data = {};
    try { data = JSON.parse(jsonStr) || {}; } catch (e) { data = {}; }
    srStart(data.items || []);
  };

  // ============================================================
  //  阶段 4：会话驱动 —— 整个切牌流程归 workflow.js
  //  壳只做三件事：挂一张卡(web.mount) / 跑 FSRS 落盘(review.commit) / 报进度
  // ============================================================
  var S = null;              // 当前会话状态
  var _committed = {};       // 已落 FSRS 的 cardId

  function sPost(type, data) {
    if (FC.post) FC.post(type, data || {});
  }

  function cardMeta(id) { return S.cardById[id] || null; }

  function modesOf(id) {
    var c = cardMeta(id);
    return (c && c.modes) ? c.modes : [];
  }

  function allPassed(id) {
    var modes = modesOf(id);
    if (!modes.length) return true;
    var p = S.passedModes[id] || {};
    for (var i = 0; i < modes.length; i++) { if (!p[modes[i]]) return false; }
    return true;
  }

  function bump(id, e) {
    if (e > (S.effort[id] || 0)) S.effort[id] = e;
  }

  function ratingFor(id) {
    var e = S.effort[id] || 0;
    return e === 0 ? 'good' : (e === 1 ? 'hard' : 'again');
  }

  function cardsBetween(from, to) {
    var out = [], seen = {};
    for (var i = from; i < to && i < S.units.length; i++) {
      var cs = S.units[i].cards || [];
      for (var j = 0; j < cs.length; j++) {
        if (!seen[cs[j].id]) { seen[cs[j].id] = 1; out.push(cs[j].id); }
      }
    }
    return out;
  }

  function buildIndex() {
    S.cardById = {};
    for (var i = 0; i < S.units.length; i++) {
      var cs = S.units[i].cards || [];
      for (var j = 0; j < cs.length; j++) S.cardById[cs[j].id] = cs[j];
    }
  }

  function removePool(id) {
    var i = S.retestPool.indexOf(id);
    if (i >= 0) S.retestPool.splice(i, 1);
  }

  function enterLearn() {
    if (!S.queue.length) { nextUnit(); return; }
    S.phase = 'learn';
    S.roundTotal = S.queue.length;
  }

  function startUnit() {
    S.queue = [];
    S.retestPool = [];
    S.passedModes = {};
    S.wrongCount = {};
    S.round = 1;
    S.modeIdx = 0;
    var u = S.units[S.unitIdx];
    if (!u) { S.phase = 'done'; return; }
    S.queue = (u.cards || []).map(function (c) {
      return { cardId: c.id, mode: 'read', round: 1 };
    });
    S.roundTotal = S.queue.length;
    if (u.hasPassage && u.readFirst) S.phase = 'passage';
    else if (u.hasPassage && S.passageCloze) S.phase = 'passageCloze';
    else enterLearn();
  }

  function nextUnit() {
    S.unitIdx++;
    if (!S.reviewSpellDone && S.leadingReviewCount > 0 &&
        S.unitIdx === S.leadingReviewCount && S.unitIdx < S.units.length) {
      S.reviewSpellDone = true;
      var cs = cardsBetween(0, S.leadingReviewCount);
      if (cs.length) {
        S.spellCards = cs; S.spellReturnsToUnits = true; S.spellDone = 0;
        S.phase = 'spellPrompt'; return;
      }
    }
    if (S.unitIdx >= S.units.length) {
      if (!S.finalSpellDone) {
        S.finalSpellDone = true;
        var from = S.reviewSpellDone ? S.leadingReviewCount : 0;
        var cs2 = cardsBetween(from, S.units.length);
        if (cs2.length) {
          S.spellCards = cs2; S.spellReturnsToUnits = false; S.spellDone = 0;
          S.phase = 'spellPrompt'; return;
        }
      }
      S.phase = 'done'; return;
    }
    startUnit();
  }

  function startMode() {
    // 兜底一：池里「考不了任何**启用中**的考法」的卡直接毕业。两种都算：
    //   1. modesOf(id) 为空（既没例句也没词义）
    //   2. 有考法，但用户一个都没开 —— 例如卡只有例句（能考 cloze），
    //      而用户只开了 choice。这种卡永远进不了 pending，
    //      会一路 round++ 自递归到栈溢出。以前只挡了第 1 种。
    S.retestPool.slice().forEach(function (id) {
      var ms = modesOf(id);
      var playable = ms.filter(function (m) {
        return S.retestModes.indexOf(m) >= 0;
      });
      if (!playable.length) { removePool(id); S.graduated[id] = true; }
    });
    while (S.modeIdx < S.retestModes.length) {
      var m = S.retestModes[S.modeIdx];
      var pending = S.retestPool.filter(function (id) {
        if (S.graduated[id]) return false;
        if (modesOf(id).indexOf(m) < 0) return false;
        var p = S.passedModes[id] || {};
        return !p[m];
      });
      if (!pending.length) { S.modeIdx++; continue; }
      S.phase = (m === 'cloze') ? 'cloze' : 'choice';
      S.queue = pending.map(function (id) {
        return { cardId: id, mode: m, round: S.round };
      });
      S.roundTotal = S.queue.length;
      return;
    }
    if (!S.retestPool.length) { nextUnit(); return; }

    // 兜底二：轮数封顶。S.round++ 既不清池也不改 passedModes，
    // 一旦进入「状态不再变化」的组合，自递归就是无限递归（栈溢出）。
    // 宁可放行这些卡，也不能让用户卡在死循环里出不来。
    if (S.round >= MAX_RETEST_ROUND) {
      S.retestPool.slice().forEach(function (id) { S.graduated[id] = true; });
      S.retestPool = [];
      nextUnit();
      return;
    }
    S.round++; S.modeIdx = 0; startMode();
  }

  function advance() {
    if (S.queue.length) return;
    if (S.phase === 'learn') {
      if (!S.retestPool.length || !S.retestModes.length) { nextUnit(); return; }
      S.round = 2; S.modeIdx = 0; startMode(); return;
    }
    S.modeIdx++;
    startMode();
  }

  function submitLearn(rating) {
    if (!S.queue.length) return;
    var step = S.queue.shift();
    var id = step.cardId;
    if (rating === 'good' || !modesOf(id).length) {
      S.graduated[id] = true;
    } else {
      if (S.retestPool.indexOf(id) < 0) S.retestPool.push(id);
      bump(id, rating === 'again' ? 2 : 1);
    }
    advance();
  }

  function submitRetest(mode, ok) {
    if (!S.queue.length) return;
    var step = S.queue.shift();
    var id = step.cardId;
    if (ok) {
      (S.passedModes[id] = S.passedModes[id] || {})[mode] = true;
      if (allPassed(id)) { removePool(id); S.graduated[id] = true; }
    } else {
      var n = (S.wrongCount[id] || 0) + 1;
      S.wrongCount[id] = n;
      bump(id, n >= 2 ? 2 : 1);
    }
    advance();
  }

  function submitPassage() {
    var u = S.units[S.unitIdx];
    if (S.passageCloze && u && u.hasPassage) S.phase = 'passageCloze';
    else enterLearn();
  }

  function submitPassageCloze(ok) { if (ok) enterLearn(); }

  function flushGraduated() {
    Object.keys(S.graduated).forEach(function (id) {
      if (_committed[id]) return;
      _committed[id] = true;
      log("commit " + id + " rating=" + ratingFor(id));
      try {
        FC.call('review.commit', { id: id, rating: ratingFor(id) })
          .catch(function () {});
      } catch (e) {}
    });
  }

  function progressDone() {
    if (S.phase === 'passage' || S.phase === 'passageCloze') return 0;
    if (S.phase === 'spell' || S.phase === 'spellPrompt') return S.spellDone;
    return Math.max(0, S.roundTotal - S.queue.length);
  }

  function progressTotal() {
    if (S.phase === 'passage' || S.phase === 'passageCloze') return 1;
    if (S.phase === 'spell' || S.phase === 'spellPrompt') return S.spellCards.length;
    return S.roundTotal;
  }

  function reportProgress() {
    sPost('web.progress', {
      phase: S.phase,
      done: progressDone(),
      total: progressTotal(),
      graduated: Object.keys(S.graduated).length
    });
  }

  function render() {
    if (!S) return;
    log("render phase=" + S.phase + " unit=" + S.unitIdx +
        " q=" + S.queue.length + " spell=" + S.spellCards.length);
    prefetchAhead();   // 顺带把后面几张的音频先落盘
    if (S.phase === 'done') {
      sPost('web.finish', { graduated: Object.keys(S.graduated).length });
      return;
    }
    if (S.phase === 'spellPrompt') {
      // 容器内浮层问「拼不拼」——以前是发 web.spellPrompt 让壳弹原生框
      srAskShow(S.spellCards.length);
      return;
    }
    if (S.phase === 'spell') {
      // 拼写轮 UI 归 srStart 管，这里不再向壳要 items
      srAskHide();
      return;
    }
    if (S.phase === 'passage' || S.phase === 'passageCloze') {
      sPost('web.mount', {
        unit: S.unitIdx,
        mode: S.phase === 'passage' ? 'passage' : 'passage_cloze',
        index: 0, total: 1, round: 1
      });
      return;
    }
    var step = S.queue[0];
    if (!step) return;
    sPost('web.mount', {
      unit: S.unitIdx,
      cardId: step.cardId,
      mode: step.mode,
      index: Math.max(0, S.roundTotal - S.queue.length),
      total: S.roundTotal,
      round: step.round
    });
  }

  function onAnswer(rating) {
    if (!S) return;
    log("answer " + rating + " phase=" + S.phase + " q=" + S.queue.length);
    if (S.phase === 'learn') submitLearn(rating);
    else if (S.phase === 'choice' || S.phase === 'cloze') {
      submitRetest(S.phase, rating !== 'again');
    } else if (S.phase === 'passage') submitPassage();
    else if (S.phase === 'passageCloze') submitPassageCloze(rating !== 'again');
    else return;
    flushGraduated();
    reportProgress();
    render();
  }

  function beginSpell() {
    if (!S || S.phase !== 'spellPrompt') return;
    log("beginSpell n=" + S.spellCards.length);
    S.spellDone = 0;
    S.phase = 'spell';
    render();
    // 选卡要现取字段（plan 只带 id/word），异步组完再开轮。
    // 空列表时 srStart 自己会调 FC.spellDone() → endSpell()。
    buildSpellItems(S.spellCards).then(function (items) {
      if (!S || S.phase !== 'spell') return;
      srStart(items);
    }).catch(function (e) {
      log("buildSpellItems 失败 " + e);
      if (S && S.phase === 'spell') endSpell();
    });
  }

  function endSpell() {
    if (!S) return;
    log("endSpell returns=" + S.spellReturnsToUnits);
    S.spellCards = []; S.spellDone = 0;
    if (S.spellReturnsToUnits) { S.spellReturnsToUnits = false; startUnit(); }
    else S.phase = 'done';
    render();
  }

  function startSession(plan) {
    _committed = {};
    _pfDone = {};
    log("start units=" + (plan.units || []).length);
    S = {
      units: plan.units || [],
      retestModes: plan.retestModes || [],
      passageCloze: !!plan.passageCloze,
      cardById: {},
      unitIdx: 0,
      phase: 'done',
      queue: [], retestPool: [], graduated: {}, passedModes: {},
      effort: {}, wrongCount: {},
      round: 1, modeIdx: 0, roundTotal: 0,
      leadingReviewCount: 0,
      reviewSpellDone: false, finalSpellDone: false,
      spellReturnsToUnits: false, spellCards: [], spellDone: 0
    };
    buildIndex();
    var n = 0;
    for (var i = 0; i < S.units.length; i++) { if (!S.units[i].isReview) break; n++; }
    S.leadingReviewCount = n;
    if (!S.units.length) { S.phase = 'done'; render(); return; }

    // 接管：评分 / 拼写回报都归本层
    FC.answer = function (r) { onAnswer(r); };
    FC.spellDone = function () { endSpell(); };
    FC.spellProgress = function (d) { if (S) { S.spellDone = d || 0; reportProgress(); } };

    startUnit();
    reportProgress();
    render();
  }

  if (FC.on) {
    FC.on('web.start', function () {
      if (!FC.call) return;
      log("web.start -> 拉计划");
      FC.call('session.plan', {}).then(function (plan) {
        if (plan && plan.units && plan.units.length !== undefined) startSession(plan);
        else log("web.start：没有计划（非 Web 驱动？）");
      }).catch(function () {});
    });
    // 老路径兼容：壳主动回执（现在浮层在容器内，不再走这条）
    FC.on('web.spellDecision', function (d) {
      if (!S || S.phase !== 'spellPrompt') return;
      if (d && d.go) beginSpell(); else endSpell();
    });
  }

  WF.session = {
    isOn: function () { return !!S; },
    state: function () { return S; },
    onAnswer: onAnswer
  };
})();
