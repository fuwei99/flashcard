/* ============================================================
   不背单词 · 暗黑极简模板 · 交互脚本
   ------------------------------------------------------------
   两段式流程：
     正面  点【忘记】-> pre=again -> 词义页只剩【下一词】
           点【模糊】-> pre=hard  -> 词义页【记错了】+【下一词】
           点【记得】-> pre=good  -> 词义页【记错了】+【下一词】
     词义页 点【记错了】-> 改判 again
           点【下一词】-> 提交 pre 那个评分
   原生壳只暴露 window.Flashcard API：
     Flashcard.getCard()          -> {fields, state, stats, index, total}
     Flashcard.answer(rating)     -> 'again' | 'hard' | 'good'
     Flashcard.tts(text, lang)
     Flashcard.getState(k) / setState(k, v)
     Flashcard.undo() / next() / prev()
     Flashcard.ready()
   ============================================================ */
(function () {
  "use strict";

  var FC = window.Flashcard || null;

  // ---------- 降级：浏览器里没有原生壳时，用 localStorage 模拟 ----------
  if (!FC) {
    FC = window.Flashcard = {
      _card: null,
      getCard: function () { return FC._card || {}; },
      answer: function (r) {
        console.log("[mock] answer:", r);
        var st = JSON.parse(localStorage.getItem("fc_states") || "{}");
        st[FC._card.fields.word] = r;
        localStorage.setItem("fc_states", JSON.stringify(st));
        FC.next();
      },
      tts: function (text, lang) {
        if (!("speechSynthesis" in window)) return;
        speechSynthesis.cancel();
        var u = new SpeechSynthesisUtterance(text);
        u.lang = lang || "en-US";
        u.rate = 0.95;
        speechSynthesis.speak(u);
      },
      getState: function (k) {
        var s = JSON.parse(localStorage.getItem("fc_kv") || "{}");
        return s[k];
      },
      setState: function (k, v) {
        var s = JSON.parse(localStorage.getItem("fc_kv") || "{}");
        s[k] = v; localStorage.setItem("fc_kv", JSON.stringify(s));
      },
      undo: function () { }, next: function () { }, prev: function () { },
      ready: function () { }
    };
  }

  var root = document.querySelector(".fc-root");
  if (!root) return;

  var preRating = "good"; // 正面预判

  // ---------- 渲染词组列表 ----------
  function renderPhrases(card) {
    var box = root.querySelector(".fc-phrase-list");
    if (!box) return;
    box.innerHTML = "";
    (card.fields.phrases || []).forEach(function (p) {
      var row = document.createElement("div");
      row.className = "fc-phrase";
      row.innerHTML =
        '<span class="en"></span><span class="cn"></span>';
      row.querySelector(".en").textContent = p.en || "";
      row.querySelector(".cn").textContent = p.cn || "";
      box.appendChild(row);
    });
  }

  // ---------- 进词义页 ----------
  function toMeaning(pre) {
    preRating = pre || "good";
    root.setAttribute("data-pre", preRating); // CSS 靠它决定是否显示【记错了】
    root.setAttribute("data-state", "back");
    var face = root.querySelector(".fc-back");
    if (face) face.scrollTop = 0;
  }

  // ---------- 事件委托 ----------
  root.addEventListener("click", function (e) {
    var t = e.target.closest("[data-action],[data-tts]");
    if (!t) return;

    if (t.hasAttribute("data-tts")) {
      e.stopPropagation();
      FC.tts(t.getAttribute("data-tts"), "en-US");
      return;
    }

    var action = t.getAttribute("data-action");

    // 正面三档：一律进词义页
    if (action === "to-meaning") {
      toMeaning(t.getAttribute("data-pre"));
      return;
    }

    // 词义页：这里才评分
    if (action === "answer") {
      var r = t.getAttribute("data-rating");
      var final = (r === "again") ? "again" : preRating;
      root.querySelectorAll(".fc-actions-back .fc-btn").forEach(function (b) {
        b.setAttribute("disabled", "disabled");
      });
      FC.answer(final);
      return;
    }
  });

  // 空格/回车 = 进词义页（正面时，按 good 预判）
  document.addEventListener("keydown", function (e) {
    if (e.code === "Space" || e.code === "Enter") {
      e.preventDefault();
      if (root.getAttribute("data-state") === "front") toMeaning("good");
    }
  });

  // ---------- 初始化 ----------
  function boot() {
    var card = FC.getCard();
    if (card && card.fields) renderPhrases(card);

    root.setAttribute("data-state", "front");
    root.setAttribute("data-pre", "");

    if (FC.ready) FC.ready();
    console.log("[bubei_dark] card ready:", (card.fields || {}).word);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
