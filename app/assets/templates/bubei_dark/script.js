/* ============================================================
   不背单词 · 暗黑极简模板 · 交互脚本（v2 大改版）
   ------------------------------------------------------------
   对标设计：
     1. Choice 考法对标图 1：大卡片、正误红绿高亮、揭晓英文单词、继续按钮
     2. 词义页对标图 2：无限长页滚动、真题例句大卡片
     3. 自动发音：进入卡片自动调用系统 TTS 发音当前单词
     4. SPA 架构：mount() 完整挂载数据，带 250ms 连点防抖门锁
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
      ready: function () {}, mountCard: function () {}, onMount: function () {}
    };
  }

  var root = document.querySelector(".fc-root");
  if (!root) return;

  var card = {};
  var fields = {};
  var sess = {};
  var mode = "read";
  var choices = [];
  var preRating = "good";
  var pendingAnswer = null; // 'good' | 'again'
  var clickLock = false;

  // ---------- 朗读纯文本 ----------
  function speak(text, lang) {
    var say = String(text || "")
      .replace(/<[^>]*>/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (say) FC.tts(say, lang || "en-US");
  }

  // ---------- 渲染词义页的各个区块 ----------
  function renderBackFace() {
    // 词义
    var posEl = root.querySelector(".fc-back .fc-pos");
    var meanEl = root.querySelector(".fc-back .fc-mean-text");
    if (posEl) posEl.textContent = fields.pos || "";
    if (meanEl) meanEl.textContent = fields.meaning || "";

    // 真题例句
    var sentBlock = root.querySelector(".fc-sentence-block");
    var enEl = root.querySelector(".fc-en-sentence");
    var cnEl = root.querySelector(".fc-cn-sentence");
    if (fields.sentence_en && fields.sentence_en.trim()) {
      if (enEl) enEl.innerHTML = fields.sentence_en;
      if (cnEl) cnEl.textContent = fields.sentence_cn || "";
      if (sentBlock) sentBlock.style.display = "block";
    } else {
      if (sentBlock) sentBlock.style.display = "none";
    }

    // 常用短语
    var phraseBlock = root.querySelector(".fc-phrases-block");
    var phraseList = root.querySelector(".fc-phrase-list");
    var phrases = fields.phrases || [];
    if (Array.isArray(phrases) && phrases.length > 0) {
      if (phraseList) {
        phraseList.innerHTML = "";
        phrases.forEach(function (p) {
          var item = document.createElement("div");
          item.className = "fc-phrase-item";
          var en = document.createElement("span");
          en.className = "fc-phrase-en";
          en.textContent = p.en || "";
          var cn = document.createElement("span");
          cn.className = "fc-phrase-cn";
          cn.textContent = p.cn || "";
          item.appendChild(en);
          item.appendChild(cn);
          phraseList.appendChild(item);
        });
      }
      if (phraseBlock) phraseBlock.style.display = "block";
    } else {
      if (phraseBlock) phraseBlock.style.display = "none";
    }

    // 词根词源
    var rootBlock = root.querySelector(".fc-root-block");
    var rootEl = root.querySelector(".fc-root-content");
    if (fields.root && fields.root.trim()) {
      if (rootEl) rootEl.innerHTML = fields.root;
      if (rootBlock) rootBlock.style.display = "block";
    } else {
      if (rootBlock) rootBlock.style.display = "none";
    }
  }

  // ---------- choice 考法：渲染四大选项卡片（对标图 1） ----------
  function renderChoiceOptions() {
    var box = root.querySelector('.fc-options[data-for="choice"]');
    if (!box) return;
    box.innerHTML = "";

    choices.forEach(function (c) {
      var btn = document.createElement("button");
      btn.className = "fc-opt-btn";
      btn.type = "button";
      var isRight = (c.right === "true" || c.right === true);
      btn.setAttribute("data-right", String(isRight));

      // 选完后揭晓的真实英文单词（图 1 核心亮点！）
      var revealEl = document.createElement("div");
      revealEl.className = "fc-opt-revealed-word";
      revealEl.textContent = c.word || (isRight ? (fields.word || "") : "");
      btn.appendChild(revealEl);

      // 主体：词性 + 释义
      var mainEl = document.createElement("div");
      mainEl.className = "fc-opt-main";

      if (c.pos) {
        var posEl = document.createElement("span");
        posEl.className = "fc-opt-pos";
        posEl.textContent = c.pos;
        mainEl.appendChild(posEl);
      }

      var textEl = document.createElement("span");
      textEl.className = "fc-opt-text";
      textEl.textContent = c.text || "";
      mainEl.appendChild(textEl);

      btn.appendChild(mainEl);

      // 点击选项
      btn.addEventListener("click", function () {
        handleChoicePick(btn, box, isRight);
      });

      box.appendChild(btn);
    });
  }

  // ---------- 用户点击选项处理（图 1 红绿反馈） ----------
  function handleChoicePick(pickedBtn, box, isRight) {
    if (pendingAnswer !== null) return;
    pendingAnswer = isRight ? "good" : "again";

    // 禁用所有选项，并标色
    var allBtns = box.querySelectorAll(".fc-opt-btn");
    allBtns.forEach(function (b) {
      b.setAttribute("disabled", "disabled");
      var right = (b.getAttribute("data-right") === "true");
      if (right) {
        b.classList.add("is-right");
      } else if (b === pickedBtn) {
        b.classList.add("is-wrong");
      } else {
        b.classList.add("is-dimmed");
      }
    });

    // 激活底部的「继续」大按钮
    var continueBtn = root.querySelector(".fc-btn-continue");
    if (continueBtn) {
      continueBtn.removeAttribute("disabled");
    }
  }

  // ---------- cloze 填空考法 ----------
  function renderCloze() {
    var raw = String(fields.sentence_en || "").replace(/<[^>]+>/g, "");
    var w = String(fields.word || "");
    var blank = raw;
    if (w) {
      try { blank = raw.replace(new RegExp(w, "ig"), "______"); }
      catch (e) { blank = raw; }
    }
    var box = root.querySelector(".fc-cloze-box");
    if (box) box.textContent = blank;

    // 渲染 cloze 选项
    var optBox = root.querySelector('.fc-options[data-for="cloze"]');
    if (!optBox) return;
    optBox.innerHTML = "";

    choices.forEach(function (c) {
      var btn = document.createElement("button");
      btn.className = "fc-opt-btn";
      btn.type = "button";
      var isRight = (c.right === "true" || c.right === true);
      btn.setAttribute("data-right", String(isRight));

      var mainEl = document.createElement("div");
      mainEl.className = "fc-opt-main";
      var textEl = document.createElement("span");
      textEl.className = "fc-opt-text";
      textEl.textContent = c.text || c.word || "";
      mainEl.appendChild(textEl);
      btn.appendChild(mainEl);

      btn.addEventListener("click", function () {
        handleChoicePick(btn, optBox, isRight);
      });
      optBox.appendChild(btn);
    });
  }

  // ---------- 切换到词义页（read 模式） ----------
  function toMeaning(pre) {
    preRating = pre || "good";
    root.setAttribute("data-pre", preRating);
    root.setAttribute("data-state", "back");
    var backEl = root.querySelector(".fc-back");
    if (backEl) backEl.scrollTop = 0;
  }

  // ---------- mount：增量刷新全部卡片数据 ----------
  function mount() {
    card = FC.getCard() || {};
    fields = card.fields || {};
    sess = card.session || {};
    mode = sess.mode || "read";
    choices = card.choices || [];
    preRating = "good";
    pendingAnswer = null;

    var curWord = fields.word || card.id || "";
    var curSyllable = fields.syllable || curWord;
    var phonetic = fields.phonetic_us || fields.phonetic_uk || "";

    // 1. 设置根状态
    root.setAttribute("data-mode", mode);
    root.setAttribute("data-state", "front");
    root.setAttribute("data-pre", "");

    // 2. 顶栏更新
    var counterEl = root.querySelector(".fc-counter");
    if (counterEl) {
      var idx = (card.index !== undefined) ? (card.index + 1) : 1;
      var tot = card.total || 1;
      counterEl.textContent = idx + " / " + tot;
    }
    var tagEl = root.querySelector(".fc-tag");
    var tagText = root.querySelector(".fc-tag-text");
    if (tagEl && tagText) {
      if (fields.exam_tag) {
        tagText.textContent = fields.exam_tag;
        tagEl.style.display = "inline-flex";
      } else {
        tagEl.style.display = "none";
      }
    }

    // 3. 刷新正面与所有单词标题
    root.querySelectorAll(".fc-word:not(.fc-word-syllable)").forEach(function (el) {
      el.textContent = curWord;
    });
    var sylEl = root.querySelector(".fc-word-syllable");
    if (sylEl) sylEl.textContent = curSyllable;

    // 4. 音标胶囊刷新
    root.querySelectorAll(".fc-pill-us .fc-phonetic-text").forEach(function (el) {
      el.textContent = phonetic ? ("/" + phonetic.replace(/^\/|\/$/g, "") + "/") : "";
    });

    // 5. 重置底部「继续」按钮为禁用
    var continueBtn = root.querySelector(".fc-btn-continue");
    if (continueBtn) {
      continueBtn.setAttribute("disabled", "disabled");
    }

    // 6. 分模式渲染考法区域
    if (mode === "read") {
      renderBackFace();
    } else if (mode === "choice") {
      renderChoiceOptions();
    } else if (mode === "cloze") {
      renderCloze();
    }

    // 7. 自动播放当前单词发音（用户强烈需求！）
    if (curWord) {
      setTimeout(function () {
        speak(curWord, "en-US");
      }, 70);
    }
  }

  // ---------- 全局点击事件代理 ----------
  root.addEventListener("click", function (e) {
    if (clickLock) {
      e.preventDefault();
      return;
    }

    // 1. 点击单词或音标胶囊 -> 发音
    var ttsWordTarget = e.target.closest('[data-role="tts-word"], .fc-word, .fc-tts');
    if (ttsWordTarget) {
      e.stopPropagation();
      speak(fields.word || "", "en-US");
      return;
    }

    // 2. 点击例句小喇叭 -> 朗读例句
    var ttsSentTarget = e.target.closest('[data-role="tts-sentence"]');
    if (ttsSentTarget) {
      e.stopPropagation();
      speak(fields.sentence_en || "", "en-US");
      return;
    }

    // 3. 底部操作按钮
    var actionTarget = e.target.closest("[data-action]");
    if (!actionTarget) return;

    var act = actionTarget.getAttribute("data-action");

    // 正面自评 -> 进词义页
    if (act === "to-meaning") {
      toMeaning(actionTarget.getAttribute("data-pre"));
      return;
    }

    // 词义页打分落盘
    if (act === "answer") {
      var r = actionTarget.getAttribute("data-rating");
      var fin = (r === "again") ? "again" : preRating;
      root.querySelectorAll(".fc-actions-back .fc-btn").forEach(function (b) {
        b.setAttribute("disabled", "disabled");
      });
      FC.answer(fin);
      return;
    }

    // choice / cloze 点击「继续」
    if (act === "submit") {
      if (pendingAnswer === null) return;
      actionTarget.setAttribute("disabled", "disabled");
      FC.answer(pendingAnswer);
      return;
    }
  });

  // ---------- 键盘空格快捷键 ----------
  document.addEventListener("keydown", function (e) {
    if (e.code === "Space" || e.code === "Enter") {
      e.preventDefault();
      if (mode === "read") {
        if (root.getAttribute("data-state") === "front") toMeaning("good");
      } else if (pendingAnswer !== null) {
        var cb = root.querySelector(".fc-btn-continue");
        if (cb && !cb.hasAttribute("disabled")) {
          cb.setAttribute("disabled", "disabled");
          FC.answer(pendingAnswer);
        }
      }
    }
  });

  // ---------- SPA 挂载回调 ----------
  if (FC.onMount) {
    FC.onMount(function () {
      clickLock = true;
      setTimeout(function () { clickLock = false; }, 250);
      mount();
      if (FC.ready) FC.ready();
    });
  }

  // ---------- 首次启动 ----------
  function boot() {
    mount();
    console.log("[bubei_dark v2] mounted mode=" + mode);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
