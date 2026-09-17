/* ============================================================
   Flashcard · 不背单词暗黑风 · 纯 JS（零依赖）
   流程：自评(认识/模糊/忘记) → 词义页 → 错词四选一重考 → 总结
   附加：收藏 / 标熟 / 笔记 / 拼写测验 / TTS 发音
   ============================================================ */
"use strict";

/* ================= 数据 ================= */
/* ================= 壳桥接 ================= */
var FC = window.Flashcard || null;
function fcCall(m, p) {
  if (!FC || !FC.call) return Promise.reject(new Error("no bridge"));
  return FC.call(m, p || {});
}
function fcTts(text, opts) {
  if (FC && FC.tts) { FC.tts(text, opts || {}); return; }
  try {
    window.speechSynthesis.cancel();
    var u = new SpeechSynthesisUtterance(String(text || ""));
    u.lang = "en-US";
    u.rate = 0.95;
    window.speechSynthesis.speak(u);
  } catch (e) {}
}

/* ================= 卡数据归一化 =================
   壳给的是书里的原始 fields（v3 形状：senses[].cn 是字符串、sentence_en 带 <u>、
   synonyms 是 [{word,senses}]……）。这里折成新版渲染要的 WordCard 形状。 */
function cnList(v) {
  if (v == null) return [];
  if (Array.isArray(v)) {
    var o = [];
    v.forEach(function (x) { o = o.concat(cnList(x)); });
    return o;
  }
  return String(v).split(/[；;，,、]\s*/).map(function (x) { return x.trim(); }).filter(Boolean);
}
function stripU(x) { return String(x || "").replace(/<\/?u\s*>/g, ""); }
function flatRel(items) {
  var out = [];
  (items || []).forEach(function (it) {
    if (typeof it === "string") { out.push({ word: it, pos: "", cn: [] }); return; }
    var w = String(it.word || "");
    var senses = it.senses || it.meanings;
    if (senses && senses.length) {
      senses.forEach(function (x) {
        out.push({ word: w, pos: String((x && x.pos) || ""), cn: cnList(x && x.cn) });
      });
    } else {
      out.push({ word: w, pos: String(it.pos || ""), cn: cnList(it.cn) });
    }
  });
  return out;
}
function wordsOf(items) {
  return flatRel(items).map(function (x) { return x.word; }).filter(Boolean);
}
function normCard(raw, fallbackId) {
  var f = (raw && raw.fields) ? raw.fields : (raw || {});
  var senses = [];
  (f.senses || []).forEach(function (x) {
    if (typeof x === "string") senses.push({ pos: "", cn: cnList(x) });
    else senses.push({ pos: String(x.pos || ""), cn: cnList(x.cn) });
  });
  var sen = (f.sentence && typeof f.sentence === "object")
    ? { en: stripU(f.sentence.en), cn: f.sentence.cn || "" }
    : { en: stripU(f.sentence_en), cn: f.sentence_cn || "" };

  var collocations = [], rootItems = [], rootSummary = "", exams = [], keep = [];
  (f.blocks || []).forEach(function (b) {
    var t = String((b && b.title) || "");
    var ty = String((b && b.type) || "").toLowerCase();
    if (ty === "pairs" && (t.indexOf("搭配") >= 0 || t.indexOf("短语") >= 0)) {
      (b.items || []).forEach(function (it) {
        if (it && typeof it === "object") {
          collocations.push({ en: String(it.en || it.k || it.left || ""), cn: String(it.cn || it.v || it.right || "") });
        }
      });
    } else if (t.indexOf("词根") >= 0 || t.indexOf("词源") >= 0) {
      var txt = String(b.text || b.html || "");
      rootSummary = txt;
      rootItems.push({ tag: "词根", text: txt });
    } else {
      keep.push(b);
    }
  });
  if (Array.isArray(f.collocations)) collocations = f.collocations;
  if (f.root && typeof f.root === "object" && !Array.isArray(f.root)) {
    rootItems = f.root.items || rootItems;
    rootSummary = f.root.summary || rootSummary;
  } else if (Array.isArray(f.root) && f.root.length) {
    rootItems = f.root;
  }
  if (Array.isArray(f.exams)) exams = f.exams;

  return {
    id: (raw && raw.id) || f.id || fallbackId || f.word || "",
    word: String(f.word || ""),
    syllable: f.syllable || "",
    phonetic: String(f.phonetic || f.phonetic_us || f.phonetic_uk || "").trim(),
    verified: !!(f.verified || f.phonetic_us),
    senses: senses,
    sentence: sen,
    collocations: collocations,
    derivatives: Array.isArray(f.derivatives) ? flatRel(f.derivatives) : [],
    synonyms: Array.isArray(f.synonyms) ? (typeof f.synonyms[0] === "string" ? f.synonyms.slice() : wordsOf(f.synonyms)) : [],
    antonyms: Array.isArray(f.antonyms) ? (typeof f.antonyms[0] === "string" ? f.antonyms.slice() : wordsOf(f.antonyms)) : [],
    root: rootItems,
    rootSummary: rootSummary,
    exams: exams,
    blocks: keep,
    tags: f.tags || [],
    _kv: (raw && raw.kv) || {}
  };
}

