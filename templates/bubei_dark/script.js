/* ============================================================
   不背单词 · 暗黑极简模板 · 交互脚本
   ------------------------------------------------------------
   三种考法，由 card.session.mode 决定：
     read   : 正面三档 -> 词义页两档
     choice : 英 -> 中选义，选完 -> 下一词
     cloze  : 例句挖空 -> 选英词，选完 -> 下一词
   选项数据来自 card.choices = [{text, right}]
   ============================================================ */
(function () {
  "use strict";

  var FC = window.Flashcard || null;
  if (!FC) {
    FC = window.Flashcard = {
      getCard: function () { return window.__FLASHCARD_CARD__ || {}; },
      answer: function (r) { console.log("[mock] answer:", r); },
      tts: function (t, l) {
        if (!("speechSynthesis" in window)) return;
        speechSynthesis.cancel();
        var u = new SpeechSynthesisUtterance(t);
        u.lang = l || "en-US"; u.rate = 0.95; speechSynthesis.speak(u);
      },
      getState: function () {}, setState: function () {},
      undo: function () {}, next: function () {}, prev: function () {},
      ready: function () {}
    };
  }

  var root = document.querySelector(".fc-root");
  if (!root) return;

  var card = FC.getCard() || {};
  var fields = card.fields || {};
  var sess = card.session || {};
  var mode = sess.mode || "read";
  var choices = card.choices || [];
  var preRating = "good";
  var pending = null; // 'good' | 'again'

  // ---------- 词组 ----------
  function renderPhrases() {
    var box = root.querySelector(".fc-phrase-list");
    if (!box) return;
    box.innerHTML = "";
    (fields.phrases || []).forEach(function (p) {
      var row = document.createElement("div");
      row.className = "fc-phrase";
      var en = document.createElement("span"); en.className = "en"; en.textContent = p.en || "";
      var cn = document.createElement("span"); cn.className = "cn"; cn.textContent = p.cn || "";
      row.appendChild(en); row.appendChild(cn);
      box.appendChild(row);
    });
  }

  // ---------- read：进词义页 ----------
  function toMeaning(pre) {
    preRating = pre || "good";
    root.setAttribute("data-pre", preRating);
    root.setAttribute("data-state", "back");
    var f = root.querySelector(".fc-back");
    if (f) f.scrollTop = 0;
  }

  // ---------- choice / cloze：渲染选项 ----------
  function renderOptions() {
    var box = root.querySelector('.fc-options[data-for="' + mode + '"]');
    if (!box) return;
    box.innerHTML = "";
    choices.forEach(function (c) {
      var b = document.createElement("button");
      b.className = "fc-option";
      b.type = "button";
      b.textContent = c.text || "";
      b.setAttribute("data-right", String(c.right === "true" || c.right === true));
      b.addEventListener("click", function () { pick(b, box); });
      box.appendChild(b);
    });
  }

  function pick(btn, box) {
    if (pending !== null) return;
    pending = (btn.getAttribute("data-right") === "true") ? "good" : "again";

    box.querySelectorAll(".fc-option").forEach(function (x) {
      var right = x.getAttribute("data-right") === "true";
      if (right) x.classList.add("right");
      else if (x === btn) x.classList.add("wrong");
      x.setAttribute("disabled", "disabled");
    });

    var nb = root.querySelector(".fc-actions-next .fc-btn");
    if (nb) nb.removeAttribute("disabled");
  }

  // ---------- cloze：挖空例句 ----------
  function renderCloze() {
    var raw = String(fields.sentence_en || "").replace(/<[^>]+>/g, "");
    var w = String(fields.word || "");
    var blank = raw;
    if (w) {
      try { blank = raw.replace(new RegExp(w, "ig"), "______"); }
      catch (e) { blank = raw; }
    }
    var box = root.querySelector(".fc-cloze-sentence");
    if (box) box.textContent = blank;
  }

  // ---------- 事件 ----------
  root.addEventListener("click", function (e) {
    var t = e.target.closest("[data-action],[data-tts]");
    if (!t) return;

    if (t.hasAttribute("data-tts")) {
      e.stopPropagation();
      // 例句里带 <u>/<b> 高亮，剥掉再念，不然 TTS 会念出尖括号
      var say = String(t.getAttribute("data-tts") || "")
        .replace(/<[^>]*>/g, "")
        .replace(/\s+/g, " ")
        .trim();
      if (say) FC.tts(say, "en-US");
      return;
    }

    var a = t.getAttribute("data-action");

    if (a === "to-meaning") { toMeaning(t.getAttribute("data-pre")); return; }

    if (a === "answer") {
      var r = t.getAttribute("data-rating");
      var fin = (r === "again") ? "again" : preRating;
      root.querySelectorAll(".fc-actions-back .fc-btn").forEach(function (b) {
        b.setAttribute("disabled", "disabled");
      });
      FC.answer(fin);
      return;
    }

    if (a === "submit") {
      if (pending === null) return;
      t.setAttribute("disabled", "disabled");
      FC.answer(pending);
      return;
    }
  });

  // 空格 / 回车
  document.addEventListener("keydown", function (e) {
    if (e.code === "Space" || e.code === "Enter") {
      e.preventDefault();
      if (mode === "read") {
        if (root.getAttribute("data-state") === "front") toMeaning("good");
      } else if (pending !== null) {
        var nb = root.querySelector(".fc-actions-next .fc-btn");
        if (nb) { nb.setAttribute("disabled", "disabled"); FC.answer(pending); }
      }
    }
  });

  // ---------- 初始化 ----------
  function boot() {
    root.setAttribute("data-mode", mode);
    root.setAttribute("data-state", "front");
    root.setAttribute("data-pre", "");

    if (mode === "read") {
      renderPhrases();
    } else if (mode === "choice") {
      renderOptions();
    } else if (mode === "cloze") {
      renderCloze();
      renderOptions();
    }

    if (FC.ready) FC.ready();
    console.log("[bubei_dark] ready mode=" + mode + " word=" + (fields.word || ""));
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
