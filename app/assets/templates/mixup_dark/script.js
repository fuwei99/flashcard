/* ============================================================
   形近词辨析 · 暗黑模板 · 交互脚本
   ------------------------------------------------------------
   两段式流程：
     正面  点【记错了】-> pre=again -> 词义页只剩【下一词】
           点【模糊】  -> pre=hard  -> 词义页【记错了】+【下一词】
           点【记得】  -> pre=good  -> 词义页【记错了】+【下一词】
     词义页 点【记错了】-> 改判 again
           点【下一词】-> 提交 pre 那个评分
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

  var preRating = "good"; // 正面预判

  // ---------- 渲染义项块 ----------
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

  // ---------- 翻到词义页 ----------
  function toMeaning(pre) {
    preRating = pre || "good";
    root.setAttribute("data-pre", preRating);   // CSS 靠它决定是否显示【记错了】
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

    // 正面三档：一律进词义页，记录预判
    if (a === "to-meaning") {
      toMeaning(t.getAttribute("data-pre"));
      return;
    }

    // 词义页：这里才评分
    if (a === "answer") {
      var r = t.getAttribute("data-rating");
      var final = (r === "again") ? "again" : preRating;
      root.querySelectorAll(".fc-actions-back .fc-btn").forEach(function (b) {
        b.setAttribute("disabled", "disabled");
      });
      FC.answer(final);
    }
  });

  // 空格/回车 = 进词义页（正面时，按 good 预判）
  document.addEventListener("keydown", function (e) {
    if (e.code === "Space" || e.code === "Enter") {
      e.preventDefault();
      if (root.getAttribute("data-state") === "front") toMeaning("good");
    }
  });

  // ---------- 渲染 ----------
  function render() {
    renderSenses(FC.getCard());
    root.setAttribute("data-state", "front");
    root.setAttribute("data-pre", "");
  }

  // SPA 增量挂卡：原生切卡 -> mountCard -> 这里重渲染。
  // 以前没有这段，切卡后画面永远停在上一张（模板等于废的）。
  if (FC.onMount) {
    FC.onMount(function () {
      render();
      if (FC.ready) FC.ready();
    });
  }

  // ---------- 初始化 ----------
  function boot() {
    // 真机骨架页首帧是空壳（id 为空），等原生 mountCard 灌数据后再渲染
    var injected = window.__FLASHCARD_CARD__;
    if (injected && !injected.id) return;
    render();
    if (FC.ready) FC.ready();
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