/* ================= 会话（自管一轮）================= */
var DECK = [];   /* boot() 里从壳拉 */

/* ================= 工具 ================= */
function speak(text, opts) {
  var say = String(text || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
  if (!say) return;
  fcTts(say, opts || { lang: "en-US", rate: 0.95 });
}

function shuffle(arr, seed) {
  var a = arr.slice(), s = seed, i, j, t;
  for (i = a.length - 1; i > 0; i--) {
    s = (s * 9301 + 49297) % 233280;
    j = Math.floor((s / 233280) * (i + 1));
    t = a[i]; a[i] = a[j]; a[j] = t;
  }
  return a;
}

function highlight(sentence, word) {
  return sentence.replace(new RegExp("(" + word + ")", "i"), "<b>$1</b>");
}

/* ================= SVG 图标 ================= */
var I = {
  speaker: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>',
  chevron: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
  undo: '<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/></svg>',
  star: function (filled) {
    return '<svg class="ico star" viewBox="0 0 24 24" fill="' + (filled ? "currentColor" : "none") +
      '" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6L12 16.7 6.6 19.6l1.1-6L3.2 9.4l6.1-.8L12 3z"/></svg>';
  },
  dots: '<svg class="ico" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.9"/><circle cx="12" cy="12" r="1.9"/><circle cx="19" cy="12" r="1.9"/></svg>',
  badge: '<svg viewBox="0 0 24 24"><path fill="#1db373" d="M12 1.6l2.1 1.8 2.7-.5 1 2.6 2.6 1-.5 2.7 1.8 2.1-1.8 2.1.5 2.7-2.6 1-1 2.6-2.7-.5-2.1 1.8-2.1-1.8-2.7.5-1-2.6-2.6-1 .5-2.7L1.6 12l1.8-2.1-.5-2.7 2.6-1 1-2.6 2.7.5L12 1.6z"/><path d="M8.4 12.2l2.3 2.3 4.6-4.7" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  noteAdd: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M4 20h7"/><path d="M14.5 4.5l3 3L8 17l-4 1 1-4 9.5-9.5z" stroke-linejoin="round"/><path d="M18 15v5M15.5 17.5h5" stroke-width="1.7"/></svg>',
  pencil: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 4.5l3 3L8 17l-4 1 1-4 9.5-9.5z"/></svg>',
  sentSwitch: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="14" rx="3.5"/><path d="M7.5 10h6M7.5 14h9"/></svg>',
  textSearch: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M4 6h13M4 11h7M4 16h5"/><circle cx="16.5" cy="15.5" r="3.4"/><path d="M19 18l2.4 2.4"/></svg>',
  close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>'
};

/* ================= 状态 ================= */
var S = {
  phase: "learn",          // learn | choice | done
  face: "front",           // front | back
  tab: "colloc",           // colloc | deriv | syn | root | note
  queue: DECK.slice(),
  idx: 0,
  pool: [],                // 错词重考池（存 id）
  ratings: {},             // id -> good | hard | again
  favs: {},                // id -> true
  notes: {},               // id -> 笔记文本
  knownCount: 0,
  rIdx: 0,
  revealed: false,
  picked: null,
  wrongs: 0,
  noteOpen: false,
  draft: "",
  spellOpen: false,
  spellInput: "",
  spellState: "idle",      // idle | right | wrong
  _options: []
};

function cur() { return S.queue[S.idx]; }
function retestCards() {
  return S.pool.map(function (id) {
    return DECK.filter(function (w) { return w.id === id; })[0];
  }).filter(Boolean);
}
function rCur() { return retestCards()[S.rIdx]; }
function activeWord() { return S.phase === "choice" ? rCur() : cur(); }

/* ================= 片段渲染 ================= */
function vTopbar() {
  var w = activeWord();
  if (!w) return "";
  var counter = S.phase === "learn"
    ? Math.min(S.idx + 1, S.queue.length) + "/" + S.queue.length
    : (S.rIdx + 1) + "/" + retestCards().length;
  var canUndo = S.phase === "learn" && S.idx > 0;
  return '<header class="topbar">' +
    '<button class="back" data-act="undo-noop">' + I.chevron +
      '<span class="counter">' + counter + "</span></button>" +
    '<div class="acts">' +
      '<button data-act="undo"><span class="' + (canUndo ? "" : "disabled") + '">' +
        I.undo.replace('class="ico"', 'class="ico' + (canUndo ? "" : " disabled") + '"') + "</span></button>" +
      '<button data-act="fav"><span class="' + (S.favs[w.id] ? "faved" : "") + '">' +
        I.star(!!S.favs[w.id]).replace('class="ico star"', 'class="ico star' + (S.favs[w.id] ? " faved" : "") + '"') + "</span></button>" +
      '<button class="tb-txt" data-act="known">熟</button>' +
      '<button class="tb-txt abc" data-act="spell-open">abc</button>' +
      "<button>" + I.dots + "</button>" +
    "</div></header>";
}

function vHero(w, syllable) {
  return '<div class="hero"><div class="word-wrap">' +
    "<h1>" + (syllable ? w.syllable : w.word) + "</h1>" +
    (w.verified ? '<span class="badge">' + I.badge + "</span>" : "") +
    "</div>" +
    '<div class="phon-row">' +
      '<button class="pill" data-act="speak-word"><span class="us">美</span>' + I.speaker + "</button>" +
      '<span class="phonetic">' + w.phonetic + "</span>" +
    "</div></div>";
}

function vSenseLine(w) {
  var html = '<div class="sense-line">';
  w.senses.forEach(function (s) {
    html += '<span class="pos">' + s.pos + "</span>";
    s.cn.forEach(function (m, mi) {
      html += '<span class="cn' + (mi === 0 ? " primary" : "") + '">' + m + "</span>";
    });
  });
  return html + "</div>";
}

function vDash(label, bar, act, dim) {
  return '<button class="dash-btn' + (dim ? " dim" : "") + '" data-act="' + act + '">' +
    "<b>" + label + "</b><i class=\"" + bar + "\"></i></button>";
}

/* ================= 各屏 ================= */
function vLearnFront(w) {
  return vTopbar() +
    '<div class="screen">' +
    '<div style="margin-top:52px" class="spacer-wrap">' + vHero(w, false) +
      '<div class="skeleton"><i class="sk-1"></i><i class="sk-2"></i></div></div>' +
    '<div class="spacer"></div>' +
    '<p class="hint">瞬间想起词义，选「认识」<br>思考后想起词义，选「模糊」</p>' +
    '<footer class="footer cols-3">' +
      vDash("认识", "bar-teal", "rate-good") +
      vDash("模糊", "bar-amber", "rate-hard") +
      vDash("忘记了", "bar-red", "rate-again") +
    "</footer></div>";
}

function vInfoBody(w) {
  var note = S.notes[w.id];
  if (S.tab === "colloc") {
    return w.collocations.map(function (c) {
      return '<p class="colloc-row"><span class="en">' + c.en + '</span><span class="cn">' + c.cn + "</span></p>";
    }).join("") +
    '<button class="more-link">学习所有考研真题词组 <span>›</span></button>';
  }
  if (S.tab === "deriv") {
    return (w.derivatives || []).map(function (d) {
      return '<p class="colloc-row"><span class="en">' + d.word + '</span>' +
        '<span class="pos">' + d.pos + '</span><span class="cn tight">' + d.cn + "</span></p>";
    }).join("");
  }
  if (S.tab === "syn") {
    var html = "";
    if (w.synonyms) html += '<p class="thes-row"><span class="tag">近义</span>' + w.synonyms.join(", ") + "</p>";
    if (w.antonyms) html += '<p class="thes-row"><span class="tag">反义</span>' + w.antonyms.join(", ") + "</p>";
    return html;
  }
  if (S.tab === "root") {
    return (w.root || []).map(function (r) {
      return '<p class="root-row"><span class="tag">' + r.tag + "</span>" + r.text + "</p>";
    }).join("") +
    (w.rootSummary ? '<p class="root-summary">' + w.rootSummary + "</p>" : "") +
    '<button class="more-link" style="margin-top:16px">查看更多同根词 <span>›</span></button>';
  }
  /* note */
  return '<p class="note-text">' + (note || "暂无笔记") + "</p>" +
    '<button class="note-edit-link" data-act="note-open">编辑笔记 ' + I.pencil + "</button>";
}

function vLearnBack(w) {
  var note = S.notes[w.id];
  var tabs = [["colloc", "词组搭配"], ["deriv", "派生"], ["syn", "近义"], ["root", "词根"]];
  if (note) tabs.push(["note", "笔记"]);
  var tabHtml = tabs.map(function (t) {
    return '<button class="tab' + (S.tab === t[0] ? " on" : "") + '" data-act="tab" data-arg="' + t[0] + '">' + t[1] + "</button>";
  }).join("");
  return vTopbar() +
    '<div class="screen">' +
    '<div class="detail-scroll">' +
      vHero(w, true) + vSenseLine(w) +
      '<div class="sent-card">' +
        '<p class="en">' + highlight(w.sentence.en, w.word) + "</p>" +
        '<p class="cn">' + w.sentence.cn + "</p>" +
        '<button class="circle-btn" data-act="speak-sentence">' + I.sentSwitch + "</button>" +
      "</div>" +
      '<div class="info-card">' +
        '<div class="info-body">' + vInfoBody(w) + "</div>" +
        '<div class="tabbar">' + tabHtml + '<span class="sp"></span>' +
          (!note ? '<button class="note-add" data-act="note-open">' + I.noteAdd + "</button>" : "") +
          '<button class="circle-btn">' + I.textSearch + "</button>" +
        "</div>" +
      "</div>" +
    "</div>" +
    '<footer class="footer cols-2">' +
      vDash("下一词", "bar-teal", "next") +
      vDash("记错了", "bar-red", "mistake") +
    "</footer></div>";
}

function vChoice(w) {
  var others = shuffle(DECK.filter(function (x) { return x.id !== w.id; }), w.id.charCodeAt(1) * 17).slice(0, 3);
  S._options = shuffle([w].concat(others), w.word.length * 31 + S.rIdx * 7);
  var opts = S._options.map(function (o, i) {
    var isRight = o.id === w.id;
    var sense = o.senses[0];
    if (!S.revealed) {
      return '<button class="opt" data-act="pick" data-arg="' + i + '">' +
        '<span class="o-pos">' + sense.pos + "</span>" +
        '<span class="o-cn">' + sense.cn.join("；") + "</span></button>";
    }
    return '<div class="opt revealed ' + (isRight ? "right" : "wrong") + '">' +
      '<span class="o-word">' + o.word + "</span>" +
      '<span class="o-sense">' + sense.pos + " " + sense.cn.join("；") + "</span>" +
      (isRight ? '<button class="o-note" data-act="note-open">' + I.noteAdd + "</button>" : "") +
      "</div>";
  }).join("");
  var feedback = "";
  if (S.revealed && S.picked !== null) {
    feedback = '<p class="feedback">' +
      (S._options[S.picked].id === w.id ? "回答正确" : "记错了，已加入复习") + "</p>";
  }
  return vTopbar() +
    '<div class="screen">' +
    '<div class="detail-scroll" style="padding-top:52px">' +
      vHero(w, false) + '<div class="spacer" style="min-height:60px"></div>' +
      '<div class="opts">' + opts + "</div>" + feedback +
    "</div>" +
    '<footer class="footer center">' +
      (S.revealed ? vDash("继续", "bar-teal", "retest-next") : vDash("看答案", "bar-red", "show-answer")) +
    "</footer></div>";
}

function vDone() {
  var goodN = Object.keys(S.ratings).filter(function (k) { return S.ratings[k] === "good"; }).length + S.knownCount;
  var rows = DECK.map(function (w) {
    var r = S.pool.indexOf(w.id) >= 0 ? (S.ratings[w.id] || "hard") : (S.ratings[w.id] || "good");
    var dot = r === "good" ? "bar-teal" : r === "hard" ? "bar-amber" : "bar-red";
    return '<div class="row"><div class="l">' +
      '<span class="dot ' + dot + '"></span>' +
      '<span class="w">' + w.word + "</span>" +
      (S.favs[w.id] ? '<span class="fav-star">' + I.star(true) + "</span>" : "") +
      '</div><span class="m">' + w.senses[0].cn[0] + "</span></div>";
  }).join("");
  return '<div class="done">' +
    '<span class="big-badge">' + I.badge + "</span>" +
    "<h2>本组学习完成</h2>" +
    '<p class="sub">' + DECK.length + " 词 · 认识 " + goodN + " · 出错 " + S.wrongs + "</p>" +
    '<div class="list">' + rows + "</div>" +
    '<div class="restart">' + vDash("再来一轮", "bar-teal", "restart") + "</div>" +
  "</div>";
}

function vNoteOverlay(w) {
  return '<div class="overlay">' +
    '<p class="ov-title">' + w.word + " 的笔记</p>" +
    '<div class="note-card">' +
      '<textarea id="note-ta" maxlength="1000" placeholder="写下你的笔记...">' + S.draft + "</textarea>" +
      '<div class="note-meta">' +
        '<span class="chip">' + w.word + "</span>" +
        '<span class="chip trunc">' + w.senses[0].pos + w.senses[0].cn.join("；") + "</span>" +
        '<span class="sp"></span>' +
        '<span class="note-count" id="note-count">' + S.draft.length + "/1000</span>" +
      "</div></div>" +
    '<div class="note-foot">' +
      '<button class="sq-btn" data-act="note-close">' + I.close + "</button>" +
      '<button class="sq-btn ' + (S.draft.trim() ? "save-on" : "save-off") + '" id="note-save" data-act="note-save">' + I.check + "</button>" +
    "</div></div>";
}

function vSpellOverlay(w) {
  var stateCls = S.spellState === "idle" ? "" : S.spellState;
  var msg = S.spellState === "right" ? "拼写正确"
    : S.spellState === "wrong" ? "再想想，或直接返回" : "";
  return '<div class="overlay">' +
    '<p class="ov-title">拼写测验</p>' +
    '<div class="spell-body">' +
      '<p class="spell-cn"><span class="pos">' + w.senses[0].pos + "</span>" + w.senses[0].cn.join("；") + "</p>" +
      '<input id="spell-in" class="spell-input ' + stateCls + '" type="text" autocomplete="off" ' +
        'autocorrect="off" autocapitalize="off" spellcheck="false" ' +
        'placeholder="拼出对应的英文单词" value="' + S.spellInput.replace(/"/g, "&quot;") + '"' +
        (S.spellState === "right" ? " disabled" : "") + ">" +
      '<p class="spell-msg ' + stateCls + '">' + msg + "</p>" +
    "</div>" +
    '<footer class="footer cols-2">' +
      vDash("返回", "bar-gray", "spell-close", true) +
      (S.spellState === "right"
        ? vDash("完成", "bar-teal", "spell-close")
        : vDash("检查", "bar-teal", "spell-check")) +
    "</footer></div>";
}

/* ================= 主渲染 ================= */
var app = document.getElementById("app");

function render() {
  var html = "";
  var w;
  if (S.phase === "done") {
    html = vDone();
  } else {
    w = S.phase === "choice" ? rCur() : cur();
    if (!w) { S.phase = "done"; html = vDone(); }
    else if (S.phase === "learn" && S.face === "front") html = vLearnFront(w);
    else if (S.phase === "learn") html = vLearnBack(w);
    else html = vChoice(w);
  }
  var aw = activeWord();
  if (S.noteOpen && aw) html += vNoteOverlay(aw);
  if (S.spellOpen && aw) html += vSpellOverlay(aw);
  app.innerHTML = html;
  afterRender();
}

function afterRender() {
  var ta = document.getElementById("note-ta");
  if (ta) {
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
    ta.addEventListener("input", function () {
      S.draft = ta.value;
      var c = document.getElementById("note-count");
      if (c) c.textContent = S.draft.length + "/1000";
      var save = document.getElementById("note-save");
      if (save) save.className = "sq-btn " + (S.draft.trim() ? "save-on" : "save-off");
    });
  }
  var si = document.getElementById("spell-in");
  if (si && S.spellState !== "right") {
    si.focus();
    si.setSelectionRange(si.value.length, si.value.length);
    si.addEventListener("input", function () {
      S.spellInput = si.value;
      if (S.spellState === "wrong") {
        S.spellState = "idle";
        si.className = "spell-input";
        var m = document.querySelector(".spell-msg");
        if (m) { m.className = "spell-msg"; m.textContent = ""; }
      }
    });
    si.addEventListener("keydown", function (e) {
      if (e.key === "Enter") ACTIONS["spell-check"]();
    });
  }
}

/* ================= 动作表 ================= */
function endLearn() {
  if (S.pool.length) {
    S.phase = "choice"; S.rIdx = 0; S.revealed = false; S.picked = null;
  } else {
    S.phase = "done";
  }
}

var ACTIONS = {
  "rate-good": function () { rateWord("good"); },
  "rate-hard": function () { rateWord("hard"); },
  "rate-again": function () { rateWord("again"); },

  "next": function () { advance(false); },
  "mistake": function () { advance(true); },

  "undo": function () {
    if (S.phase === "learn" && S.idx > 0) {
      S.idx--; S.face = "front"; S.tab = "colloc"; render();
    }
  },
  "undo-noop": function () {},

  "fav": function () {
    var w = activeWord();
    if (!w) return;
    if (S.favs[w.id]) delete S.favs[w.id]; else S.favs[w.id] = true;
    render();
  },

  "known": function () {
    if (S.phase !== "learn") return;
    var w = cur();
    if (!w) return;
    S.knownCount++;
    commit(w, "good");
    S.queue = S.queue.filter(function (x) { return x.id !== w.id; });
    S.face = "front"; S.tab = "colloc";
    if (S.idx >= S.queue.length) endLearn();
    render();
  },

  "tab": function (arg) { S.tab = arg; render(); },

  "speak-word": function () { var w = activeWord(); if (w) speak(w.word); },
  "speak-sentence": function () { var w = activeWord(); if (w) speak(w.sentence.en); },

  "pick": function (arg) {
    if (S.revealed) return;
    var i = parseInt(arg, 10);
    S.picked = i; S.revealed = true;
    var w = rCur();
    if (S._options[i].id !== w.id) S.wrongs++;
    speak(w.word);
    render();
  },
  "show-answer": function () {
    S.picked = null; S.revealed = true; S.wrongs++;
    speak(rCur().word);
    render();
  },
  "retest-next": function () {
    S.revealed = false; S.picked = null;
    if (S.rIdx + 1 < retestCards().length) S.rIdx++;
    else S.phase = "done";
    render();
  },

  "restart": function () {
    S.phase = "learn"; S.face = "front"; S.tab = "colloc";
    S.queue = DECK.slice(); S.idx = 0;
    S.pool = []; S.ratings = {}; S.knownCount = 0;
    S.rIdx = 0; S.revealed = false; S.picked = null; S.wrongs = 0;
    render();
  },

  "note-open": function () {
    var w = activeWord();
    if (!w) return;
    S.draft = S.notes[w.id] || "";
    S.noteOpen = true;
    render();
  },
  "note-close": function () { S.noteOpen = false; render(); },
  "note-save": function () {
    var w = activeWord();
    if (!w) return;
    S.notes[w.id] = S.draft.trim();
    S.noteOpen = false;
    if (S.notes[w.id] && S.phase === "learn" && S.face === "back") S.tab = "note";
    render();
  },

  "spell-open": function () {
    S.spellInput = ""; S.spellState = "idle"; S.spellOpen = true;
    render();
  },
  "spell-close": function () { S.spellOpen = false; render(); },
  "spell-check": function () {
    var w = activeWord();
    if (!w || S.spellState === "right") return;
    var ok = S.spellInput.trim().toLowerCase() === w.word;
    S.spellState = ok ? "right" : "wrong";
    if (ok) speak(w.word);
    render();
  }
};

function rateWord(r) {
  var w = cur();
  S.ratings[w.id] = r;
  if (r !== "good" && S.pool.indexOf(w.id) < 0) S.pool.push(w.id);
  S.face = "back"; S.tab = "colloc";
  speak(w.word);
  render();
}

function advance(mistake) {
  var w = cur();
  if (mistake) {
    S.ratings[w.id] = "again";
    if (S.pool.indexOf(w.id) < 0) S.pool.push(w.id);
  }
  commit(w, S.ratings[w.id] || "good");
  S.face = "front"; S.tab = "colloc";
  if (S.idx + 1 < S.queue.length) S.idx++;
  else endLearn();
  render();
}

/* ================= 事件委托 ================= */
app.addEventListener("click", function (e) {
  var el = e.target.closest("[data-act]");
  if (!el) return;
  var act = el.getAttribute("data-act");
  if (ACTIONS[act]) ACTIONS[act](el.getAttribute("data-arg"));
});

/* ================= 启动：从壳拉队列 ================= */
function mapRating(r) {
  return r === "good" ? "good" : r === "hard" ? "hard" : "again";
}
function commit(w, rating) {
  if (!w || !w.id) return;
  fcCall("review.commit", { id: w.id, rating: mapRating(rating) }).catch(function (e) {
    if (FC && FC.log) { try { FC.log("ref", "commit fail: " + e); } catch (_) {} }
  });
}
function fetchCards(ids) {
  return Promise.all(ids.map(function (id) {
    return fcCall("card.get", { id: id }).then(function (x) { return x && x.card; });
  }));
}
function loadQueue() {
  // web_session 模式：壳按【当前这本书】排好了计划（review_screen 里 setPlan）。
  // 从 session.plan 拿本轮该给谁 —— 千万别用 card.new，那是全库新卡，
  // 会跨书抓卡（踩过：打开测试书，蹦出来别本书的 portray）。
  return fcCall("session.plan", {}).then(function (plan) {
    var ids = [];
    ((plan && plan.units) || []).forEach(function (u) {
      (u.cards || []).forEach(function (c) { if (c && c.id) ids.push(c.id); });
    });
    if (ids.length) return fetchCards(ids);
    // 兜底：真没计划（非 web_session 路径）才退回全库新卡
    return fcCall("card.new", { limit: 20 }).then(function (r) {
      return fetchCards((r && r.ids) || []);
    });
  }).then(function (list) {
    DECK = list.filter(Boolean).map(function (c, i) { return normCard(c, "c" + i); });
  }).catch(function (e) {
    if (FC && FC.log) { try { FC.log("ref", "loadQueue fail: " + e); } catch (_) {} }
    DECK = [];
  });
}
loadQueue().then(function () {
  S.phase = "learn";
  S.face = "front";
  S.queue = DECK.slice();
  S.idx = 0;
  render();
});
