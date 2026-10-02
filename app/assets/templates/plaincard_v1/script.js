/* ============================================================================
   plaincard_v1 · 渲染层
   ----------------------------------------------------------------------------
   分工（这套模板是「壳出能力、模板出流程」的样板）：
     script.js    只干一件事：把一张卡的字段变成 DOM。不认识队列、不认识调度。
     workflow.js  才是司机：排队、交评级、报进度、存断点。

   三层渲染契约（内容作者的三个档位，从省事到自由）：
     ① 结构化原语   type + front/back/cloze/cover/media  —— 90% 的卡都够用
     ② markdown-lite  **粗体** ==高亮== `代码` - 列表      —— front/back/detail 里直接写
     ③ HTML 逃生舱  字段 `html`                            —— 整段原样注入，排版自己说了算

   公式不是「卡型」，是**所有文本字段都可用的能力**：写完 DOM 交给 KaTeX 扫。
   ========================================================================== */
(function () {
  "use strict";

  var root, body, inner, frontEl, backEl, detailEl, mnemonicEl,
      chipsEl, srcEl, flipBtn, detailBtn, rateRow;

  var card = null;
  var onRate = null;

  // ---------------------------------------------------------------- 工具

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function txt(v) { return String(v == null ? "" : v); }

  /** 行内格式：转义 + 粗体 / 高亮 / 代码。**不碰公式**。 */
  function inlineFmt(s) {
    return esc(s)
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
      .replace(/==([^=]+)==/g, '<span class="pc-mark">$1</span>')
      .replace(/`([^`]+)`/g, '<span class="pc-code">$1</span>');
  }

  /**
   * 文本块 → HTML。
   *
   * 关键：**单行不包 <p>**。
   * 因为挖空/遮盖会把一句话切成若干段分别处理（“最大应力在” + 空 + “处”），
   * 每段都包一层 <p> 的话，那个空就变成块级元素的兄弟节点、被顶到自己
   * 一行去 —— 一句话被硬拆成三行，填空卡直接报废。
   * 所以：单行 → 纯行内；多行 → 才走段落 / 列表。
   */
  function mdBlock(raw) {
    var s = txt(raw);
    if (s.indexOf("\n") < 0) return inlineFmt(s);

    var lines = s.split("\n");
    var out = [];
    var listType = null; // 'ul' | 'ol'

    function closeList() { if (listType) { out.push("</" + listType + ">"); listType = null; } }

    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].trim();
      if (t === "") { closeList(); continue; }

      var mOl = /^(\d+)[.、)]\s+(.*)$/.exec(t);
      var mUl = /^[-*·]\s+(.*)$/.exec(t);
      if (mUl) {
        if (listType !== "ul") { closeList(); out.push("<ul>"); listType = "ul"; }
        out.push("<li>" + inlineFmt(mUl[1]) + "</li>");
        continue;
      }
      if (mOl) {
        if (listType !== "ol") { closeList(); out.push("<ol>"); listType = "ol"; }
        out.push('<li value="' + mOl[1] + '">' + inlineFmt(mOl[2]) + "</li>");
        continue;
      }
      closeList();
      out.push("<p>" + inlineFmt(t) + "</p>");
    }
    closeList();
    return out.join("");
  }

  /**
   * 标记语法（在 markdown-lite **之前**扫，两者顺序不能反）：
   *   {{c1::答案}}         挖空 —— 点一下揭
   *   {{c1::答案::提示}}   挖空带提示（提示常显，答案藏）
   *   [[文字]]             遮盖 —— 点一下揭
   *   [[文字::提示]]       遮盖带提示
   *
   * 为什么复用 Anki 的 `{{cN::}}` 而不是自创：Anki 生态里几十万张挖空卡都是
   * 这个语法，转换脚本一行不用改。`c1`/`c2` 的分组语义我们暂时不用
   * （一张卡 = 一个调度单元，不是「一个空 = 一个调度单元」）。
   */
  var MARK_RE = /\{\{c(\d+)::([\s\S]*?)(?:::\s*([\s\S]*?))?\}\}|\s*\[\[([\s\S]*?)(?:::\s*([\s\S]*?))?\]\]/g;

  function renderInline(raw) {
    var s = txt(raw);
    var out = "";
    var last = 0;
    var m;
    MARK_RE.lastIndex = 0;
    var i = 0;
    while ((m = MARK_RE.exec(s)) !== null) {
      out += mdBlock(s.slice(last, m.index));
      i++;
      if (m[1] != null) {
        // {{cN::答案::提示}}
        var hint = m[3] ? '<span class="pc-hint">' + esc(m[3]) + "</span>" : "";
        out += '<span class="pc-blank" data-blank="' + i + '">' +
               '<span class="pc-val">' + esc(m[2]) + "</span>" + hint + "</span>";
      } else {
        // [[遮住::提示]]
        var h2 = m[5] ? '<span class="pc-hint">' + esc(m[5]) + "</span>" : "";
        out += '<span class="pc-cover" data-blank="' + i + '">' +
               '<span class="pc-val">' + esc(m[4]) + "</span>" + h2 + "</span>";
      }
      last = m.index + m[0].length;
    }
    out += mdBlock(s.slice(last));
    return out;
  }

  // ---------------------------------------------------------------- 公式

  /**
   * 扫一遍 DOM 把 $…$ / $$…$$ 渲染掉。
   * 用 KaTeX 官方的 auto-render：它知道怎么跳过 <code>/<pre>/已渲染的 .katex，
   * 自己写一遍遍历一定会漏这两种。
   *
   * 失败不能炸卡片：KaTeX 抛错（写错一个 \frac）时保持原文可见 ——
   * 看到 `\frac{a}{b}` 总比看到一片空白强，至少知道是哪里写错了。
   */
  function renderMath(el, delims) {
    if (!el || !window.renderMathInElement || !window.katex) return 0;
    try {
      window.renderMathInElement(el, {
        delimiters: delims || [
          { left: "$$", right: "$$", display: true },
          { left: "\\[", right: "\\]", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\(", right: "\\)", display: false }
        ],
        throwOnError: false,
        errorColor: "#ff6b6b",
        ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code", "option"]
      });
      return el.querySelectorAll(".katex").length;
    } catch (e) {
      if (window.Flashcard && Flashcard.log) Flashcard.log("math", "渲染失败: " + e);
      return 0;
    }
  }

  // ---------------------------------------------------------------- 媒体

  function mediaNode(item) {
    var kind = txt(item.kind || item.type || "image").toLowerCase();
    var src = txt(item.src || item.url || "");
    if (!src) return null;

    var wrap = document.createElement("div");
    wrap.className = "pc-media";

    if (kind === "audio") {
      var au = document.createElement("audio");
      au.controls = true;
      au.src = src;
      wrap.appendChild(au);
    } else {
      var img = document.createElement("img");
      img.alt = txt(item.caption || "");
      img.src = src;
      wrap.appendChild(img);
      img.addEventListener("click", function () {
        // 点一下全屏看细节（解剖图 / 电路图那种）
        img.style.maxHeight = (img.style.maxHeight === "none") ? "46vh" : "none";
      });
    }
    if (item.caption) {
      var cap = document.createElement("div");
      cap.className = "cap";
      cap.textContent = item.caption;
      wrap.appendChild(cap);
    }
    return wrap;
  }

  /**
   * 本地图片 → data-uri。
   * 卡里的 src 写相对路径（如 `media/gearbox.png`，相对 Documents/Flashcard/），
   * 因为页面是 loadHtmlString 灌进来的、**没有 baseUrl**，相对路径一定 404。
   * 壳那边 media.get 读文件转 base64 回来。
   */
  function resolveMedia(el, list) {
    var raw = list || [];
    var nodes = [];
    for (var i = 0; i < raw.length; i++) {
      var n = mediaNode(raw[i]);
      if (n) nodes.push({ node: n, item: raw[i] });
    }
    nodes.forEach(function (p) { el.appendChild(p.node); });

    // http(s) / data: 直接能用；其余走壳换 data-uri
    nodes.forEach(function (p) {
      var src = txt(p.item.src || p.item.url || "");
      if (/^(https?:|data:|file:)/i.test(src)) return;
      var img = p.node.querySelector("img,audio");
      if (!img) return;
      Flashcard.call("media.get", { path: src }).then(function (r) {
        if (r && r.ok) img.src = r.data_uri;
        else if (window.Flashcard && Flashcard.log) {
          Flashcard.log("media", "取图失败 " + src + " → " + (r && r.error));
        }
      }).catch(function (e) {
        if (window.Flashcard && Flashcard.log) Flashcard.log("media", "取图异常 " + src + " " + e);
      });
    });
  }

  // ---------------------------------------------------------------- TTS

  function ttsButton(getText) {
    var b = document.createElement("button");
    b.className = "pc-btn-speak";
    b.type = "button";
    b.textContent = "🔊";
    b.title = "朗读";
    b.addEventListener("click", function () {
      var t = getText();
      if (t) Flashcard.tts(t, "en-US");
    });
    return b;
  }

  // ---------------------------------------------------------------- 渲染

  function setState(s) {
    root.setAttribute("data-state", s);
    if (s === "back") {
      // 翻面后把内容区拉回顶部：长答案直接从第一行开始读
      body.scrollTop = 0;
    }
  }

  function revealAll() {
    var els = inner.querySelectorAll(".pc-blank, .pc-cover");
    for (var i = 0; i < els.length; i++) els[i].classList.add("on");
  }

  function bindBlanks() {
    var els = inner.querySelectorAll(".pc-blank, .pc-cover");
    for (var i = 0; i < els.length; i++) {
      (function (el) {
        el.addEventListener("click", function (ev) {
          ev.stopPropagation();
          el.classList.toggle("on");
        });
      })(els[i]);
    }
  }

  function chips(fields, type) {
    chipsEl.innerHTML = "";
    var tagLabel = { qa: "问答", cloze: "挖空", mask: "遮盖", point: "要点", sentence: "句子" };
    if (tagLabel[type]) {
      var c0 = document.createElement("span");
      c0.className = "pc-chip t-" + type;
      c0.textContent = tagLabel[type];
      chipsEl.appendChild(c0);
    }
    var tags = fields.tags;
    if (typeof tags === "string") tags = tags.split(/[,，、;；]/);
    if (tags instanceof Array) {
      for (var i = 0; i < tags.length && i < 4; i++) {
        var t = txt(tags[i]).trim();
        if (!t) continue;
        var c = document.createElement("span");
        c.className = "pc-chip";
        c.textContent = t;
        chipsEl.appendChild(c);
      }
    }
    srcEl.textContent = txt(fields.source || "");
  }

  /**
   * 挂一张卡。ctx 里是壳给的环境（book / engine / scene / index / total…）。
   * 返回一个统计对象，workflow.js 拿去写日志。
   */
  function mount(c, ctx) {
    card = c || {};
    var f = card.fields || {};
    ctx = ctx || {};

    var type = txt(f.type || "qa").toLowerCase();
    root.setAttribute("data-type", type);
    root.removeAttribute("data-detail");
    setState(ctx.state === "back" ? "back" : "front");

    chips(f, type);
    inner.innerHTML = "";
    inner.className = "pc-inner";

    // ---- ③ 逃生舱：html 字段直接接管内容区 ----
    if (txt(f.html).trim()) {
      root.setAttribute("data-mode", "raw");
      inner.innerHTML = f.html;   // 作者自己负责排版；下面的结构化槽位全跳过
      return { raw: true };
    }
    root.removeAttribute("data-mode");

    // ---- ① + ② 结构化渲染 ----
    var frontHtml = "";
    if (txt(f.front).trim()) frontHtml += renderInline(f.front);
    // cloze 卡：没有 front 就把挖空句当正面
    if (txt(f.cloze).trim()) frontHtml += renderInline(f.cloze);
    // mask 卡：正文放正面，遮盖已经在里面
    if (txt(f.cover).trim()) frontHtml += renderInline(f.cover);
    if (!frontHtml) frontHtml = '<p class="pc-empty">（这张卡没有正面内容）</p>';

    var frontSec = document.createElement("section");
    frontSec.className = "pc-front";
    frontSec.innerHTML = frontHtml;
    // 英文内容给个朗读键
    if (/[A-Za-z]{4,}/.test(frontSec.textContent || "")) {
      frontSec.appendChild(ttsButton(function () { return frontSec.textContent; }));
    }
    inner.appendChild(frontSec);

    var ansSec = document.createElement("section");
    ansSec.className = "pc-answer";

    var backEl = document.createElement("div");
    backEl.className = "pc-back";
    backEl.innerHTML = renderInline(f.back || "") ||
      '<span class="pc-empty">（没有背面）</span>';
    ansSec.appendChild(backEl);

    var detailHtml = renderInline(f.detail || "");
    if (detailHtml.trim()) {
      var d = document.createElement("div");
      d.className = "pc-detail";
      d.innerHTML = detailHtml;
      ansSec.appendChild(d);
      detailBtn.hidden = false;
    } else {
      detailBtn.hidden = true;
    }

    if (txt(f.mnemonic).trim()) {
      var mn = document.createElement("div");
      mn.className = "pc-mnemonic";
      mn.innerHTML = renderInline(f.mnemonic);
      ansSec.appendChild(mn);
    }

    inner.appendChild(ansSec);

    var mediaWrap = document.createElement("div");
    inner.appendChild(mediaWrap);
    resolveMedia(mediaWrap, f.media);

    bindBlanks();

    // ---- 公式：所有文本字段都过一遍 ----
    var n = renderMath(inner, (ctx.math && ctx.math.delimiters) || undefined);
    return { math: n, type: type };
  }

  // ---------------------------------------------------------------- 事件

  function init() {
    root = document.getElementById("pc-root");
    if (!root) return;
    body = document.getElementById("pcBody");
    inner = document.getElementById("pcInner");
    chipsEl = document.getElementById("pcChips");
    srcEl = document.getElementById("pcSrc");
    flipBtn = document.getElementById("pcFlip");
    detailBtn = document.getElementById("pcDetailBtn");
    rateRow = document.getElementById("pcRateRow");

    flipBtn.addEventListener("click", function () { API.flip(); });
    root.addEventListener("click", function (ev) {
      // 点空白处也能翻面（只往前翻，不来回跳）
      if (ev.target.closest(".pc-blank,.pc-cover,button,img,a,audio")) return;
      if (root.getAttribute("data-state") === "front") API.flip();
    });
    detailBtn.addEventListener("click", function () {
      var on = root.getAttribute("data-detail") === "on";
      if (on) root.removeAttribute("data-detail");
      else root.setAttribute("data-detail", "on");
      detailBtn.textContent = on ? "详解" : "收起详解";
    });

    var btns = rateRow.querySelectorAll(".pc-rate");
    for (var i = 0; i < btns.length; i++) {
      (function (b) {
        b.addEventListener("click", function () {
          var r = b.getAttribute("data-rating");
          if (onRate) onRate(r);
        });
      })(btns[i]);
    }

    // 物理键盘（桌面预览 / 平板接键盘时很好用）
    document.addEventListener("keydown", function (ev) {
      if (ev.target && /INPUT|TEXTAREA/.test(ev.target.tagName)) return;
      var k = ev.key;
      var map = { "1": "again", "2": "hard", "3": "good", "4": "easy" };
      if (k === " " || k === "Enter") { ev.preventDefault(); API.flip(); return; }
      if (k === "r") { revealAll(); return; }
      if (map[k] && root.getAttribute("data-state") === "back") {
        onRate && onRate(map[k]);
      }
    });
  }

  var API = {
    mount: mount,
    flip: function () {
      if (root.getAttribute("data-state") !== "front") return;
      setState("back");
      revealAll();  // 翻面即全揭：挖空/遮盖的交互在「正面自测」时才有意义
    },
    revealAll: revealAll,
    onRate: function (fn) { onRate = fn; },
    /** workflow.js 用：把四档的下次间隔写成按钮上的小字 */
    setPreview: function (map) {
      ["again", "hard", "good", "easy"].forEach(function (k) {
        var el = document.getElementById("pcG-" + k);
        if (!el) return;
        el.textContent = (map && map[k]) ? map[k] : "";
      });
    },
    /** workflow.js 用：刚交完评级，先锁住按钮防连点 */
    lock: function (v) { rateRow.style.pointerEvents = v ? "none" : ""; },
    current: function () { return card; }
  };

  window.PC = API;

  // 给测试用的口子：纯函数（不碰 DOM 的那些）挂出来，
  // `node webpreview/plaincard_test.js` 直接怼这几个。
  // 不导出的话，这两个解析器就只能靠肉眼在手机上验收 —— 那种验收一定会漏。
  API.__test = {
    esc: esc,
    inlineFmt: inlineFmt,
    mdBlock: mdBlock,
    renderInline: renderInline,
    MARK_RE: MARK_RE
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
