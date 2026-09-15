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
      tts: function (t, o) {
        if (!("speechSynthesis" in window)) return;
        var lang = (o && typeof o === "object") ? (o.lang || "en-US") : (o || "en-US");
        var rate = (o && typeof o === "object" && o.rate) ? (0.95 * o.rate) : 0.95;
        speechSynthesis.cancel();
        var u = new SpeechSynthesisUtterance(t);
        u.lang = lang; u.rate = rate; speechSynthesis.speak(u);
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
  var wrongToMeaning = false; // 答错后：先看错误项释义，点「继续」才进词义页

  // ---------- TTS 路由（改这里就能换：词 / 句 / 文章各走各的）----------
  var TTS_WORD     = { plugin: "doubao", voice: "zh_female_wenroutaozi_v2_mars_bigtts", cache: true };   // 单词：豆包·温柔桃子，落盘
  var TTS_SENTENCE = { plugin: "doubao", voice: "zh_male_cixingjunyu_uranus_bigtts",  cache: false };  // 例句：豆包·磁性君语，不落盘
  var TTS_PASSAGE  = { plugin: "system", cache: false };  // 文章：系统 TTS，不落盘

  // ---------- 朗读纯文本 ----------
  function speak(text, lang, opts) {
    var say = String(text || "")
      .replace(/<[^>]*>/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (!say) return;
    var o = Object.assign({ lang: lang || "en-US" }, opts || {});
    FC.tts(say, o);
  }

  // ---------- 词义页：义项列表 ----------
  // 一词多义 / 一词多性在这里逐条渲染。
  // 老数据（只有 pos + meaning 两个字符串）被折成一条，不改 json 也能看。
  function sensesOf() {
    var raw = fields.senses;
    var out = [];
    if (Array.isArray(raw)) {
      raw.forEach(function (s) {
        if (s && typeof s === "object") {
          var cn = String(s.cn || s.meaning || "").trim();
          if (!cn) return;
          out.push({
            pos: String(s.pos || "").trim(),
            cn: cn,
            phonetic: String(s.phonetic_us || s.phonetic || "").trim()
          });
        } else if (typeof s === "string" && s.trim()) {
          out.push({ pos: "", cn: s.trim(), phonetic: "" });
        }
      });
    }
    if (!out.length) {
      var cn0 = String(fields.meaning || "").trim();
      if (cn0) {
        out.push({ pos: String(fields.pos || "").trim(), cn: cn0, phonetic: "" });
      }
    }
    return out;
  }

  function renderSenses() {
    var box = root.querySelector(".fc-back .fc-senses");
    if (!box) return;
    box.innerHTML = "";
    var list = sensesOf();
    list.forEach(function (s) {
      var row = document.createElement("div");
      row.className = "fc-sense";
      if (s.pos) {
        var p = document.createElement("span");
        p.className = "fc-pos";
        p.textContent = s.pos;
        row.appendChild(p);
      }
      var t = document.createElement("span");
      t.className = "fc-mean-text";
      t.textContent = s.cn;
      row.appendChild(t);
      // 多音词：义项自带音标就顺带显示
      if (s.phonetic) {
        var ph = document.createElement("span");
        ph.className = "fc-sense-phonetic";
        ph.textContent = "/" + s.phonetic.replace(/^\/|\/$/g, "") + "/";
        row.appendChild(ph);
      }
      box.appendChild(row);
    });
    box.style.display = list.length ? "" : "none";
  }

  // ---------- 词义页：真题例句（固定字段，cloze 也读它） ----------
  function renderSentence() {
    var sentBlock = root.querySelector(".fc-sentence-block");
    var enEl = root.querySelector(".fc-en-sentence");
    var cnEl = root.querySelector(".fc-cn-sentence");
    if (String(fields.sentence_en || "").trim()) {
      if (enEl) enEl.innerHTML = fields.sentence_en;
      if (cnEl) cnEl.textContent = fields.sentence_cn || "";
      if (sentBlock) sentBlock.style.display = "block";
    } else {
      if (sentBlock) sentBlock.style.display = "none";
    }
  }

  // ---------- 词义页：扩展块 ----------
  // 模板**不认识任何业务字段**，只按 block 的 type 渲染。
  // 以后要加「近义词 / 反义词 / 词形变化 / 易混词」，
  // 只在 json 里加一个 block 就行 —— 不用动这里，更不用重编 APK。
  var BLOCK_BODY = {
    // 富文本（词根词源、辨析说明）
    html: function (b) { return String(b.html || b.text || ""); },
    // 纯段落（转义）
    text: function (b) { return escHtml(b.text || b.html || ""); },
    // 单列列表：["thorough", "concentrated"]
    list: function (b) {
      var items = b.items || [];
      if (!items.length) return "";
      var s = '<ul class="fc-block-list">';
      items.forEach(function (it) {
        var o = blockItem(it);
        s += "<li>" + escHtml(o.left) +
             (o.right ? '<span class="fc-block-cn">' + escHtml(o.right) + "</span>" : "") +
             "</li>";
      });
      return s + "</ul>";
    },
    // 左右两列：[{en, cn}] 或 [{k, v}]
    pairs: function (b) {
      var items = b.items || [];
      if (!items.length) return "";
      var s = '<div class="fc-block-pairs">';
      items.forEach(function (it) {
        var o = blockItem(it);
        s += '<div class="fc-block-pair">' +
             '<span class="fc-pair-l">' + escHtml(o.left) + "</span>" +
             '<span class="fc-pair-r">' + escHtml(o.right) + "</span></div>";
      });
      return s + "</div>";
    },
    // 表格：{cols:["原形","过去式"], rows:[["go","went"]]}
    table: function (b) {
      var cols = b.cols || [], rows = b.rows || [];
      if (!cols.length && !rows.length) return "";
      var s = '<table class="fc-block-table">';
      if (cols.length) {
        s += "<thead><tr>";
        cols.forEach(function (c) { s += "<th>" + escHtml(c) + "</th>"; });
        s += "</tr></thead>";
      }
      s += "<tbody>";
      rows.forEach(function (r) {
        s += "<tr>";
        (r || []).forEach(function (c) { s += "<td>" + escHtml(c) + "</td>"; });
        s += "</tr>";
      });
      return s + "</tbody></table>";
    },
    // 图片：{src, alt}
    image: function (b) {
      if (!b.src) return "";
      return '<img class="fc-block-img" src="' + escHtml(b.src) +
             '" alt="' + escHtml(b.alt || "") + '">';
    }
  };

  // 注意：这里用 "&" + "amp;" 拼出来，
  // 不直接写实体字面量 —— 避免脚本/补丁工具把 & 实体解码掉。
  var AMP = "&" + "amp;", LT = "&" + "lt;", GT = "&" + "gt;", QUOT = "&" + "quot;";

  function escHtml(s) {
    return String(s === undefined || s === null ? "" : s)
      .replace(/&/g, AMP)
      .replace(/</g, LT)
      .replace(/>/g, GT)
      .replace(/"/g, QUOT);
  }

  /// 把 block 的 items 元素归一成 {left, right}
  function blockItem(it) {
    if (it === undefined || it === null) return { left: "", right: "" };
    if (typeof it !== "object") return { left: String(it), right: "" };
    if (it.en !== undefined || it.cn !== undefined) {
      return { left: String(it.en || ""), right: String(it.cn || "") };
    }
    if (it.k !== undefined || it.v !== undefined) {
      return { left: String(it.k || ""), right: String(it.v || "") };
    }
    if (it.left !== undefined || it.right !== undefined) {
      return { left: String(it.left || ""), right: String(it.right || "") };
    }
    var ks = Object.keys(it);
    if (ks.length === 1) return { left: ks[0], right: String(it[ks[0]] || "") };
    return { left: "", right: "" };
  }

  /// 未知 type 不崩：按内容退化渲染（html → 列表 → 表格 → 纯文本）
  function blockBody(b) {
    var fn = BLOCK_BODY[String(b.type || "").toLowerCase()];
    if (fn) return fn(b);
    if (b.html) return String(b.html);
    if (b.text) return escHtml(b.text);
    if (Array.isArray(b.items) && b.items.length) return BLOCK_BODY.list(b);
    if (Array.isArray(b.rows) && b.rows.length) return BLOCK_BODY.table(b);
    return "";
  }

  /// 归一化 blocks：
  ///   新格式直接用 fields.blocks；
  ///   老格式（phrases / root 平铺在字段上）现场折成 block ——
  ///   用户手里的老书不改 json 也能正常渲染。
  function blocksOf(f) {
    var out = [];
    if (Array.isArray(f.blocks)) {
      f.blocks.forEach(function (b) {
        if (b && typeof b === "object") out.push(b);
      });
    }
    if (out.length) return out;
    if (Array.isArray(f.phrases) && f.phrases.length) {
      out.push({ type: "pairs", title: "常用短语", items: f.phrases });
    }
    if (f.root && String(f.root).trim()) {
      out.push({ type: "html", title: "词根词源", html: f.root });
    }
    return out;
  }

  function renderBlocks() {
    var host = root.querySelector(".fc-back .fc-blocks");
    if (!host) return;
    host.innerHTML = "";
    var tpl = document.getElementById("fc-block-tpl");
    blocksOf(fields).forEach(function (b) {
      var body = blockBody(b);
      if (!body) return;
      var block = (tpl && tpl.content && tpl.content.firstElementChild)
        ? tpl.content.firstElementChild.cloneNode(true)
        : null;
      if (!block) {
        block = document.createElement("div");
        block.className = "fc-card-block";
        block.innerHTML =
          '<div class="fc-block-header"><span class="fc-block-title"></span></div>' +
          '<div class="fc-block-body"></div>';
      }
      var title = String(b.title || "").trim();
      var titleEl = block.querySelector(".fc-block-title");
      if (titleEl) titleEl.textContent = title;
      var headerEl = block.querySelector(".fc-block-header");
      if (headerEl) headerEl.style.display = title ? "" : "none";
      var bodyEl = block.querySelector(".fc-block-body");
      if (bodyEl) bodyEl.innerHTML = body;
      host.appendChild(block);
    });
  }

  // ---------- 固定卡片：派生词 / 近义词 / 反义词 ----------
  // 这三个是**固定字段**（不是 blocks）：每条 = 词 + 词性释义，形状一致，
  // 所以共用一套归一化与渲染。多词性 = 多条 senses。
  //
  // 宽容读取（json 里少写哪样都不崩）：
  //   {word, senses:[{pos,cn}]}  |  {word, pos, cn}  |  "word"
  function relatedOf(key) {
    var raw = fields[key];
    if (!Array.isArray(raw)) return [];
    var out = [];
    raw.forEach(function (it) {
      if (it === null || it === undefined) return;
      if (typeof it === "string") {
        if (it.trim()) out.push({ word: it.trim(), senses: [] });
        return;
      }
      if (typeof it !== "object") return;
      var w = String(it.word || it.en || it.k || "").trim();
      var senses = [];
      var rawS = it.senses || it.meanings;
      if (Array.isArray(rawS)) {
        rawS.forEach(function (s) {
          if (s && typeof s === "object") {
            var cn = String(s.cn || s.meaning || "").trim();
            if (cn) senses.push({ pos: String(s.pos || "").trim(), cn: cn });
          } else if (typeof s === "string" && s.trim()) {
            senses.push({ pos: "", cn: s.trim() });
          }
        });
      }
      if (!senses.length) {
        var cn0 = String(it.cn || it.meaning || it.v || "").trim();
        if (cn0) senses.push({ pos: String(it.pos || "").trim(), cn: cn0 });
      }
      if (!w && !senses.length) return;
      out.push({ word: w, senses: senses });
    });
    return out;
  }

  // 一条关联词：左边词，右边逐条「词性 + 释义」
  function relatedRowHtml(item) {
    var s = '<div class="fc-rel-row">';
    s += '<div class="fc-rel-word" data-say="' + escHtml(item.word) + '">' +
         escHtml(item.word) + "</div>";
    if (item.senses.length) {
      s += '<div class="fc-rel-senses">';
      item.senses.forEach(function (x) {
        s += '<div class="fc-rel-sense">' +
             (x.pos ? '<span class="fc-rel-pos">' + escHtml(x.pos) + "</span>" : "") +
             '<span class="fc-rel-cn">' + escHtml(x.cn) + "</span></div>";
      });
      s += "</div>";
    }
    return s + "</div>";
  }

  // groups = [{label, items}]；全空则整张卡隐藏
  function renderRelated(blockSel, bodySel, groups) {
    var block = root.querySelector(blockSel);
    var body = root.querySelector(bodySel);
    if (!block || !body) return;
    var html = "";
    groups.forEach(function (g) {
      if (!g.items || !g.items.length) return;
      html += '<div class="fc-rel-group">' +
              (g.label ? '<div class="fc-rel-label">' + escHtml(g.label) + "</div>" : "") +
              g.items.map(relatedRowHtml).join("") +
              "</div>";
    });
    body.innerHTML = html;
    block.style.display = html ? "" : "none";
  }

  function renderDerivatives() {
    renderRelated(".fc-deriv-block", ".fc-deriv-body",
      [{ label: "", items: relatedOf("derivatives") }]);
  }

  // 近义词和反义词**同一张卡**：各带小标题，谁有显示谁
  function renderThesaurus() {
    renderRelated(".fc-thes-block", ".fc-thes-body", [
      { label: "近义词", items: relatedOf("synonyms") },
      { label: "反义词", items: relatedOf("antonyms") }
    ]);
  }

  // ---------- 渲染词义页的各个区块 ----------
  function renderBackFace() {
    renderSenses();
    renderSentence();
    renderDerivatives();
    renderThesaurus();
    renderBlocks();
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
      btn.setAttribute("data-plain", c.plain || "");

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

    // 答完都读一遍正确选项。
    // cloze 进卡时故意不读（答案就是这个单词，读了直接泄题）；这里已经答完，可以读了。
    speak(fields.word || "", "en-US", TTS_WORD);

    if (isRight) {
      // 答对 -> 停在原题看绿色反馈，点「继续」进下一题
      wrongToMeaning = false;
    } else {
      // 答错 -> **不要**立刻跳词义页：先把「你选的那个」的中文意思亮出来，
      //         让你知道错在哪；点「继续」才去看完整词义。
      if (mode === "cloze") revealPickedMeaning(pickedBtn);
      wrongToMeaning = true;
    }

    // 激活底部的「继续」大按钮
    var continueBtn = root.querySelector(".fc-btn-continue");
    if (continueBtn) {
      continueBtn.removeAttribute("disabled");
      var lbl = continueBtn.querySelector("span");
      if (lbl) lbl.textContent = wrongToMeaning ? "看词义" : "继续";
    }
  }

  /// 在选错的那个选项上补一行中文释义，让用户知道自己选的是什么意思
  function revealPickedMeaning(btn) {
    if (!btn) return;
    var plain = btn.getAttribute("data-plain") || "";
    if (!plain) return;
    var el = btn.querySelector(".fc-opt-plain");
    if (!el) {
      el = document.createElement("div");
      el.className = "fc-opt-plain";
      btn.appendChild(el);
    }
    el.textContent = plain;
  }

  // ---------- cloze 填空考法 ----------
  // 常见变形后缀白名单：只有「词干 + 这些后缀」才认，
  // 避免 act 把 practice 误抠成 pr______ice。
  var BLANK_SUFFIXES = ["", "s", "es", "ed", "d", "ing", "ion", "ions", "ation",
    "ations", "ment", "ments", "ly", "ness", "er", "ers", "est", "ive", "ives",
    "al", "ally", "ence", "ance", "ful", "less", "ity", "ities", "ize", "ized",
    "izes", "izing", "t"];

  // 把例句里的目标词抠成 ______，返回 { text, answer }
  //
  //   1) 优先认 <u>/<b>/<em>/<strong> 标记 —— json 里已经像语篇一样把词划好线了，
  //      直接整段精准抠掉。这样 prevailed / provoked / endorsed 这些**变形词**
  //      也不会漏，不会再出现「匹配不上原形 → 空挖不出来 → 整句连答案一起显示」。
  //   2) 没有标记的老数据，退回「原形整词」匹配。
  //   3) 还没有，做变形兜底：词干 + 后缀白名单（comply→complied、impose→imposed…）。
  function blankSentence(raw, word) {
    var src = String(raw || "");
    var w = String(word || "").trim();

    // 1) 标记优先：数据里已经划好线了，精准抠
    var m = src.match(/<(u|b|em|strong)\b[^>]*>([\s\S]*?)<\/\1>/i);
    if (m) {
      var inner = m[2].replace(/<[^>]+>/g, "").trim();
      if (inner) {
        return {
          text: src.slice(0, m.index) + "______" + src.slice(m.index + m[0].length),
          answer: inner
        };
      }
    }

    var plain = src.replace(/<[^>]+>/g, "");
    if (!w) return { text: plain, answer: "" };

    // 2) 原形整词（转义 a.m. / e.g. / (up)on 这些正则元字符）
    var safe = w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    var re = null;
    try { re = new RegExp("\\b" + safe + "\\b", "i"); } catch (e) { re = null; }
    var hit = re ? plain.match(re) : null;
    if (hit) {
      return {
        text: plain.slice(0, hit.index) + "______" + plain.slice(hit.index + hit[0].length),
        answer: hit[0]
      };
    }

    // 3) 变形兜底：词干 + 后缀白名单
    var stem = w.toLowerCase();
    if (/y$/.test(stem) && !/[aeiou]y$/.test(stem)) stem = stem.slice(0, -1) + "i";
    else if (/e$/.test(stem)) stem = stem.slice(0, -1);

    var tokRe = /\b[A-Za-z][A-Za-z'’-]*\b/g, t;
    while ((t = tokRe.exec(plain)) !== null) {
      var low = t[0].toLowerCase();
      if (low.indexOf(stem) !== 0) continue;
      if (BLANK_SUFFIXES.indexOf(low.slice(stem.length)) < 0) continue;
      return {
        text: plain.slice(0, t.index) + "______" + plain.slice(t.index + t[0].length),
        answer: t[0]
      };
    }

    return { text: plain, answer: "" };
  }

  function renderCloze() {
    var rawSent = String(fields.sentence_en || "").trim();
    var box = root.querySelector(".fc-cloze-box");
    var optBox = root.querySelector('.fc-options[data-for="cloze"]');

    // 这张卡没有例句 —— 正常情况下会话编排已经把 cloze 考法对它跳过了，
    // 这里再兜一道，避免出现「空题干 + 没选项」的死页面。
    if (!rawSent) {
      if (box) box.textContent = "（本词没有例句，已跳过选词填空）";
      if (optBox) optBox.innerHTML = "";
      var contBtn = root.querySelector(".fc-btn-continue");
      if (contBtn) contBtn.removeAttribute("disabled");
      return;
    }

    var res = blankSentence(rawSent, fields.word || "");
    // 抠完再把残留的标签洗掉（______ 留着）
    var shown = res.text.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
    if (box) box.textContent = shown;

    // 渲染 cloze 选项
    if (!optBox) return;
    optBox.innerHTML = "";

    choices.forEach(function (c) {
      var btn = document.createElement("button");
      btn.className = "fc-opt-btn";
      btn.type = "button";
      var isRight = (c.right === "true" || c.right === true);
      btn.setAttribute("data-right", String(isRight));
      // cloze 的选项是英文词，答错时要补一行中文释义，让用户知道错在哪
      btn.setAttribute("data-plain", c.plain || "");

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
    speak(w, "en-US", TTS_WORD);
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
        // 今天不复习这个词（blank === false）：只作划线词展示，不挖空、不进词库
        if (seg.blank === false) {
          var pw = document.createElement("span");
          pw.className = "fc-pw";
          pw.textContent = seg.w;
          pw.setAttribute("data-word", seg.lemma || seg.w);
          pw.setAttribute("data-pos", seg.pos || "");
          pw.setAttribute("data-meaning", seg.meaning || "");
          body.appendChild(pw);
          return;
        }
        var idx = blanks.length;
        var b = document.createElement("span");
        b.className = "fc-blank";
        b.setAttribute("data-idx", String(idx));
        b.textContent = "______";
        b.addEventListener("click", function () { onTapBlank(idx); });
        body.appendChild(b);
        blanks.push({
          el: b, answer: seg.w, pos: seg.pos || "",
          meaning: seg.meaning || "", plain: seg.plain || "", filled: null
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
      // 用纯中文释义：带短语的完整释义会把答案（这个词本身）写进提示里
      hint.textContent = "当前空：" +
          ((b.pos ? b.pos + " " : "") + (b.plain || b.meaning || "（无语义）"));
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
      speak(blank.answer, "en-US", TTS_WORD);
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
    // blanks 为空（本批词在语篇里一个都没命中）也视为完成，避免卡死
    var done = blanks.every(function (b) { return b.filled !== null; });
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
    if (w) seq.push(Object.assign({ text: w, lang: "en-US" }, TTS_WORD));
    var sent = String(fields.sentence_en || "")
      .replace(/<[^>]*>/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (sent) seq.push(Object.assign({ text: sent, lang: "en-US" }, TTS_SENTENCE));
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
    wrongToMeaning = false;

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
      var continueLbl = continueBtn.querySelector("span");
      if (continueLbl) continueLbl.textContent = "继续";
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
        speak(curWord, "en-US", TTS_WORD);
      }, 70);
    } else if (mode === "passage") {
      // 语篇通读：进页自动朗读全文（保持旧版「进卡即读」的听感）
      autoTtsTimer = setTimeout(function () {
        autoTtsTimer = null;
        speak(passageText(), "en-US", TTS_PASSAGE);
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
      speak(fields.word || "", "en-US", TTS_WORD);
      return;
    }

    // 2. 点击例句小喇叭 -> 朗读例句
    var ttsSentTarget = e.target.closest('[data-role="tts-sentence"]');
    if (ttsSentTarget) {
      e.stopPropagation();
      speak(fields.sentence_en || "", "en-US", TTS_SENTENCE);
      return;
    }

    // 2b. 语篇通读：点小喇叭 -> 朗读全文
    var ttsPassage = e.target.closest('[data-role="tts-passage"]');
    if (ttsPassage) {
      e.stopPropagation();
      speak(passageText(), "en-US", TTS_PASSAGE);
      return;
    }

    // 2c. 语篇通读：点划线目标词 -> 浮释义 + 发音
    var pwTarget = e.target.closest(".fc-pw");
    if (pwTarget) {
      e.stopPropagation();
      showPassageTooltip(pwTarget);
      return;
    }

    // 2d. 关联词（派生词 / 近义词 / 反义词）点词 -> 发音
    var sayTarget = e.target.closest("[data-say]");
    if (sayTarget) {
      e.stopPropagation();
      speak(sayTarget.getAttribute("data-say") || "", "en-US", TTS_WORD);
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
      if (wrongToMeaning) {
        // 答错后点「继续」= 进词义页（按 again 计）。
        // 看完词义再点「下一词」才算真正作答 —— 这张卡后面仍会被重考。
        wrongToMeaning = false;
        pendingAnswer = null;
        toMeaning("again");
        return;
      }
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
