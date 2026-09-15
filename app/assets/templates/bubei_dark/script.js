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
      ttsSeq: function (list) {
        if (!("speechSynthesis" in window) || !list || !list.length) return;
        speechSynthesis.cancel();
        (function next(i) {
          if (i >= list.length) return;
          var it = list[i] || {};
          var u = new SpeechSynthesisUtterance(String(it.text || ""));
          u.lang = it.lang || "en-US"; u.rate = 0.95;
          u.onend = function () { next(i + 1); };
          speechSynthesis.speak(u);
        })(0);
      },
      ready: function () {}, mountCard: function () {}, onMount: function () {},
      ttsStop: function () {}
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
  var autoTtsTimer = null;  // 正面自动发音的定时器，进词义页时要清掉
  var passageTipTimer = null; // 语篇通读释义浮层定时器
  var blanks = [];            // 语篇选词：空格
  var bank = [];              // 语篇选词：词库
  var activeBlank = -1;       // 语篇选词：光标所在空格

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
    // 连点锁：切卡后 250ms 内的幽灵点击，即使落在选项上也一律忽略。
    // （root 上的委托监听检查了 clickLock，但选项按钮是直接绑的，
    //   事件在 target 阶段先于 root 冒泡执行，必须在这里再挡一道。）
    if (clickLock) return;
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

    // 答错 -> 切到词义页，把词 + 音标 + 词性 + 释义 + 例句完整看一遍（BUG-009）。
    //         这张卡后面仍会被重考，但中间不能只是干巴巴重复「选错 -> 下一题」。
    // 答对 -> 停在原题看红绿反馈，直接「继续」。
    if (!isRight) {
      root.setAttribute("data-state", "back");
      var backEl = root.querySelector(".fc-back");
      if (backEl) backEl.scrollTop = 0;
      playMeaningAudio();
    }

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
      // 转义正则元字符（a.m. / e.g. / (up)on 等），并只替换「整词、首次」。
      // 否则 act 会把 practice 挖成 pr______ice，new RegExp 还可能直接抛异常。
      var safe = w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      try { blank = raw.replace(new RegExp("\\b" + safe + "\\b", "i"), "______"); }
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

  // ---------- 语篇：把 segments 渲染成 DOM ----------
  function passageSegments() {
    var p = card.passage || {};
    return p.segments || [];
  }

  function passageText() {
    var t = "";
    passageSegments().forEach(function (seg) {
      t += (seg.w !== undefined && seg.w !== null) ? (seg.w + " ") : (seg.t || "");
    });
    return t;
  }

  function renderPassageRead() {
    var p = card.passage || {};
    var body = root.querySelector(".fc-passage .fc-passage-body");
    var titleEl = root.querySelector(".fc-passage .fc-passage-title");
    var cnEl = root.querySelector(".fc-passage .fc-passage-cn");
    var tip = root.querySelector(".fc-passage .fc-passage-tip");
    if (titleEl) titleEl.textContent = p.title || "语篇";
    if (cnEl) {
      cnEl.textContent = p.cn || "";
      cnEl.style.display = p.cn ? "block" : "none";
    }
    if (tip) tip.classList.remove("show");
    if (!body) return;
    body.innerHTML = "";

    passageSegments().forEach(function (seg) {
      if (seg.w !== undefined && seg.w !== null) {
        var span = document.createElement("span");
        span.className = "fc-pw";
        span.textContent = seg.w;
        span.setAttribute("data-word", seg.lemma || seg.w);
        span.setAttribute("data-pos", seg.pos || "");
        span.setAttribute("data-meaning", seg.meaning || "");
        body.appendChild(span);
      } else {
        body.appendChild(document.createTextNode(seg.t || ""));
      }
    });
  }

  function showPassageTooltip(el) {
    var w = el.getAttribute("data-word") || el.textContent || "";
    var pos = el.getAttribute("data-pos") || "";
    var mean = el.getAttribute("data-meaning") || "";
    speak(w, "en-US");
    var tip = root.querySelector(".fc-passage .fc-passage-tip");
    if (!tip) return;
    tip.innerHTML = "";
    var a = document.createElement("div");
    a.className = "fc-tip-word";
    a.textContent = w;
    var b = document.createElement("div");
    b.className = "fc-tip-mean";
    b.textContent = (pos ? pos + " " : "") + (mean || "（本章未收录释义）");
    tip.appendChild(a);
    tip.appendChild(b);
    tip.classList.add("show");
    if (passageTipTimer) clearTimeout(passageTipTimer);
    passageTipTimer = setTimeout(function () { tip.classList.remove("show"); }, 3000);
  }

  // ---------- 语篇选词（多邻国式填词） ----------
  function renderPassageCloze() {
    var p = card.passage || {};
    var titleEl = root.querySelector(".fc-passage-cloze .fc-passage-title");
    var body = root.querySelector(".fc-cloze-passage");
    if (titleEl) titleEl.textContent = p.title || "语篇选词";
    if (!body) return;
    body.innerHTML = "";
    blanks = [];
    bank = [];
    activeBlank = -1;

    passageSegments().forEach(function (seg) {
      if (seg.w !== undefined && seg.w !== null) {
        var idx = blanks.length;
        var b = document.createElement("span");
        b.className = "fc-blank";
        b.setAttribute("data-idx", String(idx));
        b.textContent = "______";
        b.addEventListener("click", function () { onTapBlank(idx); });
        body.appendChild(b);
        blanks.push({
          el: b, answer: seg.w, pos: seg.pos || "",
          meaning: seg.meaning || "", filled: null
        });
        bank.push({ surface: seg.w, used: false, el: null });
      } else {
        body.appendChild(document.createTextNode(seg.t || ""));
      }
    });

    renderBank();
    setActiveBlank(firstEmptyBlank());
    updateClozeContinue();
  }

  function renderBank() {
    var box = root.querySelector(".fc-wordbank");
    if (!box) return;
    box.innerHTML = "";
    var order = [];
    for (var i = 0; i < bank.length; i++) order.push(i);
    for (var k = order.length - 1; k > 0; k--) {
      var j = Math.floor(Math.random() * (k + 1));
      var t = order[k]; order[k] = order[j]; order[j] = t;
    }
    order.forEach(function (i) {
      var tile = document.createElement("button");
      tile.className = "fc-bank-tile";
      tile.type = "button";
      tile.textContent = bank[i].surface;
      tile.addEventListener("click", function () { onPickTile(i); });
      bank[i].el = tile;
      box.appendChild(tile);
    });
  }

  function firstEmptyBlank() {
    for (var i = 0; i < blanks.length; i++) {
      if (blanks[i].filled === null) return i;
    }
    return -1;
  }

  function onTapBlank(idx) {
    if (clickLock) return;
    if (idx < 0 || idx >= blanks.length) return;
    if (blanks[idx].filled !== null) return;
    setActiveBlank(idx);
  }

  function setActiveBlank(i) {
    activeBlank = i;
    blanks.forEach(function (b, k) {
      if (b.el) b.el.classList.toggle("is-active", k === i && b.filled === null);
    });
    var hint = root.querySelector(".fc-blank-hint");
    if (!hint) return;
    if (i < 0) {
      hint.textContent = "全部填好，点「继续」过关";
    } else {
      var b = blanks[i];
      hint.textContent = "当前空：" + ((b.pos ? b.pos + " " : "") + (b.meaning || "（无语义）"));
    }
  }

  function onPickTile(i) {
    if (clickLock) return;
    var tile = bank[i];
    if (!tile || tile.used) return;
    if (activeBlank < 0 || blanks[activeBlank].filled !== null) {
      setActiveBlank(firstEmptyBlank());
    }
    if (activeBlank < 0) return;
    var blank = blanks[activeBlank];
    if (blank.filled !== null) return;

    if (String(tile.surface).toLowerCase() === String(blank.answer).toLowerCase()) {
      blank.filled = tile.surface;
      if (blank.el) {
        blank.el.textContent = tile.surface;
        blank.el.classList.remove("is-active");
        blank.el.classList.add("is-filled");
      }
      tile.used = true;
      if (tile.el) {
        tile.el.classList.add("is-used");
        tile.el.setAttribute("disabled", "disabled");
      }
      speak(blank.answer, "en-US");
      setActiveBlank(firstEmptyBlank());
      updateClozeContinue();
    } else {
      if (tile.el) {
        tile.el.classList.add("is-wrong");
        setTimeout(function () { if (tile.el) tile.el.classList.remove("is-wrong"); }, 450);
      }
      if (blank.el) {
        blank.el.classList.add("is-wrong");
        setTimeout(function () { if (blank.el) blank.el.classList.remove("is-wrong"); }, 450);
      }
    }
  }

  function updateClozeContinue() {
    var done = blanks.length > 0 && blanks.every(function (b) { return b.filled !== null; });
    var btn = root.querySelector(".fc-btn-continue");
    if (done) {
      pendingAnswer = "good";
      if (btn) btn.removeAttribute("disabled");
    } else {
      pendingAnswer = null;
      if (btn) btn.setAttribute("disabled", "disabled");
    }
  }

  // ---------- 进词义页：先念单词，念完再念例句 ----------
  function playMeaningAudio() {
    // 清掉切卡时挂起的正面自动发音，避免和这里的顺序播放打架
    if (autoTtsTimer) { clearTimeout(autoTtsTimer); autoTtsTimer = null; }
    var seq = [];
    var w = String(fields.word || "").trim();
    if (w) seq.push({ text: w, lang: "en-US" });
    var sent = String(fields.sentence_en || "")
      .replace(/<[^>]*>/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (sent) seq.push({ text: sent, lang: "en-US" });
    if (seq.length && FC.ttsSeq) FC.ttsSeq(seq);
  }

  // ---------- 切换到词义页（read 模式） ----------
  function toMeaning(pre) {
    preRating = pre || "good";
    root.setAttribute("data-pre", preRating);
    root.setAttribute("data-state", "back");
    var backEl = root.querySelector(".fc-back");
    if (backEl) backEl.scrollTop = 0;
    playMeaningAudio();
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

    // 5. 重置按钮状态：
    //    - 上一张卡答完时把词义页「记错了 / 下一词」禁用了，切卡必须重新放开，
    //      否则第二张卡点「下一词」毫无反应（disabled 按钮不触发 click，整个卡死）。
    //      以前整页重载会自然清掉，SPA 增量挂卡后 DOM 复用，必须手动复位。
    //    - 底部「继续」按钮重置为禁用，等选了选项再亮。
    root.querySelectorAll(".fc-actions button").forEach(function (b) {
      b.removeAttribute("disabled");
    });
    var continueBtn = root.querySelector(".fc-btn-continue");
    if (continueBtn) {
      continueBtn.setAttribute("disabled", "disabled");
    }

    // 6. 词义页所有模式都渲染 —— choice / cloze 答错要切到 back 看完整词义，
    //    此时 .fc-back 的词性 / 释义 / 例句 / 短语 / 词根必须已经填好。
    renderBackFace();
    if (mode === "passage") {
      renderPassageRead();
    } else if (mode === "passage_cloze") {
      renderPassageCloze();
    } else if (mode === "choice") {
      renderChoiceOptions();
    } else if (mode === "cloze") {
      renderCloze();
    }

    // 7. 自动播放当前单词发音（用户强烈需求！）
    //    cloze 例外：答案就是这个单词，一进卡就念 = 直接泄题。
    if (autoTtsTimer) { clearTimeout(autoTtsTimer); autoTtsTimer = null; }
    if (FC.ttsStop) FC.ttsStop(); // 切卡先掐断上一张可能还在念的语音
    if (curWord && mode !== "cloze") {
      autoTtsTimer = setTimeout(function () {
        autoTtsTimer = null;
        speak(curWord, "en-US");
      }, 70);
    } else if (mode === "passage") {
      // 语篇通读：进页自动朗读全文（保持旧版「进卡即读」的听感）
      autoTtsTimer = setTimeout(function () {
        autoTtsTimer = null;
        speak(passageText(), "en-US");
      }, 260);
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

    // 2b. 语篇通读：点小喇叭 -> 朗读全文
    var ttsPassage = e.target.closest('[data-role="tts-passage"]');
    if (ttsPassage) {
      e.stopPropagation();
      speak(passageText(), "en-US");
      return;
    }

    // 2c. 语篇通读：点划线目标词 -> 浮释义 + 发音
    var pwTarget = e.target.closest(".fc-pw");
    if (pwTarget) {
      e.stopPropagation();
      showPassageTooltip(pwTarget);
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

    // 语篇通读 -> 进入单词背诵
    if (act === "start-drill") {
      if (actionTarget.hasAttribute("disabled")) return;
      actionTarget.setAttribute("disabled", "disabled");
      FC.answer("good");
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
    // 真机：骨架页首帧 __FLASHCARD_CARD__ 是空壳（id 为空），先不渲染空卡，
    //       等原生 mountCard 灌入真实数据（onMount 回调里再 mount）。
    // 预览 mock：没有注入 __FLASHCARD_CARD__，直接渲染。
    var injected = window.__FLASHCARD_CARD__;
    if (injected && !injected.id) return;
    mount();
    console.log("[bubei_dark v2] mounted mode=" + mode);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
