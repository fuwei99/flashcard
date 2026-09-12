/* ============================================================
   形近词辨析 · 暗黑模板 · 交互脚本
   卡牌内部全权处理：义项渲染、翻面、TTS、评分。
   原生壳只暴露 window.Flashcard API。
   ============================================================ */
(function () {
  "use strict";

  var FC = window.Flashcard || {
    getCard: function () { return {}; },
    answer: function () {}, tts: function () {},
    getState: function () {}, setState: function () {},
    undo: function () {}, next: function () {}, prev: function () {},
    ready: function () {}
  };

  var root = document.querySelector(".fc-root");
  if (!root) return;

  // ---------- 渲染义项块（数组字段由脚本生成 DOM）----------
  function renderSenses(card) {
    var list = (card.fields && card.fields.senses) || [];
    root.querySelectorAll(".fc-senses").forEach(function (box) {
      box.innerHTML = "";
      list.forEach(function (s) {
        var d = document.createElement("div");
        d.className = "fc-sense";
        var p = document.createElement("span");
        p.className = "pos"; p.textContent = s.pos || "";
        var c = document.createElement("span");
        c.className = "cn"; c.textContent = s.cn || "";
        d.appendChild(p); d.appendChild(c);
        box.appendChild(d);
      });
    });
  }

  // ---------- 翻面 ----------
  function reveal() {
    root.setAttribute("data-state", "back");
    var f = root.querySelector(".fc-back");
    if (f) f.scrollTop = 0;
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
    var a = t.getAttribute("data-action");
    if (a === "reveal") { reveal(); return; }
    if (a === "answer") {
      root.querySelectorAll(".fc-btn").forEach(function (b) {
        b.setAttribute("disabled", "disabled");
      });
      FC.answer(t.getAttribute("data-rating"));
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
    renderSenses(FC.getCard());
    root.setAttribute("data-state", "front");
    if (FC.ready) FC.ready();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
