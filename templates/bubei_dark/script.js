/* ============================================================
   不背单词 · 暗黑极简模板 · 交互脚本
   ------------------------------------------------------------
   卡牌内部全权处理：翻面、TTS、评分按钮。
   原生壳只暴露 window.Flashcard API：
     Flashcard.getCard()          -> {fields, state, stats, index, total}
     Flashcard.answer(rating)     -> 'again' | 'hard' | 'good'
     Flashcard.tts(text, lang)    -> 调用系统 TTS
     Flashcard.getState(k)        -> 读卡牌私有状态
     Flashcard.setState(k, v)     -> 写卡牌私有状态
     Flashcard.undo() / next() / prev()
     Flashcard.ready()            -> 告诉原生壳渲染完成
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

  // ---------- 渲染词组列表（数组字段由脚本生成 DOM）----------
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

  // ---------- 翻面 ----------
  function reveal() {
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
    if (action === "reveal") { reveal(); return; }
    if (action === "answer") {
      var rating = t.getAttribute("data-rating");
      // 防止连点重复提交
      root.querySelectorAll(".fc-btn").forEach(function (b) {
        b.setAttribute("disabled", "disabled");
      });
      FC.answer(rating);
      return;
    }
  });

  // 空格/回车翻面
  document.addEventListener("keydown", function (e) {
    if (e.code === "Space" || e.code === "Enter") {
      e.preventDefault();
      if (root.getAttribute("data-state") === "front") reveal();
    }
  });

  // ---------- 初始化 ----------
  function boot() {
    var card = FC.getCard();
    if (card && card.fields) renderPhrases(card);

    // 若这张卡已学且非首次，直接展示背面可配置；这里保持「先正面」
    root.setAttribute("data-state", "front");

    // 交给原生壳：已挂载完成
    if (FC.ready) FC.ready();
    console.log("[bubei_dark] card ready:", (card.fields || {}).word);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
