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

  // 原生侧：开一轮拼写（覆盖 script.js 的默认实现）
  FC.startSpellRound = function (jsonStr) {
    var data = {};
    try { data = JSON.parse(jsonStr) || {}; } catch (e) { data = {}; }
    srStart(data.items || []);
  };

  WF.spell = {
    start: srStart,
    finish: srFinish,
    isOn: function () { return srOn; },
    snapshot: srSnapshot
  };
})();
