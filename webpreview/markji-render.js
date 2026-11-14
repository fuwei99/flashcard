/* ============================================================================
   markji-render.js —— 从 templates/markji_v1/script.js 抽出的纯渲染器
   ----------------------------------------------------------------------------
   只管「墨墨语法文本 -> HTML」这一件事：块级 / 行内 / 挖空 / 选择题 / 公式 / 答案线。
   注意：**网站知识点卡的真身是 sourceHtml（带彩色 <strong> 的 HTML），不走这个**；
   这个渲染器服务的是真题卡和 01..10_*.txt 那套自写语法卡。
   改 templates/markji_v1/script.js 里的 MJ 段后，务必同步本文件。
   ========================================================================== */
(function (root) {
  "use strict";

root.Markji = (function () {
  
  var ESC_L = "\u0001", ESC_R = "\u0002";   // \[ \] 的占位符

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  /* ---------------------------------------------------------------- 行内 */

  // 先把 \[ \] 换成占位符，解析完再还原，避免被当成语法括号
  function protect(s) {
    return s.replace(/\\\[/g, ESC_L).replace(/\\\]/g, ESC_R);
  }
  function unprotect(s) {
    return s.replace(new RegExp(ESC_L, "g"), "[").replace(new RegExp(ESC_R, "g"), "]");
  }

  // 文字样式参数 → class / style
  function styleAttrs(params) {
    var cls = [], style = [], bgLum = -1, hasFg = false;
    String(params || "").split(",").forEach(function (p) {
      p = p.trim();
      if (!p) return;
      if (p === "B") cls.push("mj-b");
      else if (p === "I") cls.push("mj-i");
      else if (p === "U") cls.push("mj-u");
      else if (p === "D") cls.push("mj-d");
      else if (p === "up") cls.push("mj-up");
      else if (p === "down") cls.push("mj-down");
      else if (/^!![0-9a-f]{6}$/i.test(p)) {
        var bg = p.slice(2).toLowerCase();
        style.push("background:#" + bg);
        bgLum = 0.299 * parseInt(bg.slice(0, 2), 16) +
                0.587 * parseInt(bg.slice(2, 4), 16) +
                0.114 * parseInt(bg.slice(4, 6), 16);
      }
      else if (/^![0-9a-f]{6}$/i.test(p)) { style.push("color:#" + p.slice(1).toLowerCase()); hasFg = true; }
      else if (/^link\//.test(p)) {
        var m = /^link\/"([^"]*)"/.exec(p);
        if (m) cls.push("mj-link:" + m[1]);
      }
    });
    // 只给了背景色、没给文字色时按亮度配字：
    // 亮底（浅黄/浅绿高亮）压深字，暗底压浅字 —— 否则深色主题下就是白字糊在浅黄上
    if (bgLum >= 0 && !hasFg) style.push(bgLum >= 140 ? "color:#1f2329" : "color:#f0f4f5");
    return { cls: cls, style: style.join(";") };
  }

  /**
   * 行内解析。一次性从左到右扫，命中标签就替换，避免嵌套误伤。
   * 支持 T / F / E / Audio / Card；不支持的标签原样保留。
   */
  function inline(raw, state) {
    var s = protect(String(raw == null ? "" : raw));
    var out = "", i = 0, guard = 0;

    while (i < s.length && guard++ < 20000) {
      var open = s.indexOf("[", i);
      if (open < 0) { out += s.slice(i); break; }
      out += s.slice(i, open);

      // 找匹配的右括号（内容里不许有未转义的 ]，语法本身也不允许嵌套）
      var close = s.indexOf("]", open + 1);
      if (close < 0) { out += s.slice(open); break; }

      var body = s.slice(open + 1, close);
      var p1 = body.indexOf("#");
      var p2 = p1 < 0 ? -1 : body.indexOf("#", p1 + 1);
      if (p1 < 0 || p2 < 0) { out += esc(unprotect(s.slice(open, close + 1))); i = close + 1; continue; }

      var name = body.slice(0, p1), params = body.slice(p1 + 1, p2), content = body.slice(p2 + 1);

      if (name === "T") {
        var a = styleAttrs(params), link = null;
        a.cls = a.cls.filter(function (c) {
          if (c.indexOf("mj-link:") === 0) { link = c.slice(8); return false; }
          return true;
        });
        var inner = esc(unprotect(content));
        var html = '<span class="mj-t ' + a.cls.join(" ") + '"' +
          (a.style ? ' style="' + a.style + '"' : "") + ">" + inner + "</span>";
        if (link) html = '<a href="' + esc(link) + '" target="_blank" rel="noopener">' + html + "</a>";
        out += html;

      } else if (name === "F") {
        var g = /^\d+$/.test(params.trim()) ? params.trim() : "1";
        out += '<span class="mj-f pc-blank" data-g="' + g + '" role="button" tabindex="0">' +
               '<span class="mj-f-t">' + esc(unprotect(content)) + "</span></span>";

      } else if (name === "E") {
        out += '<span class="mj-eq" data-tex="' + esc(unprotect(content)) + '"></span>';

      } else if (name === "Audio") {
        out += '<span class="mj-audio" title="音频">🔊 ' + esc(unprotect(content)) + "</span>";

      } else if (name === "Card") {
        out += '<span class="mj-card" title="关联卡片">🔗 ' + esc(unprotect(content)) + "</span>";

      } else {
        // 未知标签：原样输出（不吞内容，方便发现语法写错）
        out += esc(unprotect(s.slice(open, close + 1)));
      }
      i = close + 1;
    }
    return unprotect(out);
  }

  /* ---------------------------------------------------------------- 块级 */

  function renderChoice(lines, params) {
    var multi = /multi/.test(params), fixed = /fixed/.test(params);
    var opts = lines.map(function (ln) {
      var m = /^([*-])\s+(.*)$/.exec(ln.trim());
      return m ? { ok: m[1] === "*", text: m[2] } : null;
    }).filter(Boolean);
    if (!opts.length) return "";

    var correct = opts.filter(function (o) { return o.ok; }).length;
    var html = '<div class="mj-choice' + (multi ? " mj-multi" : "") + '" data-fixed="' + (fixed ? 1 : 0) + '">';
    html += '<div class="mj-choice-hint">' + (multi ? "多选 · 选完看答案" : "单选") + "</div>";
    opts.forEach(function (o, idx) {
      html += '<div class="mj-opt" data-ok="' + (o.ok ? 1 : 0) + '" data-i="' + idx + '">' +
        '<span class="mj-opt-mark">' + String.fromCharCode(65 + idx) + "</span>" +
        '<span class="mj-opt-t">' + inline(o.text) + "</span></div>";
    });
    html += '<div class="mj-choice-foot" data-correct="' + correct + '"></div></div>';
    return html;
  }

  function renderBlockLine(line, state) {
    var m;

    // [P#params#content]
    if ((m = /^\[P#([^#\]]*)#([\s\S]*)\]$/.exec(line))) {
      var params = m[1], content = m[2];
      var cls = ["mj-p"], style = [];
      params.split(",").forEach(function (p) {
        p = p.trim();
        if (p === "H1") cls.push("mj-h1");
        else if (p === "L") cls.push("mj-li");
        else if (/^I\d+$/.test(p)) style.push("margin-left:" + (parseInt(p.slice(1), 10) * 1.6) + "em");
        else if (p === "center") cls.push("mj-center");
        else if (p === "right") cls.push("mj-right");
        else if (p === "left") cls.push("mj-left");
      });
      return '<div class="' + cls.join(" ") + '"' + (style.length ? ' style="' + style.join(";") + '"' : "") + ">" +
             inline(content) + "</div>";
    }

    // 独立公式 [E##...]
    if ((m = /^\[E##([\s\S]*)\]$/.exec(line))) {
      return '<div class="mj-eq-block" data-tex="' + esc(unprotect(m[1])) + '"></div>';
    }

    // 图片 [Pic#params#] —— 这里没有 file.id 解析能力，先留占位
    if ((m = /^\[Pic#([^#]*)#\]$/.exec(line))) {
      return '<div class="mj-pic" data-id="' + esc(m[1]) + '">🖼 图片 ' + esc(m[1]) + "</div>";
    }

    // 普通段落
    return '<div class="mj-p">' + inline(line) + "</div>";
  }

  /* ---------------------------------------------------------------- 主函数 */

  function render(text, opts) {
    opts = opts || {};
    var lines = String(text == null ? "" : text).replace(/\r\n?/g, "\n").split("\n");

    var frontLines = [], backLines = [], inBack = false;
    var i = 0;

    while (i < lines.length) {
      var line = lines[i];

      // 答案线
      if (/^-{3,}$/.test(line.trim()) && !inBack) { inBack = true; i++; continue; }

      // 选择题：跨行收集到独占一行的 ]
      var cm = /^\[Choice#([^#\]]*)#\s*$/.exec(line);
      if (cm) {
        var buf = [], j = i + 1;
        while (j < lines.length && lines[j].trim() !== "]") { buf.push(lines[j]); j++; }
        var ch = renderChoice(buf, cm[1]);
        (inBack ? backLines : frontLines).push(ch);
        i = j + 1;
        continue;
      }

      // 空行只当分隔，不产出空段落
      if (!line.trim()) { i++; continue; }

      var html = renderBlockLine(line, {});
      if (html) (inBack ? backLines : frontLines).push(html);
      i++;
    }

    // 正面只有标题 + 一行提示时，把「问题」当正面没问题；
    // 纯挖空卡（无 ---）正面就是全部内容，背面留空。
    return {
      front: frontLines.join("\n"),
      back: backLines.join("\n"),
      hasAnswerLine: inBack
    };
  }

  /* ---------------------------------------------------------------- 交互 */

  function bindCloze(scope) {
    if (!scope || scope.__mjBound) return;
    scope.__mjBound = true;
    scope.addEventListener("click", function (e) {
      var t = e.target.closest ? e.target.closest(".mj-f") : null;
      if (t) t.classList.toggle("on");
    });
    scope.addEventListener("keydown", function (e) {
      if (e.key !== "Enter" && e.key !== " ") return;
      var t = e.target.closest ? e.target.closest(".mj-f") : null;
      if (t) { t.classList.toggle("on"); e.preventDefault(); }
    });
  }

  function bindChoice(scope) {
    if (!scope || scope.__mjChoiceBound) return;
    scope.__mjChoiceBound = true;
    scope.addEventListener("click", function (e) {
      var opt = e.target.closest ? e.target.closest(".mj-opt") : null;
      if (!opt) return;
      var box = opt.closest(".mj-choice");
      if (!box) return;
      if (box.classList.contains("mj-multi")) opt.classList.toggle("mj-picked");
      else {
        box.querySelectorAll(".mj-opt").forEach(function (o) { o.classList.remove("mj-picked"); });
        opt.classList.add("mj-picked");
      }
    });
  }


    return { render: render, inline: inline, bind: function (s) { bindCloze(s); bindChoice(s); } };
  })();

  if (typeof module !== "undefined" && module.exports) {
    module.exports = root.Markji;
  }
})(typeof window !== "undefined" ? window
   : typeof globalThis !== "undefined" ? globalThis : this);
