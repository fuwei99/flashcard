/* 不背单词 · React 复刻 v1 —— 壳适配 + 状态机 + 渲染 */
(function () {
  "use strict";
  var FC = window.Flashcard;
  if (!FC) {
    FC = window.Flashcard = {
      getCard: function () { return window.__FLASHCARD_CARD__ || {}; },
      call: function () { return Promise.resolve({ ok: true, card: null, ids: [] }); },
      tts: function (t) { try { speechSynthesis.cancel(); var u = new SpeechSynthesisUtterance(String(t || "")); u.lang = "en-US"; u.rate = 0.95; speechSynthesis.speak(u); } catch (e) {} },
      onMount: function () {}, log: function () {}
    };
  }
  var root = document.getElementById("fc-app");
  if (!root) return;

  function esc(s) { return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;"); }
  function arr(v) { return Array.isArray(v) ? v : (v == null ? [] : [v]); }
  function shuffle(a, seed) { var r = a.slice(), s = seed || 1; for (var i = r.length - 1; i > 0; i--) { s = (s * 9301 + 49297) % 233280; var j = Math.floor((s / 233280) * (i + 1)); var t = r[i]; r[i] = r[j]; r[j] = t; } return r; }
  /* TTS 路由：照抄 bubei_dark —— 词和句各走各的插件/音色。
     不传 plugin 时壳会用「当前选中插件」，音色不受控；显式点名更稳。 */
  var TTS_WORD     = { lang: "en-US", plugin: "doubao", voice: "zh_female_wenroutaozi_v2_mars_bigtts", cache: true };
  var TTS_SENTENCE = { lang: "en-US", plugin: "doubao", voice: "zh_male_cixingjunyu_uranus_bigtts", cache: false };
  var TTS_PASSAGE  = { lang: "en-US", plugin: "doubao", voice: "zh_male_cixingjunyu_uranus_bigtts", rate: 1.2, pitch: 0.9, cache: false };
  function speak(text, opts) { var say = String(text || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim(); if (!say) return; try { FC.tts(say, opts || TTS_WORD); } catch (e) {} }
  /* 读完单词自动接例句：走壳的 ttsSeq 顺序播 —— 单词一开口就去合成例句，几乎无缝。
     壳没给 ttsSeq 就退回只读单词。 */
  function speakWordThenSentence(card) {
    var f = (card && card.fields) || {};
    var w = String(f.word || "").trim();
    var s = String((f.sentence || {}).en || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
    var seq = [];
    if (w) seq.push(Object.assign({ text: w, lang: "en-US" }, TTS_WORD));
    if (s) seq.push(Object.assign({ text: s, lang: "en-US" }, TTS_SENTENCE));
    if (seq.length && FC.ttsSeq) { try { FC.ttsSeq(seq); return; } catch (e) {} }
    if (w) speak(w, TTS_WORD);
  }
  /* 只读句子 —— 点「提示」时用，不再重复读单词 */
  function speakSentence(card) {
    var f = (card && card.fields) || {};
    var s = String((f.sentence || {}).en || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
    if (s) speak(s, TTS_SENTENCE);
  }
  /* 进入卡片正面（认识 / 不认识）自动读单词。
     paint() 会被反复调用，用 _spokenId 防同一张卡重复开口。 */
  function maybeSpeakFront() {
    if (S.phase !== "cards" || S.face !== "front" || !S.card) return;
    var id = S.card.id;
    if (!id || S._spokenId === id) return;
    S._spokenId = id;
    var w = String((S.card.fields || {}).word || "").trim();
    if (w) speak(w, TTS_WORD);
  }
  /* 进入语篇通读自动朗读整段。同 maybeSpeakFront，用守卫防 paint() 反复触发。 */
  function maybeSpeakPassage() {
    if (S.phase !== "passage" || !S.passage) return;
    if (S._passageSpoken) return;
    S._passageSpoken = true;
    var segs = arr(S.passage.segments);
    var txt = segs.map(function (x) { return x.w || x.t || ""; }).join("");
    if (txt) speak(txt, TTS_PASSAGE);
  }
  function call(m, p) { try { return FC.call ? FC.call(m, p) : Promise.resolve({}); } catch (e) { return Promise.resolve({}); } }
  /* 插件统一入口：壳只认 plugin.call，具体插件在 Flashcard/plugins/*.js */
  function pluginCall(id, method, args) {
    return call("plugin.call", { id: id, method: method, args: args || {} });
  }
  /* 有道插件的配置状态（设置页显示用） */
  function loadDictCfg() {
    return pluginCall("youdao", "getConfig", {}).then(function (r) {
      var d = (r && r.ok && r.data) ? r.data : null;
      S.dictCfg = d ? { appKey: d.appKey || "", configured: !!(d.appKey && d.hasSecret) } : null;
      if (d && d.appKey) S.dictKey = d.appKey;
    }).catch(function () {});
  }
  function log(m) { try { if (FC.log) FC.log("[v1]", m); } catch (e) {} }
  /* ===================== 会话断点续传 =====================
     与 bubei_dark/workflow.js 同源：每一步 session.save 落盘到
     /mnt/Flashcard/session.json，重进时 session.load 原地续上。
     不存整张卡（几百 KB 会炸），只存 card id + 进度，恢复时 card.get 重拉。 */
  var WF_NAME = "bubei_react_v1";
  var _saveTimer = null;
  /* 计划指纹：只有「同一章、同一批卡」才算同一次会话。
     光存队列不存「这是哪章」，换章节就会把上一章的断点续上 —— 病根就在这。 */
  function planKey(plan) {
    var units = arr(plan && plan.units);
    if (!units.length) return "";
    var parts = units.map(function (u) {
      return String(u.title || "") + ":" + arr(u.cards).map(function (c) { return c.id; }).join(",");
    });
    return String((plan && plan.mode) || "") + "|" + parts.join("|");
  }
  function snapshot() {
    return {
      screen: S.screen, phase: S.phase, idx: S.idx, face: S.face, tab: S.tab,
      hinted: S.hinted, wrongs: S.wrongs, missed: S.missed.slice(),
      history: S.history.slice(), learned: S.learned, ratings: S.ratings,
      queueIds: S.queue.map(function (c) { return c.id; }),
      planKey: planKey(S.plan)
    };
  }
  function saveSession() {
    if (!S.queue || !S.queue.length || S.phase === "done") return;
    try { call("session.save", { workflow: WF_NAME, cursor: S.screen, session: snapshot() }); } catch (e) {}
  }
  function saveSoon() {
    if (_saveTimer) clearTimeout(_saveTimer);
    _saveTimer = setTimeout(function () { _saveTimer = null; saveSession(); }, 200);
  }
  function clearSession() { try { call("session.clear", {}); } catch (e) {} }
  function restoreSession(snap, plan) {
    if (!snap || !snap.queueIds || !snap.queueIds.length || snap.phase !== "cards") return false;
    if (plan) S.plan = plan;
    S.screen = snap.screen === "review" ? "review" : "learn";
    S.phase = "cards"; S.idx = snap.idx || 0; S.face = snap.face === "back" ? "back" : "front";
    S.tab = snap.tab || "colloc"; S.hinted = !!snap.hinted; S.wrongs = snap.wrongs || 0;
    S.missed = arr(snap.missed); S.history = arr(snap.history); S.learned = snap.learned || {}; S.ratings = snap.ratings || {};
    S.queue = []; S.card = null;
    fetchCards(snap.queueIds).then(function (cards) {
      if (!cards.length) { log("restore -> 0 cards, 重开"); S.queue = []; startSession(S.screen); return; }
      S.queue = cards; S.idx = Math.min(S.idx, cards.length - 1);
      S.card = cards[S.idx] || null;
      return hydrateKv(cards).then(function () {
        log("restore ok idx=" + S.idx + "/" + cards.length + " face=" + S.face + " screen=" + S.screen);
        reportProgress(); paint();
      });
    });
    return true;
  }
  function orangeWord(text, word) { if (!word) return esc(text); var re = new RegExp("(" + word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\w*)", "ig"); return String(text || "").split(re).map(function (seg) { if (!seg) return ""; return seg.toLowerCase().indexOf(word.toLowerCase()) === 0 ? '<b class="font-bold text-[#f0a824]">' + esc(seg) + "</b>" : esc(seg); }).join(""); }
  function clickable(text, boldWord, selected, cls) { var toks = String(text || "").split(/([A-Za-z][A-Za-z'-]*)/g); return '<p class="' + (cls || "") + '">' + toks.map(function (tk) { if (!/^[A-Za-z]/.test(tk)) return esc(tk); var isBold = boldWord && tk.toLowerCase().indexOf(boldWord.toLowerCase()) === 0; var isSel = selected && tk.toLowerCase() === selected.toLowerCase(); return '<span data-word="' + esc(tk) + '" class="cursor-pointer rounded-[4px] transition-colors ' + (isSel ? "bg-[#4a5578]/80 px-[2px] -mx-[2px] " : "active:bg-white/15 ") + (isBold ? "font-bold text-white" : "") + '">' + esc(tk) + "</span>"; }).join("") + "</p>"; }

  var S = {
    screen: "learn", phase: "cards", face: "front", tab: "colloc",
    tabOrder: ["colloc", "deriv", "syn", "root", "mnem"],
    card: null, queue: [], idx: 0, hinted: false,
    prefs: { passage: true, cloze: true, confusion: true, syllable: true, clozeEx: false, topbar: true },
    favs: {}, notes: {}, learned: {}, due: [], ratings: {},
    missed: [], history: [],
    dictWord: null, dictAnchor: null, dictExpanded: false, dictFavs: {}, dictKey: "", dictSecret: "", dictCfg: null, _spokenId: null, _passageSpoken: false,
    examOpen: false, noteOpen: false, noteDraft: "", spellOpen: false,
    spellInput: "", spellState: "idle",
    srAsk: 0, srItems: [], sr: null,
    menuOpen: false, settingsOpen: false, orderOpen: false,
    sentView: null, rIdx: 0, revealed: false, picked: null, wrongs: 0,
    passageStep: "read", clozeFilled: [], clozeErr: null,
    /* —— 纯渲染层驱动字段（workflow.js 通过 web.mount 灌入）—— */
    mode: "read", pendingRating: "good", retestTotal: 0,
    /* 统一场景（壳通过 session.scene 下发）：learn / review / retest / preview */
    scene: "", browse: false,
    choicePool: [], sentCloze: null
  };
  var TABS = { colloc: "词组", deriv: "派生", syn: "串记", root: "词根", mnem: "助记", note: "笔记" };
  var BG = "linear-gradient(168deg, #121214 0%, #131216 55%, #1a1522 100%)";
  var LEARN_BG = "linear-gradient(172deg, #131417 0%, #16151b 45%, #2a211d 100%)";
  function F() { return (S.card && S.card.fields) || {}; }

  var I = {
    speaker: '<svg viewBox="0 0 24 24" class="__C__" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>',
    chevron: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
    undo: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/></svg>',
    star: function (f) { return '<svg viewBox="0 0 24 24" class="__C__" fill="' + (f ? "currentColor" : "none") + '" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6L12 16.7 6.6 19.6l1.1-6L3.2 9.4l6.1-.8L12 3z"/></svg>'; },
    dots: '<svg viewBox="0 0 24 24" class="__C__" fill="currentColor"><circle cx="5" cy="12" r="1.9"/><circle cx="12" cy="12" r="1.9"/><circle cx="19" cy="12" r="1.9"/></svg>',
    noteadd: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M4 20h7"/><path d="M14.5 4.5l3 3L8 17l-4 1 1-4 9.5-9.5z" stroke-linejoin="round"/><path d="M18 15v5M15.5 17.5h5" stroke-width="1.7"/></svg>',
    sentswitch: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="14" rx="3.5"/><path d="M7.5 10h6M7.5 14h9"/></svg>',
    textsearch: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M4 6h13M4 11h7M4 16h5"/><circle cx="16.5" cy="15.5" r="3.4"/><path d="M19 18l2.4 2.4"/></svg>',
    bulb: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 1 3.5 10.9c-.8.6-1.5 1.3-1.5 2.1h-4c0-.8-.7-1.5-1.5-2.1A6 6 0 0 1 12 3z"/></svg>',
    close: '<svg viewBox="0 0 24 24" class="__C__" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>'
  };
  function ico(t, cls) { return t.replace(/__C__/g, cls || "h-[20px] w-[20px]"); }

  function topBar(counter, opts) {
    opts = opts || {};
    return '<header class="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2">' +
      '<button data-act="home" class="flex items-center gap-2 text-[#c9c9ce] active:opacity-60">' + ico(I.chevron, "h-[22px] w-[22px]") + '<span class="text-[15px] font-medium tabular-nums text-[#b9b9bf]">' + esc(counter) + "</span></button>" +
      '<div class="flex items-center gap-[26px]">' +
        '<button data-act="undo" class="' + (opts.canUndo ? "text-[#a8a8ae]" : "text-[#4a4a4f]") + '">' + ico(I.undo, "h-[20px] w-[20px]") + "</button>" +
        '<button data-act="fav" class="' + (opts.fav ? "text-[#f0f0f2]" : "text-[#a8a8ae]") + ' active:scale-90">' + ico(I.star(opts.fav), "h-[21px] w-[21px]") + "</button>" +
        (opts.showKnown ? '<button data-act="known" class="pb-[2px] text-[16px] font-semibold leading-none text-[#c9c9ce] underline decoration-[#8a8a90] decoration-[1.5px] underline-offset-[5px]">熟</button>' : "") +
        '<button data-act="spell" class="pb-[2px] text-[15px] font-bold leading-none text-[#c9c9ce] underline decoration-[#8a8a90] decoration-[1.5px] underline-offset-[5px]">abc</button>' +
        '<button data-act="menu" class="text-[#a8a8ae]">' + ico(I.dots, "h-[20px] w-[20px]") + "</button>" +
      "</div></header>";
  }
  function hero(card, opts) {
    opts = opts || {}; var f = card.fields || {}; var dots = opts.dots == null ? 1 : opts.dots;
    var word = opts.syllable ? (f.syllable || f.word) : f.word; var dh = "";
    for (var i = 0; i < 3; i++) dh += '<span class="h-[4px] w-[4px] rounded-full ' + (i >= 3 - dots ? "bg-[#2ec4a5]" : "bg-[#4a4a4f]") + '"></span>';
    return '<div class="px-[34px]"><div class="flex items-start gap-[14px]"><h1 class="text-[34px] font-extrabold leading-[1.15] tracking-[-0.01em] text-[#f5f5f7]">' + esc(word) + '</h1><span class="mt-[14px] flex flex-col gap-[3px]">' + dh + "</span></div>" +
      '<div class="mt-[14px] flex items-center gap-3"><button data-act="tts-word" class="flex items-center gap-[6px] rounded-full bg-[#29292e] px-[13px] py-[6px] active:scale-95"><span class="text-[11px] font-medium text-[#b9b9bf]">美</span>' + ico(I.speaker, "h-[12px] w-[12px] text-[#b9b9bf]") + '</button><span class="text-[15px] tracking-wide text-[#b9b9bf]">' + esc(f.phonetic || "") + "</span></div></div>";
  }
  function senseLine(card) {
    var f = card.fields || {}; var details = arr(f.meaningDetails); var senses = arr(f.senses);
    var html = '<div class="mt-[22px] space-y-[10px] px-[34px]">';
    senses.forEach(function (s, si) {
      html += '<p class="flex flex-wrap items-baseline gap-x-[18px] gap-y-2"><span class="text-[16px] text-[#a8a8ae]">' + esc(s.pos || "") + "</span>";
      arr(s.cn).forEach(function (m, mi) {
        var dIdx = -1; for (var k = 0; k < details.length; k++) { if (details[k].meaning === m) { dIdx = k; break; } }
        var bound = dIdx >= 0; var primary = si === 0 && mi === 0;
        html += "<span " + (bound ? 'data-act="meaning" data-m="' + dIdx + '"' : "") + ' class="pb-[5px] text-[17px] leading-snug ' + (bound ? "cursor-pointer underline decoration-dashed decoration-[#5a5a60] decoration-[1.5px] underline-offset-[7px] active:decoration-[#e3a83c] active:text-[#e3a83c] " : "") + (primary ? "font-bold text-[#f0f0f2]" : "font-normal text-[#d5d5da]") + '">' + esc(m) + "</span>";
      });
      html += "</p>";
    });
    return html + "</div>";
  }
  function dashBtn(label, color, act, dim) {
    return "<button " + (act ? 'data-act="' + act + '"' : "") + ' class="flex flex-col items-center gap-[9px] active:opacity-60"><span class="text-[18px] font-semibold ' + (dim ? "text-[#7c7c82]" : "text-[#ececef]") + '">' + esc(label) + '</span><span class="h-[4px] w-[22px] rounded-full ' + color + '"></span></button>';
  }
  function detailBody(card, tab) {
    var f = card.fields || {}; var details = arr(f.meaningDetails);
    var tabs = S.tabOrder.slice(); if (S.notes[card.id]) tabs.push("note");
    var tabHtml = tabs.map(function (t) { return '<button data-act="tab" data-t="' + t + '" class="rounded-[9px] px-[11px] py-[7px] text-[13.5px] transition-colors ' + (tab === t ? "bg-[#38383e] font-semibold text-[#f0f0f2]" : "text-[#8c8c92]") + '">' + esc(TABS[t]) + "</button>"; }).join("");
    var body = "";
    if (tab === "colloc") {
      body = arr(f.collocations).map(function (c, ci) {
        var mIdx = c.m == null ? 0 : c.m; var bound = c.m !== -1 && details.length > mIdx && mIdx >= 0;
        return '<p class="mb-[15px] flex items-baseline text-[16px] leading-snug"><span ' + (bound ? 'data-act="meaning" data-m="' + mIdx + '"' : "") + ' class="' + (bound ? "cursor-pointer pb-[4px] text-[#ececef] underline decoration-dashed decoration-[#5a5a60] decoration-[1.5px] underline-offset-[6px] " : "text-[#ececef]") + '">' + esc(c.en) + '</span><span class="ml-[13px] text-[#d5d5da]">' + esc(c.cn) + '</span>' + (c.tag ? '<span class="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">' + esc(c.tag) + "</span>" : "") + '</p>';
      }).join("");
    } else if (tab === "deriv") {
      var derivs = arr(f.derivatives);
      var infl = arr(f.inflections);
      var secTitle = function (t) {
        return '<div style="margin-bottom:6px"><span style="border:1px solid #4a4a4f;border-radius:5px;padding:2px 7px;font-size:12px;color:#a8a8ae">' + t + '</span></div>';
      };
      var derivHtml = derivs.length ? derivs.map(function (d) {
        return '<div style="display:flex;align-items:baseline;padding:8px 0;border-bottom:1px solid rgba(255,255,255,.06)">' +
            (d.word === f.word ? '<span style="margin-right:8px;font-size:10px;color:#e3a83c">\u25b6</span>' : '') +
            '<span data-act="word" data-w="' + esc(d.word) + '" style="cursor:pointer;font-size:16px;color:#ececef;border-bottom:1px dotted rgba(255,255,255,.25)">' + esc(d.word) + '</span>' +
            '<span style="margin-left:11px;font-size:13.5px;color:#a8a8ae">' + esc(d.pos || "") + '</span>' +
            '<span style="flex:1"></span>' +
            (d.tag ? '<span style="margin-right:9px;border-radius:4px;background:#2e2e33;padding:2px 7px;font-size:11px;color:#8c8c92">' + esc(d.tag) + '</span>' : '') +
            '<span style="font-size:14px;color:#d5d5da;text-align:right">' + esc(d.cn || "") + '</span>' +
          '</div>';
      }).join("") : '<p style="font-size:15px;color:#8c8c92">暂无派生词</p>';

      body = '<div style="margin-bottom:20px">' + secTitle("\u6d3e\u751f") + derivHtml + '</div>';

      if (infl.length) {
        body += '<div>' + secTitle("\u53d8\u5f62") + infl.map(function (x) {
          var isObj = x && typeof x === "object";
          var pos = isObj ? String(x.pos || "") : "";
          var label = isObj ? String(x.label || x.form || "") : "";
          var text = isObj ? String(x.text || x.value || "") : String(x == null ? "" : x);
          return '<div style="margin-bottom:10px;border-radius:11px;background:#28282c;padding:10px 13px">' +
              ((pos || label) ? '<div style="display:flex;align-items:center;gap:8px;margin-bottom:5px">' +
                (pos ? '<span style="font-size:13px;color:#a8a8ae">' + esc(pos) + '</span>' : '') +
                (label ? '<span style="border-radius:4px;background:#3a3a40;padding:2px 7px;font-size:11px;color:#c5c5ca">' + esc(label) + '</span>' : '') +
              '</div>' : '') +
              '<p style="font-size:15px;line-height:1.65;color:#ececef">' + esc(text) + '</p>' +
            '</div>';
        }).join("") + '</div>';
      }
    } else if (tab === "syn") {
      var cnOf = function (v) { return Array.isArray(v) ? v.join("；") : String(v == null ? "" : v); };
      var normOne = function (x, defG) {
        if (x && typeof x === "object") {
          var s0 = arr(x.senses)[0] || {};
          return { g: String(x.group || defG), w: String(x.word || ""), pos: String(s0.pos || ""), cn: cnOf(s0.cn), tag: String(x.tag || "") };
        }
        return { g: defG, w: String(x == null ? "" : x), pos: "", cn: "", tag: "" };
      };
      var items = [];
      if (arr(f.related).length) {
        arr(f.related).forEach(function (x) { items.push(normOne(x, "串记")); });
      } else {
        arr(f.synonyms).forEach(function (x) { items.push(normOne(x, "近义")); });
        arr(f.antonyms).forEach(function (x) { items.push(normOne(x, "反义")); });
      }
      items = items.filter(function (x) { return x.w; });

      var groups = [], gmap = {};
      items.forEach(function (x) {
        if (!gmap[x.g]) { gmap[x.g] = []; groups.push(x.g); }
        gmap[x.g].push(x);
      });

      body = groups.length ? groups.map(function (g) {
        var list = gmap[g], tag = "";
        for (var i = 0; i < list.length; i++) { if (list[i].tag) { tag = list[i].tag; break; } }
        return '<div style="margin-bottom:18px">' +
            '<div style="display:flex;align-items:center;margin-bottom:4px">' +
              '<span style="border:1px solid #4a4a4f;border-radius:5px;padding:2px 7px;font-size:12px;color:#a8a8ae">' + esc(g) + '</span>' +
              (tag ? '<span style="margin-left:auto;background:#2e2e33;border-radius:4px;padding:2px 7px;font-size:11px;color:#8c8c92">' + esc(tag) + '</span>' : '') +
            '</div>' +
            list.map(function (x) {
              return '<div style="display:flex;align-items:baseline;padding:9px 0;border-bottom:1px solid rgba(255,255,255,.06)">' +
                  '<span data-act="word" data-w="' + esc(x.w) + '" style="cursor:pointer;font-size:16px;color:#d5d5da;border-bottom:1px dotted rgba(255,255,255,.25)">' + esc(x.w) + '</span>' +
                  '<span style="flex:1"></span>' +
                  '<span style="font-size:14px;color:#c5c5ca;text-align:right;white-space:nowrap">' +
                    (x.pos ? '<span style="color:#a8a8ae;margin-right:7px">' + esc(x.pos) + '</span>' : '') +
                    esc(x.cn) +
                  '</span>' +
                '</div>';
            }).join("") +
          '</div>';
      }).join("") : '<p style="font-size:15px;color:#8c8c92">暂无串记</p>';
    } else if (tab === "root") {
      body = arr(f.root).map(function (r) { return '<p class="mb-[14px] text-[16px]"><span class="mr-[12px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">' + esc(r.tag || "") + '</span><span class="text-[#ececef]">' + esc(r.text || "") + "</span></p>"; }).join("") + (f.rootSummary ? '<p class="mt-[4px] text-[16px] leading-[1.7] text-[#ececef]">' + esc(f.rootSummary) + "</p>" : "");
    } else if (tab === "mnem") {
      var rawM = f.mnemonics != null ? f.mnemonics : (f.mnemonic != null ? [f.mnemonic] : []);
      var mns = arr(rawM);
      if (!mns.length) {
        body = '<p style="font-size:15px;color:#8c8c92">暂无助记</p>';
      } else {
        body = mns.map(function (m) {
          var isObj = m && typeof m === "object";
          var txt = isObj ? String(m.text || "") : String(m == null ? "" : m);
          var tag = isObj ? String(m.tag || "") : "";
          return '<div style="margin-bottom:12px;border-radius:12px;background:#28282c;padding:12px 14px;border-left:3px solid #e3a83c">' +
              (tag ? '<span style="display:inline-block;margin-bottom:7px;border-radius:4px;background:#3a3a40;padding:2px 7px;font-size:11px;color:#c5c5ca">' + esc(tag) + '</span>' : '') +
              '<p style="font-size:15.5px;line-height:1.7;color:#ececef">' + esc(txt) + '</p>' +
            '</div>';
        }).join("");
      }
    } else if (tab === "note") {
      body = '<p class="text-[16px] leading-relaxed text-[#ececef]">' + esc(S.notes[card.id] || "暂无笔记") + '</p><button data-act="note" class="mt-[16px] flex items-center gap-[6px] text-[14px] text-[#a8a8ae]">编辑笔记' + ico(I.noteadd, "h-[13px] w-[13px]") + "</button>";
    }
    return '<div class="relative mx-4 mt-[22px] rounded-[16px] bg-[#222226]/90 px-[18px] pb-[46px] pt-[17px]">' + clickable((f.sentence || {}).en, f.word, S.dictWord, "text-[17px] leading-[1.55] text-[#ececef]") + '<p class="mt-[6px] text-[15px] leading-relaxed text-[#c5c5ca]">' + esc((f.sentence || {}).cn) + '</p><button data-act="sentence-view" class="absolute bottom-[13px] right-[13px] flex h-[34px] w-[34px] items-center justify-center rounded-full bg-[#2e2e33] text-[#b9b9bf]">' + ico(I.sentswitch, "h-[17px] w-[17px]") + "</button></div>" +
      '<div class="mx-4 mb-4 mt-[13px] flex min-h-[280px] flex-1 flex-col rounded-[16px] bg-[#222226]/90 px-[18px] pt-[19px]"><div style="flex:1;min-height:0;overflow-y:auto;overscroll-behavior:contain">' + body + '</div><div class="flex flex-none items-center gap-[6px] pb-[15px] pt-3">' + tabHtml + '<span class="flex-1"></span>' + (!S.notes[card.id] ? '<button data-act="note" class="mr-[4px] text-[#a8a8ae]">' + ico(I.noteadd, "h-[18px] w-[18px]") + "</button>" : "") + '<button data-act="exam" class="flex h-[32px] w-[32px] items-center justify-center rounded-full bg-[#2e2e33] text-[#b9b9bf]">' + ico(I.textsearch, "h-[16px] w-[16px]") + "</button></div></div>";
  }
  /* 主页已删除 —— 模板只保留「学习 / 复习」两条线，进来直接开背。 */
  function sentenceText(card) { var en = String((card.fields.sentence || {}).en || ""); if (S.prefs.clozeEx) { var w = String(card.fields.word || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); en = en.replace(new RegExp(w + "\\w*", "i"), "______"); } return en; }
  function doneView() {
    var q = S.queue, missed = S.missed;
    return '<div class="flex flex-1 flex-col items-center justify-center px-9 pb-12"><svg viewBox="0 0 24 24" class="h-[52px] w-[52px]"><path fill="#1db373" d="M12 1.6l2.1 1.8 2.7-.5 1 2.6 2.6 1-.5 2.7 1.8 2.1-1.8 2.1.5 2.7-2.6 1-1 2.6-2.7-.5-2.1 1.8-2.1-1.8-2.7.5-1-2.6-2.6-1 .5-2.7L1.6 12l1.8-2.1-.5-2.7 2.6-1 1-2.6 2.7.5L12 1.6z"/><path d="M8.4 12.2l2.3 2.3 4.6-4.7" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
      '<h2 class="mt-5 text-[22px] font-bold text-[#f5f5f7]">' + (S.screen === "learn" ? "本组学习完成" : "本轮复习完成") + '</h2><p class="mt-2 text-[13.5px] text-[#7c7c82]">' + q.length + " 词 · 需复习 " + missed.length + " · 出错 " + S.wrongs + "</p>" +
      '<div class="mt-9 w-full space-y-[13px]">' + q.map(function (c) { var bad = missed.indexOf(c.id) >= 0; return '<div class="flex items-center justify-between rounded-[14px] bg-[#222226]/90 px-[18px] py-[13px]"><div class="flex items-center gap-3"><span class="h-[7px] w-[7px] rounded-full ' + (bad ? "bg-[#e34d64]" : "bg-[#2ec4a5]") + '"></span><span class="text-[16px] font-semibold text-[#ececef]">' + esc(c.fields.word) + '</span></div><span class="max-w-[45%] truncate text-[13px] text-[#8c8c92]">' + esc(arr((c.fields.senses || [])[0] && c.fields.senses[0].cn)[0] || "") + "</span></div>"; }).join("") + "</div>" +
      '<button data-act="home" class="mt-10 flex flex-col items-center gap-[9px]"><span class="text-[18px] font-semibold text-[#ececef]">完成</span><span class="h-[4px] w-[22px] rounded-full bg-[#2ec4a5]"></span></button></div>';
  }
  function overlays() { return ""; }

  /* 全量重绘会把滚动位置和输入焦点冲掉 —— 重绘前抓、重绘后还原。
     滚动容器统一打 data-scroll="key" 标记。 */
  function captureScroll() {
    var m = {}, els = root.querySelectorAll("[data-scroll]");
    for (var i = 0; i < els.length; i++) { var k = els[i].getAttribute("data-scroll"); if (k) m[k] = els[i].scrollTop; }
    return m;
  }
  function restoreScroll(m) {
    if (!m) return;
    var els = root.querySelectorAll("[data-scroll]");
    for (var i = 0; i < els.length; i++) { var k = els[i].getAttribute("data-scroll"); if (k && m[k] != null) els[i].scrollTop = m[k]; }
  }
  function captureFocus() {
    var a = document.activeElement;
    if (!a || !a.getAttribute) return null;
    var role = a.getAttribute("data-role");
    if (!role) return null;
    var f = { role: role };
    try { f.start = a.selectionStart; f.end = a.selectionEnd; } catch (e) {}
    return f;
  }
  function restoreFocus(f) {
    if (!f) return;
    var el = root.querySelector('[data-role="' + f.role + '"]');
    if (el && el.focus) { try { el.focus(); if (f.start != null && el.setSelectionRange) el.setSelectionRange(f.start, f.end); } catch (e) {} }
  }

  function paint() {
    var card = S.card;
    if (!card) { root.innerHTML = '<div class="flex h-full items-center justify-center p-8 text-center text-[15px] text-[#8a8a90]">' + (S.phase === "done" ? "没有可学的卡（已学完 / 已标熟）" : "加载中…") + "</div>"; return; }
    var _sc = captureScroll(); var _fc = captureFocus();
    var bg = S.screen === "learn" ? LEARN_BG : BG;
    var counter = ((S.idx || 0) + 1) + "/" + (S.retestTotal || 1);
    var h = '<div class="relative flex h-full flex-col overflow-hidden text-[#f0f0f2]" style="background:' + bg + '">';
    if (S.phase === "cards" && !S.browse) h += topBar(counter, { canUndo: S.face === "back" && S.history.length > 0, fav: !!S.favs[card.id], showKnown: S.face === "front" });
    if (S.phase === "cards" && S.face === "front") {
      if (S.screen === "learn") {
        h += '<div data-scroll="learn-front" class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px]">' + hero(card) + '<div class="mt-[26px] space-y-[13px] px-[34px]"><div class="h-[26px] w-[168px] rounded-full bg-[#222226]"></div><div class="h-[26px] w-[100px] rounded-full bg-[#222226]"></div></div><div class="mx-4 mt-[56px] rounded-[16px] bg-[#28282c]/80 px-[18px] py-[19px]">' + clickable(sentenceText(card), card.fields.word, S.dictWord, "text-[17px] leading-[1.6] text-[#ececef]") + (S.hinted ? '<p class="mt-[8px] text-[15px] leading-relaxed text-[#c5c5ca]">' + esc((card.fields.sentence || {}).cn) + "</p>" : "") + "</div></div>";
        if (!S.hinted) h += '<div class="mb-[26px] flex flex-none flex-col items-center gap-[10px]"><button data-act="hint" class="flex h-[52px] w-[52px] items-center justify-center rounded-full bg-[#2e2e33]/90 text-[#c9c9ce]">' + ico(I.bulb, "h-[22px] w-[22px]") + '</button><span class="text-[14px] text-[#7c7c82]">提示一下</span></div>';
        h += '<footer class="grid flex-none grid-cols-2 pb-[34px]">' + dashBtn("不认识", "bg-[#e34d64]", "rate-again") + dashBtn("认识", "bg-[#2ec4a5]", "rate-good") + "</footer>";
      } else {
        h += '<div class="mt-[52px] flex-1">' + hero(card) + '<div class="mt-[26px] space-y-[13px] px-[34px]"><div class="h-[26px] w-[168px] rounded-full bg-[#222226]"></div><div class="h-[26px] w-[100px] rounded-full bg-[#222226]"></div></div></div><p class="mb-[30px] text-center text-[14px] leading-[1.9] text-[#7c7c82]">瞬间想起词义，选「记得」<br>思考后想起词义，选「模糊」</p><footer class="grid flex-none grid-cols-3 pb-[34px]">' + dashBtn("忘记了", "bg-[#e34d64]", "rate-again") + dashBtn("模糊", "bg-[#e3a83c]", "rate-hard") + dashBtn("记得", "bg-[#2ec4a5]", "rate-good") + "</footer>";
      }
    } else if (S.phase === "cards" && S.face === "back") {
      /* preview（查词）只读：不渲染任何底部动作条 */
      var backFoot = S.browse ? "" : (((S.pendingRating === "again") || S.postChoice)
        ? '<footer class="flex flex-none justify-center pb-[34px] pt-[6px]">' + dashBtn("下一词", "bg-[#2ec4a5]", "next") + "</footer>"
        : '<footer class="grid flex-none grid-cols-2 pb-[34px] pt-[6px]">' + dashBtn("记错了", "bg-[#e34d64]", "next-miss") + dashBtn("下一词", "bg-[#2ec4a5]", "next") + "</footer>");
      h += '<div data-scroll="back" class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[46px]" style="overscroll-behavior:contain">' + hero(card, { syllable: S.prefs.syllable }) + senseLine(card) + detailBody(card, S.tab) + '</div>' + backFoot;
    } else if (S.phase === "done") { h += doneView(); }
    h += overlays() + "</div>";
    root.innerHTML = h;
    restoreScroll(_sc); restoreFocus(_fc);
    maybeSpeakFront();
    maybeSpeakPassage();
  }

  window.__FCV1 = { S: S, paint: paint, esc: esc, arr: arr, speak: speak, call: call, ico: ico, I: I, orangeWord: orangeWord, clickable: clickable, topBar: topBar, hero: hero, dashBtn: dashBtn, BG: BG, LEARN_BG: LEARN_BG, shuffle: shuffle };
  /* ===================== PART2-A：浮层渲染 ===================== */
  /* 中文译文目标词：数据格式 [中文](english) -> 中文划线高亮、点按查词 */
  function cnHtml(cn) {
    var s = String(cn || ""); var re = /\[([^\[\]]+)\]\(([^()]+)\)/g;
    var out = "", last = 0, m;
    while ((m = re.exec(s)) !== null) {
      if (m.index > last) out += esc(s.slice(last, m.index));
      var en = String(m[2]).split("|")[0];
      out += '<span data-act="word" data-w="' + esc(en) + '" class="cursor-pointer font-semibold text-[#f0a824] underline decoration-dashed decoration-[#f0a824]/50 decoration-[1.5px] underline-offset-[5px]">' + esc(m[1]) + "</span>";
      last = m.index + m[0].length;
    }
    if (last < s.length) out += esc(s.slice(last));
    return out;
  }

  function ovPassage() {
    var p = S.passage || {}; var segs = arr(p.segments);
    var body = segs.map(function (x) {
      if (x.w) return '<span data-act="word" data-w="' + esc(x.w) + '" class="mx-[2px] cursor-pointer pb-[3px] font-bold text-[#f0a824] underline decoration-dashed decoration-[#f0a824]/50 decoration-[1.5px] underline-offset-[6px]">' + esc(x.w) + "</span>";
      return esc(x.t || "");
    }).join("");
    return '<header class="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2"><button data-act="home" class="flex items-center gap-2 text-[#c9c9ce]">' + ico(I.chevron, "h-[22px] w-[22px]") + '<span class="text-[15px] font-medium text-[#b9b9bf]">语篇通读</span></button>' +
      '<button data-act="passage-speak" class="flex h-[34px] w-[34px] items-center justify-center rounded-full bg-[#29292e] text-[#b9b9bf]">' + ico(I.speaker, "h-[16px] w-[16px]") + "</button></header>" +
      '<div data-scroll="passage" class="min-h-0 flex-1 overflow-y-auto px-[26px] pb-4"><div class="mt-[10px] flex items-baseline gap-3"><h1 class="text-[26px] font-extrabold text-[#f5f5f7]">' + esc(p.title || "") + '</h1><span class="rounded-[5px] bg-[#29292e] px-[8px] py-[3px] text-[12px] text-[#a8a8ae]">' + esc(p.tag || "") + '</span></div>' +
      '<p class="mt-[20px] text-[18px] leading-[1.85] text-[#d5d5da]">' + body + "</p>" +
      '<p class="mt-[22px] border-t border-white/[0.07] pt-[18px] text-[15px] leading-[1.9] text-[#8c8c92]">' + cnHtml(p.cn) + "</p></div>" +
      '<footer class="grid flex-none ' + (S.prefs.cloze ? "grid-cols-2" : "grid-cols-1") + ' pb-[30px] pt-[10px]">' +
      (S.prefs.cloze ? dashBtn("语篇填空", "bg-[#e3a83c]", "cloze-start") : "") + dashBtn("进入单词背诵", "bg-[#2ec4a5]", "cards-start") + "</footer>";
  }

  function ovCloze() {
    var p = S.passage || {}; var segs = arr(p.segments); var bank = S.clozeBank || []; var filled = S.clozeFilled || [];
    var blanks = arr(S.clozeBlanks);
    var bi = -1; var nextBlank = filled.indexOf(null);
    var body = segs.map(function (x) {
      if (!x.w) return esc(x.t || "");
      if (x.blank === false) return '<span data-act="word" data-w="' + esc(x.lemma || x.w) + '" class="mx-[2px] cursor-pointer font-semibold text-[#d5d5da] underline decoration-dotted decoration-white/25 decoration-[1.5px] underline-offset-4">' + esc(x.w) + "</span>";
      bi += 1; var idx = bi; var val = filled[idx];
      var isActive = idx === S.clozeActive;
      return '<span data-act="cloze-blank" data-i="' + idx + '" class="mx-[3px] inline-block min-w-[92px] cursor-pointer border-b-2 pb-[1px] text-center font-bold ' + (val ? "border-[#2ec4a5]/60 text-[#2ec4a5]" : isActive ? "border-[#e3a83c] text-transparent" : "border-[#4a4a4f] text-transparent") + '">' + esc(val || "____") + "</span>";
    }).join("");
    var used = filled.filter(Boolean);
    var done = nextBlank === -1;
    var activeIdx = S.clozeActive;
    if (activeIdx == null || activeIdx < 0 || filled[activeIdx] !== null) activeIdx = nextBlank;
    var b = done ? null : (blanks[activeIdx] || {});
    var hint = done
      ? '<div style="border-radius:10px;background:rgba(29,66,57,.55);padding:10px 14px;text-align:center;font-size:14px;color:#3fe0b4">✓ 全部填好，点「进入单词背诵」过关</div>'
      : '<div style="border-radius:10px;background:#222226;padding:10px 14px;text-align:center;font-size:14px;color:#a8a8ae">当前空：<span style="font-weight:600;color:#ececef">' + esc((b.pos ? b.pos + " " : "") + (b.plain || b.meaning || "（无语义）")) + "</span></div>";
    var chips = bank.map(function (w) {
      var u = used.indexOf(w) >= 0; var err = S.clozeErr === w;
      return '<button data-act="cloze-chip" data-w="' + esc(w) + '" ' + (u ? "disabled" : "") + ' class="flex-none rounded-[12px] px-[16px] py-[9px] text-[16px] font-semibold ' + (u ? "bg-[#1c1c20] text-[#4a4a4f]" : err ? "animate-pulse bg-[#4a1a24] text-[#ff8a8a]" : "bg-[#26262b] text-[#ececef]") + '">' + esc(w) + "</button>";
    }).join("");
    return '<header class="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2"><button data-act="cloze-back" class="flex items-center gap-2 text-[#c9c9ce]">' + ico(I.chevron, "h-[22px] w-[22px]") + '<span class="text-[15px] font-medium text-[#b9b9bf]">语篇填空</span></button></header>' +
      '<div data-scroll="cloze" class="min-h-0 flex-1 overflow-y-auto px-[26px] pb-2 [scrollbar-width:none]"><div class="mt-[10px] flex items-baseline justify-between"><h1 class="text-[26px] font-extrabold text-[#f5f5f7]">' + esc(p.title || "") + '</h1><span class="text-[13px] tabular-nums text-[#8c8c92]">' + used.length + "/" + (S.clozeTargets || []).length + "</span></div>" +
      '<p class="mt-[20px] text-[18px] leading-[2.05] text-[#d5d5da]">' + body + "</p>" +
      (done ? '<div style="margin-top:22px;border-radius:14px;background:rgba(29,66,57,.6);padding:14px 18px"><p style="font-size:15px;font-weight:600;color:#3fe0b4">✓ 全部填对！</p><p style="margin-top:4px;font-size:13px;color:#8fccc4">出错 ' + (S.clozeWrongs || 0) + " 次 · 建议现在进入单词背诵巩固</p></div>" : "") +
      "</div>" +
      '<div style="flex:none;border-top:1px solid rgba(255,255,255,.07);padding:12px 16px 0">' + hint + '<div style="margin-top:10px;display:flex;flex-wrap:wrap;gap:10px;max-height:32vh;overflow-y:auto;padding-bottom:8px;-webkit-overflow-scrolling:touch;scrollbar-width:none">' + chips + "</div></div>" +
      '<footer class="grid flex-none grid-cols-2 pb-[30px] pt-[6px]">' + dashBtn("返回语篇", "bg-[#5a5a60]", "cloze-back", true) + dashBtn(done ? "进入单词背诵" : "跳过填空", "bg-[#2ec4a5]", "cards-start") + "</footer>";
  }

  function ovChoice() {
    var card = S.rCur; if (!card) return "";
    var opts = S.choiceOpts || []; var f = card.fields || {};
    var optsHtml = opts.map(function (o, i) {
      var isRight = o.id === card.id; var of = o.fields || {};
      var cls = "bg-[#222226]/90";
      if (S.revealed) cls = isRight ? "bg-[#1d4239]" : "bg-[#4a1a24]";
      var inner = "";
      if (S.revealed) {
        inner += '<span data-act="word" data-w="' + esc(of.word) + '" class="mb-[3px] block text-[19px] font-semibold text-[#f0f0f2] underline decoration-dotted decoration-white/25 decoration-[1.5px] underline-offset-4">' + esc(of.word) + "</span>";
        var s0 = (arr(of.senses)[0]) || { pos: "", cn: [] };
        inner += '<span class="block text-[15.5px] leading-snug text-[#d5d5da]/85">' + ((isRight || S.prefs.confusion) ? esc(s0.pos || "") + " " + esc(arr(s0.cn).join("；")) : "· · ·") + "</span>";
      } else {
        var s = (arr(of.senses)[0]) || { pos: "", cn: [] };
        inner += '<span class="block text-[15px] text-[#a8a8ae]">' + esc(s.pos || "") + '</span><span class="mt-[3px] block text-[16.5px] leading-snug text-[#ececef]">' + esc(arr(s.cn).join("；")) + "</span>";
      }
      return '<button data-act="choice-pick" data-i="' + i + '" class="relative block w-full rounded-[16px] px-[18px] text-left transition-colors ' + cls + " " + (S.revealed ? "py-[17px]" : "py-[21px]") + '">' + inner + "</button>";
    }).join("");
    return topBar((S.rIdx + 1) + "/" + (S.retestCards || []).length, { canUndo: false, fav: !!S.favs[card.id], showKnown: false }) +
      '<div data-scroll="choice" class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px]">' + hero(card) + '<div class="min-h-[60px] flex-1"></div><div class="space-y-[13px] px-4 pb-5 pt-8">' + optsHtml + "</div></div>" +
      '<footer class="flex flex-none justify-center pb-[34px] pt-[6px]">' + (S.revealed ? dashBtn("继续", "bg-[#2ec4a5]", "choice-next") : dashBtn("看答案", "bg-[#e34d64]", "choice-reveal")) + "</footer>";
  }

  function ovSentence() {
    var v = S.sentView; if (!v) return "";
    var card = v.card, f = card.fields || {}; var details = arr(f.meaningDetails);
    var mIdx = Math.min(v.m || 0, Math.max(0, details.length - 1));
    var detail = details[mIdx] || { examples: [] }; var exs = arr(detail.examples);
    var exIdx = Math.min(v.ex || 0, Math.max(0, exs.length - 1)); var ex = exs[exIdx];
    if (!ex) return "";
    var pos = ""; arr(f.senses).forEach(function (s) { if (arr(s.cn).indexOf(detail.meaning) >= 0) pos = s.pos; });
    var dotsEx = exs.map(function (_, i) { return '<i class="h-[6px] w-[6px] rounded-full ' + (i === exIdx ? "bg-[#c9cfdf]" : "bg-[#454e6b]") + '"></i>'; }).join("");
    var dotsM = details.map(function (_, i) { return '<button data-act="sv-m" data-m="' + i + '" class="h-[8px] w-[8px] rounded-full ' + (i === mIdx ? "bg-[#e3a83c]" : "bg-[#5a5a60]") + '"></button>'; }).join("");
    return '<div class="absolute inset-0 z-[60] flex flex-col" style="background:' + BG + '">' +
      '<div class="mx-4 mt-[40px] flex min-h-0 flex-1 flex-col overflow-hidden rounded-[20px] bg-[#1d2337] shadow-[0_18px_60px_rgba(0,0,0,0.5)]">' +
        '<div class="flex flex-none items-center justify-between px-[20px] pt-[16px]"><span class="text-[15px] text-[#a9b0c8]">' + esc(ex.src || "") + '</span><span class="flex flex-col gap-[4px]"><i class="h-[2.5px] w-[18px] rounded-full bg-[#a9b0c8]"></i><i class="h-[2.5px] w-[18px] rounded-full bg-[#a9b0c8]"></i></span></div>' +
        '<div data-act="sv-speak" class="flex min-h-[150px] flex-1 cursor-pointer flex-col justify-end px-[20px] pb-[12px]"><p class="text-[20px] font-bold leading-[1.5] text-[#f0f0f2]">' + orangeWord(ex.en, f.word) + '</p><p class="mt-[8px] text-[15px] leading-relaxed text-[#8a91a8]">' + esc(ex.cn || "") + '</p>' +
          '<div class="mt-[16px] flex items-center"><button data-act="sv-star" class="text-[#8a91a8]">' + ico(I.star(!!v.star), "h-[20px] w-[20px]") + '</button><span class="flex flex-1 justify-center gap-[8px]">' + dotsEx + '</span><span class="w-[20px]"></span></div></div>' +
        '<div class="relative h-[212px] flex-none border-t border-white/[0.05] bg-[#232a48]"><div data-scroll="sent" class="h-full overflow-y-auto px-[20px] pb-[40px] pt-[18px] ' + (v.revealed ? "" : "blur-[10px] opacity-50") + '">' +
          '<p class="text-[17px] leading-[1.6] text-[#ececef]"><b class="mr-2 font-bold">' + esc(pos) + "</b>" + esc(detail.enDef || detail.meaning || "") + "</p>" +
          (detail.pattern ? '<span class="mt-[14px] inline-block rounded-[10px] border border-[#4a5578] px-[13px] py-[7px] text-[15px] font-semibold text-[#c9cfdf]">' + esc(detail.pattern) + "</span>" : "") +
        "</div>" + (v.revealed ? "" : '<button data-act="sv-reveal" class="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 px-[18px] py-[10px] text-[16px] text-[#c9cfdf]">查看双语释义</button>') +
        '<span class="absolute bottom-[12px] right-[18px] text-[14px] tabular-nums text-[#8a91a8]">' + (exIdx + 1) + "/" + exs.length + "</span></div></div>" +
      '<footer class="grid flex-none grid-cols-2 pb-[26px] pt-[16px]">' + dashBtn("下一词", "bg-[#2ec4a5]", "sv-next") + dashBtn("收起卡片", "bg-[#e3a83c]", "sv-close") + "</footer></div>";
  }

  /* 词卡：贴着点中的词弹，小卡，尽量不挡视线 */
  /* 词卡：贴着点中的词弹，小卡 + 小尖角，不挡视线 */
  /* 词卡：钉在所选词下方；样式全内联，不依赖 Tailwind 产物 */
  function dictPopup(inner) {
    var vw = window.innerWidth || 360, vh = window.innerHeight || 640;
    var CW = Math.min(300, vw - 24);
    var a = S.dictAnchor;
    var left, top, estH = 210;
    if (a) {
      left = a.left + a.width / 2 - CW / 2;
      if (left < 12) left = 12;
      if (left + CW > vw - 12) left = vw - 12 - CW;
      top = a.bottom + 12;
      if (top + estH > vh - 12) {
        top = a.top - 12 - estH;
        if (top < 12) top = Math.max(12, vh - 12 - estH);
      }
    } else {
      left = (vw - CW) / 2; top = Math.round(vh * 0.38);
    }
    var st = "position:fixed;z-index:71;width:" + CW + "px;left:" + Math.round(left) + "px;top:" + Math.round(top) + "px;" +
             "background:#262c44;border-radius:18px;padding:16px 20px 18px;box-shadow:0 18px 60px rgba(0,0,0,0.55);";
    return '<div data-stop="1" style="' + st + '">' + inner + "</div>";
  }

  function ovDict() {
    if (!S.dictWord) return "";
    var e = S.dictEntry; var w = (e && e.word) || S.dictWord.toLowerCase();
    if (S.dictExpanded && e) {
      var tabs = ["柯林斯", "例句", "派生", "词根", "近义", "真题", "笔记"];
      var colloc = arr(e.collocations).map(function (c) { return '<div class="mb-[12px]"><p class="text-[17px] text-[#ececef]">' + esc(c.en) + '</p><p class="mt-[2px] text-[15px] text-[#8a91a8]">' + esc(c.cn) + "</p></div>"; }).join("");
      var exs = arr(e.examples).map(function (ex) {
        return '<div class="mb-[20px]"><p class="text-[17px] leading-[1.6] text-[#ececef]">' + orangeWord(ex.en, w) + "</p>" + (ex.cn ? '<p class="mt-[5px] text-[15px] leading-relaxed text-[#8a91a8]">' + esc(ex.cn) + "</p>" : "") + "</div>";
      }).join("");
      var senses = arr(e.senses).map(function (s, i) { return '<p class="text-[17px] leading-relaxed text-[#ececef]"><span class="mr-2 text-[15px] text-[#a9b0c8]">' + esc(s.pos) + '</span><span class="' + (i === 0 ? "font-bold" : "") + '">' + esc(s.cn) + "</span></p>"; }).join("");
      return '<div data-act="dict-close" class="absolute inset-0 z-[70] flex flex-col justify-end bg-black/55"><div data-stop="1" class="flex h-[94%] flex-col rounded-t-[24px] bg-[#1e2338] px-[22px]">' +
        '<div class="flex flex-none justify-center pb-1 pt-[10px]"><span class="h-[4px] w-[44px] rounded-full bg-white/20"></span></div>' +
        '<div data-scroll="dict" class="min-h-0 flex-1 overflow-y-auto pb-24"><div class="flex items-start justify-between pt-[10px]"><h2 class="text-[34px] font-extrabold leading-tight text-[#f0a824]">' + esc(w) + '</h2>' +
        '<button data-act="dict-fav" class="mt-2 ' + (S.dictFavs[w] ? "text-[#f0a824]" : "text-[#a9b0c8]") + '">' + ico(I.star(!!S.dictFavs[w]), "h-[22px] w-[22px]") + "</button></div>" +
        (e.phonetic ? '<button data-act="dict-speak" class="mt-[10px] flex items-center gap-2"><span class="flex items-center gap-[6px] rounded-full bg-[#2c3350] px-[12px] py-[5px]"><span class="text-[11px] text-[#a9b0c8]">美</span>' + ico(I.speaker, "h-[11px] w-[11px] text-[#a9b0c8]") + '</span><span class="text-[15px] text-[#a9b0c8]">' + esc(e.phonetic) + "</span></button>" : "") +
        '<div class="mt-[18px] space-y-[6px]">' + senses + "</div>" +
        (colloc ? '<div class="mt-[18px] border-t border-white/[0.08] pt-[18px]">' + colloc + "</div>" : "") +
        '<div class="mt-[20px] space-y-[24px]">' + exs + "</div></div>" +
        '<button data-act="dict-close" class="absolute bottom-[26px] right-[22px] flex h-[54px] w-[54px] items-center justify-center rounded-full bg-[#2b3152]/95 text-[#ececef]">' + ico(I.close, "h-[20px] w-[20px]") + "</button></div></div>";
    }
    var inner;
    if (!e) {
      inner = '<p style="font-size:18px;font-weight:700;color:#f0a824">' + esc(S.dictWord.toLowerCase()) + '</p>' +
              '<p style="margin-top:8px;font-size:13px;color:#8a91a8">没有查到这个词 🤔</p>';
    } else {
      inner = '<div style="display:flex;align-items:flex-start;justify-content:space-between">' +
                '<h2 style="font-size:25px;font-weight:800;line-height:1.15;color:#f0a824">' + esc(w) + '</h2>' +
                '<button data-act="dict-fav" style="margin-top:2px;' + (S.dictFavs[w] ? "color:#f0a824" : "color:#a9b0c8") + '">' + ico(I.star(!!S.dictFavs[w]), "h-[22px] w-[22px]") + "</button>" +
              "</div>" +
              (e.phonetic ? '<button data-act="dict-speak" style="margin-top:9px;display:flex;align-items:center;gap:8px"><span style="display:flex;align-items:center;gap:5px;border-radius:999px;background:#2c3350;padding:3px 9px"><span style="font-size:10px;color:#a9b0c8">美</span>' + ico(I.speaker, "h-[11px] w-[11px] text-[#a9b0c8]") + '</span><span style="font-size:14px;color:#a9b0c8">' + esc(e.phonetic) + "</span></button>" : "") +
              '<div style="margin-top:13px">' + arr(e.senses).slice(0, 2).map(function (s, i) { return '<p style="margin-top:5px;font-size:15.5px;line-height:1.35;color:#ececef"><span style="margin-right:6px;font-size:13px;color:#a9b0c8">' + esc(s.pos) + '</span><span style="' + (i === 0 ? "font-weight:600" : "") + '">' + esc(s.cn) + "</span></p>"; }).join("") + "</div>" +
              '<button data-act="dict-expand" style="margin-top:13px;font-size:13.5px;color:#a9b0c8">查看详细释义 <span style="color:#7a8098">›</span></button>';
    }
    return '<div data-act="dict-close" class="absolute inset-0 z-[70]">' + dictPopup(inner) + "</div>";
  }

  function ovExam() {
    var card = S.card; if (!card || !S.examOpen) return "";
    var f = card.fields || {}; var exams = arr(f.exams);
    var levels = ["中考", "高考", "四级", "六级", "考研", "专升本", "雅思"];
    var chips = levels.map(function (lv) { return '<span class="rounded-full px-[19px] py-[7px] text-[14px] ' + (lv === "考研" ? "bg-[#e3a83c] font-semibold text-[#241a05]" : "bg-[#26262b] text-[#8c8c92]") + '">' + lv + "</span>"; }).join("");
    var list = exams.length ? exams.map(function (ex) { return '<div class="mb-[26px]">' + clickable(ex.en, f.word, S.dictWord, "text-[17px] leading-[1.6] text-[#ececef]") + '<p class="mt-[7px] text-[13.5px] text-[#7c7c82]">' + esc(ex.src || "") + "</p></div>"; }).join("") : '<p class="mt-10 text-center text-[14px] text-[#5a5a60]">该词暂无真题记录</p>';
    return '<div class="absolute inset-0 z-50 flex flex-col" style="background:' + BG + '">' +
      '<div class="flex flex-none items-center gap-3 px-4 pt-[22px]"><div class="flex flex-1 items-center gap-2.5 rounded-full bg-[#26262b] px-4 py-[10px]"><span class="flex-1 text-[17px] text-[#ececef]">' + esc(f.word) + '</span></div><button data-act="exam-close" class="text-[16px] text-[#c9c9ce]">取消</button></div>' +
      '<div class="mt-[16px] flex flex-none flex-wrap gap-[10px] px-4">' + chips + "</div>" +
      '<div data-scroll="exam" class="mt-[18px] min-h-0 flex-1 overflow-y-auto px-5 pb-24"><p class="mb-[18px] text-[14px] text-[#a8a8ae]">在历年真题中出现 <b class="text-[#e3a83c]">' + exams.length + "</b> 次</p>" + list + "</div>" +
      '<button data-act="exam-close" class="absolute bottom-[26px] right-[22px] flex h-[54px] w-[54px] items-center justify-center rounded-full bg-[#2b2b3a]/90 text-[#ececef]">' + ico(I.close, "h-[20px] w-[20px]") + "</button></div>";
  }

  function ovNote() {
    var card = S.card; if (!card || !S.noteOpen) return "";
    var f = card.fields || {}; var s0 = (arr(f.senses)[0]) || { pos: "", cn: [] };
    return '<div class="absolute inset-0 z-50 flex flex-col" style="background:' + BG + '">' +
      '<p class="pb-2 pt-[26px] text-center text-[17px] font-semibold text-[#ececef]">' + esc(f.word) + ' 的笔记</p>' +
      '<div class="mx-4 mt-[100px] flex h-[46%] flex-col rounded-[16px] bg-[#26262b] p-[17px]"><textarea data-role="note" maxlength="1000" placeholder="写下你的笔记..." class="w-full flex-1 resize-none bg-transparent text-[16px] leading-relaxed text-[#ececef] caret-[#e3a83c] outline-none placeholder:text-[#7c7c82]">' + esc(S.noteDraft || "") + "</textarea>" +
      '<div class="flex flex-none items-center gap-[9px] pt-3"><span class="rounded-full bg-[#37373d] px-[13px] py-[6px] text-[13px] text-[#c5c5ca]">' + esc(f.word) + '</span><span class="max-w-[180px] truncate rounded-full bg-[#37373d] px-[13px] py-[6px] text-[13px] text-[#c5c5ca]">' + esc(s0.pos) + esc(arr(s0.cn).join("；")) + '</span><span class="flex-1"></span><span data-role="note-count" class="text-[13px] tabular-nums text-[#7c7c82]">' + (S.noteDraft || "").length + "/1000</span></div></div>" +
      '<div class="flex flex-1 items-end justify-between px-4 pb-[30px]"><button data-act="note-close" class="flex h-[52px] w-[52px] items-center justify-center rounded-[16px] bg-[#26262b] text-[#ececef]">' + ico(I.close, "h-[20px] w-[20px]") + '</button><button data-act="note-save" class="flex h-[52px] w-[52px] items-center justify-center rounded-[16px] ' + ((S.noteDraft || "").trim() ? "bg-[#2ec4a5] text-[#0c2620]" : "bg-[#26262b] text-[#5a5a60]") + '"><svg viewBox="0 0 24 24" class="h-[21px] w-[21px]" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></button></div></div>';
  }

  function ovSpell() {
    var card = S.card; if (!card || !S.spellOpen) return "";
    var f = card.fields || {}; var s0 = (arr(f.senses)[0]) || { pos: "", cn: [] };
    var bcls = S.spellState === "right" ? "border-[#2ec4a5] text-[#2ec4a5]" : S.spellState === "wrong" ? "border-[#e34d64] text-[#e34d64]" : "border-[#3a3a40] text-[#f0f0f2] focus:border-[#8a8a90]";
    return '<div class="absolute inset-0 z-50 flex flex-col" style="background:' + BG + '">' +
      '<p class="pb-2 pt-[26px] text-center text-[17px] font-semibold text-[#ececef]">拼写测验</p>' +
      '<div class="flex-1 px-[34px] pt-[70px]"><p class="text-[18px] leading-relaxed text-[#ececef]"><span class="mr-3 text-[15px] text-[#a8a8ae]">' + esc(s0.pos) + "</span>" + esc(arr(s0.cn).join("；")) + "</p>" +
      '<input data-role="spell" value="' + esc(S.spellInput) + '" autocomplete="off" spellcheck="false" placeholder="拼出对应的英文单词" ' + (S.spellState === "right" ? "disabled" : "") + ' class="mt-[44px] w-full border-b-2 bg-transparent pb-[10px] font-mono text-[26px] tracking-[0.12em] outline-none placeholder:text-[15px] placeholder:text-[#5a5a60] ' + bcls + '" />' +
      '<div class="mt-[22px] min-h-[30px]">' + (S.spellState === "right" ? '<p class="text-[15px] font-medium text-[#2ec4a5]">拼写正确</p>' : S.spellState === "wrong" ? '<p class="text-[15px] font-medium text-[#e34d64]">再想想，或直接返回</p>' : "") + "</div></div>" +
      '<footer class="grid flex-none grid-cols-2 pb-[34px]">' + dashBtn("返回", "bg-[#5a5a60]", "spell-back", true) + (S.spellState === "right" ? dashBtn("完成", "bg-[#2ec4a5]", "spell-done") : dashBtn("检查", "bg-[#2ec4a5]", "spell-check")) + "</footer></div>";
  }

  function ovMenu() {
    if (!S.menuOpen) return "";
    var items = [["设置", "menu-settings"], ["沉浸场景", "menu-noop"], ["小窍门", "menu-noop"], ["纠错｜举报", "menu-noop"]];
    return '<div data-act="menu-close" class="absolute inset-0 z-[72]"><div data-stop="1" class="absolute right-[14px] top-[54px] w-[216px] overflow-hidden rounded-[18px] bg-[#262c44] shadow-[0_16px_50px_rgba(0,0,0,0.55)]">' +
      items.map(function (it, i) { return '<button data-act="' + it[1] + '" class="flex w-full items-center gap-[14px] px-[20px] py-[16px] text-left text-[16px] text-[#ececef] ' + (i > 0 ? "border-t border-white/[0.07]" : "") + '">' + esc(it[0]) + "</button>"; }).join("") + "</div></div>";
  }

  function ovSettings() {
    if (!S.settingsOpen) return "";
    var rows = [["passage", "语篇阅读", "学习前先通读语篇"], ["cloze", "语篇填空", "通读后进行选词填空"], ["confusion", "易混辨析", "显示选择题错误选项词义"], ["syllable", "拆分助记", "词义页自动音节拆分"], ["clozeEx", "例句填空", "学习正面例句挖空目标词"], ["topbar", "系统顶栏", "显示 App 原生顶栏；关掉只留本页顶栏"]];
    var html = rows.map(function (r) {
      var on = S.prefs[r[0]];
      return '<div class="mb-[6px] flex items-center justify-between rounded-[14px] px-[6px] py-[10px]"><div><p class="text-[16px] font-medium text-[#ececef]">' + esc(r[1]) + '</p><p class="mt-[2px] text-[12.5px] text-[#8a91a8]">' + esc(r[2]) + "</p></div>" +
        '<button data-act="pref-toggle" data-k="' + r[0] + '" class="relative h-[28px] w-[50px] flex-none rounded-full ' + (on ? "bg-[#f0a824]" : "bg-[#3a3a44]") + '"><span class="absolute top-[3px] h-[22px] w-[22px] rounded-full bg-white shadow ' + (on ? "left-[25px]" : "left-[3px]") + '"></span></button></div>';
    }).join("");
    return '<div data-act="settings-close" class="absolute inset-0 z-[74] flex flex-col justify-end bg-black/55"><div data-stop="1" class="rounded-t-[24px] bg-[#1e2338] px-5 pb-[34px] pt-[18px]">' +
      '<div class="relative mb-[18px]"><p class="text-center text-[17px] font-semibold text-[#ececef]">学习设置</p><button data-act="settings-close" class="absolute right-0 top-1/2 flex h-[30px] w-[30px] -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-[#c9cfdf]">' + ico(I.close, "h-[14px] w-[14px]") + "</button></div>" + html +
      '<div class="mt-[12px] rounded-[14px] bg-[#26262b] px-[12px] py-[12px]"><div class="flex items-center justify-between"><p class="text-[16px] font-medium text-[#ececef]">有道词典</p><span class="text-[12px] ' + (S.dictCfg && S.dictCfg.configured ? "text-[#2ec4a5]" : "text-[#8a91a8]") + '">' + (S.dictCfg && S.dictCfg.configured ? "已配置" : "未配置") + '</span></div><p class="mt-[3px] text-[12.5px] text-[#8a91a8]">有道智云应用 ID / 密钥，查词走后端签名</p><input data-role="dict-key" placeholder="应用ID appKey" value="' + esc(S.dictKey || "") + '" class="mt-[9px] w-full rounded-[10px] bg-[#1c1c20] px-[11px] py-[9px] text-[14px] text-[#ececef] outline-none placeholder:text-[#5a5a60]" /><input data-role="dict-secret" type="password" placeholder="应用密钥 appSecret" value="' + esc(S.dictSecret || "") + '" class="mt-[7px] w-full rounded-[10px] bg-[#1c1c20] px-[11px] py-[9px] text-[14px] text-[#ececef] outline-none placeholder:text-[#5a5a60]" /><button data-act="dict-save" class="mt-[9px] w-full rounded-[10px] bg-[#f0a824] py-[9px] text-[15px] font-semibold text-black">保存并启用</button></div>' +
      '<button data-act="order-open" class="mt-[8px] flex w-full items-center justify-between rounded-[14px] px-[6px] py-[12px]"><span class="text-[16px] font-medium text-[#ececef]">助记顺序</span><span class="max-w-[60%] truncate text-[13.5px] text-[#8a91a8]">' + S.tabOrder.map(function (t) { return TABS[t]; }).join(" - ") + ' <span class="text-[#5a6178]">›</span></span></button></div></div>';
  }

  function ovOrder() {
    if (!S.orderOpen) return "";
    var rows = S.tabOrder.map(function (t, i) {
      return '<div class="mb-[10px] flex items-center justify-between rounded-[14px] bg-[#262c44] px-[18px] py-[15px]"><span class="text-[16px] text-[#ececef]">' + esc(TABS[t]) + '</span><span class="flex items-center gap-[10px]">' +
        '<button data-act="order-up" data-i="' + i + '" class="flex h-[30px] w-[30px] items-center justify-center rounded-full bg-white/10 text-[#c9cfdf]">↑</button>' +
        '<button data-act="order-down" data-i="' + i + '" class="flex h-[30px] w-[30px] items-center justify-center rounded-full bg-white/10 text-[#c9cfdf]">↓</button></span></div>';
    }).join("");
    return '<div data-act="order-close" class="absolute inset-0 z-[74] flex flex-col justify-end bg-black/55"><div data-stop="1" class="rounded-t-[24px] bg-[#1e2338] px-5 pb-[34px] pt-[18px]">' +
      '<div class="relative mb-[18px]"><p class="text-center text-[17px] font-semibold text-[#ececef]">助记顺序</p><button data-act="order-close" class="absolute right-0 top-1/2 flex h-[30px] w-[30px] -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-[#c9cfdf]">' + ico(I.close, "h-[14px] w-[14px]") + "</button></div>" + rows + "</div></div>";
  }

  function renderOverlays() {
    var h = "";
    if (S.phase === "passage") h += ovPassage();
    else if (S.phase === "cloze") h += ovCloze();
    else if (S.phase === "choice") h += ovChoice();
    else if (S.phase === "sentCloze") h += ovSentCloze();
    if (S.sentView) h += ovSentence();
    if (S.dictWord) h += ovDict();
    if (S.examOpen) h += ovExam();
    if (S.noteOpen) h += ovNote();
    if (S.spellOpen) h += ovSpell();
    if (S.menuOpen) h += ovMenu();
    if (S.settingsOpen) h += ovSettings();
    if (S.orderOpen) h += ovOrder();
    if (S.sr) h += ovSpellRound();
    else if (S.srAsk > 0) h += ovSpellAsk();
    return h;
  }
  overlays = renderOverlays;

  /* ===================== PART2-B：事件 + 初始化 ===================== */

  function closestAct(el) {
    while (el && el !== root) {
      if (el.getAttribute) {
        if (el.getAttribute("data-act")) return { el: el, act: el.getAttribute("data-act") };
        if (el.getAttribute("data-word")) return { el: el, word: el.getAttribute("data-word") };
        if (el.getAttribute("data-stop") != null) return null;
      }
      el = el.parentNode;
    }
    return null;
  }

  function dictCandidates(raw) {
    var w = String(raw || "").toLowerCase().replace(/[^a-z'-]/g, "");
    var out = [w];
    if (w.slice(-3) === "ies") out.push(w.slice(0, -3) + "y");
    if (w.slice(-2) === "es") out.push(w.slice(0, -2));
    if (w.slice(-1) === "s") out.push(w.slice(0, -1));
    if (w.slice(-3) === "ing") out.push(w.slice(0, -3), w.slice(0, -3) + "e");
    if (w.slice(-2) === "ed") out.push(w.slice(0, -2), w.slice(0, -1), w.slice(0, -2) + "e");
    if (w.slice(-1) === "d") out.push(w.slice(0, -1));
    var seen = {};
    return out.filter(function (x) { return x && !seen[x] && (seen[x] = 1); });
  }
  var _dictCache = {};
  /* 查词：① 本轮词书里现成的卡（离线，最快）② 有道（壳侧签名 HTTP） */
  function lookup(w) {
    var key = String(w || "").toLowerCase().replace(/[^a-z'-]/g, "");
    if (!key) return Promise.resolve(null);
    if (_dictCache.hasOwnProperty(key)) return Promise.resolve(_dictCache[key]);

    // ① 词书里已收录的词 —— 直接用卡上的完整数据
    var cands = dictCandidates(key);
    var pool = [];
    if (S.card) pool.push(S.card);
    S.queue.forEach(function (c) { if (c && c !== S.card) pool.push(c); });
    for (var j = 0; j < pool.length; j++) {
      var f = pool[j].fields || {};
      if (cands.indexOf(String(f.word || "").toLowerCase()) >= 0) {
        var e = { word: f.word, phonetic: f.phonetic, level: "考研",
          senses: arr(f.senses).map(function (s) { return { pos: s.pos, cn: arr(s.cn).join("；") }; }),
          collocations: arr(f.collocations),
          examples: [{ en: (f.sentence || {}).en, cn: (f.sentence || {}).cn, src: "词书例句" }].concat(arr(f.exams).map(function (x) { return { en: x.en, src: x.src }; })) };
        _dictCache[key] = e; return Promise.resolve(e);
      }
    }

    // ② 有道插件（未配置 / 查不到 → null）
    return pluginCall("youdao", "lookup", { w: key }).then(function (r) {
      var e = (r && r.ok && r.data) ? r.data : null;
      _dictCache[key] = e;
      return e;
    }).catch(function () { _dictCache[key] = null; return null; });
  }
  function openDict(w, el) {
    S.dictWord = w; S.dictExpanded = false; S.dictEntry = null; S.dictAnchor = null;
    if (el && el.getBoundingClientRect) {
      var r = el.getBoundingClientRect();
      if (r) S.dictAnchor = { top: r.top, left: r.left, bottom: r.bottom, width: r.width };
    }
    paint();
    lookup(w).then(function (e) { S.dictEntry = e; if (S.dictWord === w) paint(); });
  }

  /* ---- 例句轮播卡 ---- */
  function openSV(m) {
    S.sentView = { card: S.card, m: m || 0, ex: 0, revealed: false, star: false };
    var d = arr((S.card.fields || {}).meaningDetails)[m || 0];
    if (d && arr(d.examples)[0]) speak(arr(d.examples)[0].en, TTS_PASSAGE);
    paint();
  }

  /* ---- 会话：拉队列 ---- */
  function extractIds(plan) {
    if (!plan) return [];
    if (Array.isArray(plan.ids)) return plan.ids;
    var out = [];
    arr(plan.units).forEach(function (u) {
      arr(u && u.cards).forEach(function (c) { if (c && c.id) out.push(c.id); });
    });
    return out;
  }
  function fetchCards(ids) {
    var out = [], chain = Promise.resolve();
    ids.forEach(function (id) {
      chain = chain.then(function () {
        return call("card.get", { id: id }).then(function (r) { if (r && r.card && r.card.id) out.push(r.card); });
      });
    });
    return chain.then(function () { return out; });
  }
  /* 读回每张卡的 KV（笔记 / 收藏 / 标熟）。
     壳那边 state.kvPut 是落盘的（progress.log.jsonl + progress.json 的 card_kv），
     但重启后必须主动 kvGet 拉回来 —— 否则 S.notes 永远空，界面一直「暂无笔记」。 */
  function hydrateKv(cards) {
    return Promise.all(arr(cards).map(function (c) {
      if (!c || !c.id) return null;
      return call("state.kvGet", { id: c.id }).then(function (kv) {
        if (!kv) return;
        if (kv.note != null && String(kv.note).length) S.notes[c.id] = String(kv.note);
        if (kv.fav != null) S.favs[c.id] = !!kv.fav;
        if (kv.known != null) S.learned[c.id] = !!kv.known;
      }).catch(function () {});
    }));
  }
  function startSession(mode) {
    S.screen = mode; S.phase = "cards"; S.idx = 0; S.face = "front"; S.tab = "colloc";
    S.browse = false; S.scene = mode;
    S.hinted = false; S.missed = []; S.wrongs = 0; S.history = []; S.learned = {}; S._spokenId = null; S._passageSpoken = false;
    S.ratings = {}; S.passage = null; S.retestCards = []; S.rIdx = 0; S.revealed = false; S.picked = null; S.plan = null;
    S.clozeBlanks = []; S.clozeFilled = []; S.clozeWrong = []; S.clozeFailed = []; S.clozeActive = 0;
    S.queue = []; S.card = null; paint();
    log("startSession " + mode);
    call("session.plan", {}).then(function (plan) {
      S.plan = plan || null;
      var ids = extractIds(plan);
      log("session.plan -> ids=" + ids.length + " units=" + arr(plan && plan.units).length);
      if (ids.length) return ids;
      var m2 = mode === "learn" ? "card.new" : "card.due";
      return call(m2, { limit: 50 }).then(function (r) {
        var got = arr(r && r.ids);
        log(m2 + " -> ids=" + got.length + " head=" + JSON.stringify(got.slice(0, 3)));
        return got;
      });
    }).then(function (ids) {
      if (!ids.length) { log("EMPTY queue -> done"); S.phase = "done"; paint(); return; }
      return fetchCards(ids).then(function (cards) {
        log("card.get -> cards=" + cards.length);
        S.queue = cards; S.idx = 0; S.card = cards[0] || null;
        if (!S.card) S.phase = "done";
        return hydrateKv(cards);
      }).then(function () {
        /* 语篇：仅「学习」模式 + 开关开 + 计划第一单元带语篇 → 先通读 */
        var u0 = arr(S.plan && S.plan.units)[0];
        if (mode === "learn" && S.prefs.passage && u0 && u0.hasPassage && u0.passage) {
          S.passage = u0.passage; S.phase = "passage";
          log("startSession -> 语篇通读 segments=" + arr(u0.passage.segments).length);
        } else {
          S.phase = "cards";
        }
        reportProgress(); paint(); saveSession();
      });
    }).catch(function (e) { log("startSession ERR " + (e && e.message ? e.message : e)); });
  }
  /* ===================== 拼写轮（背完一轮加练） =====================
     复刻 bubei_dark 的「挖空填字母」：每个字母一格，逐格填。
     句子拼写（挖空）/ 单词拼写（给中文填英文）两种形态。
     3 次机会，错词放回队尾，循环到全过或用户点「结束拼写」。
     纯加练，不写 FSRS。 */
  var SR_MAX_TRIES = 3;

  function spellCnOf(f) {
    var parts = [];
    arr(f && f.senses).forEach(function (s) {
      var cn = String(arr(s.cn).join("；") || s.meaning || "")
        .replace(/[（(][^（()）]*[)）]/g, "").trim();
      if (!cn) return;
      var pos = String(s.pos || "").trim();
      parts.push((pos ? pos + " " : "") + cn);
    });
    return parts.join("；");
  }

  /* 组这一轮要拼的条目：有例句 → 句子拼写；没有 → 单词拼写。标熟跳过。 */
  function buildSpellItems(cards) {
    var sent = [], single = [];
    arr(cards).forEach(function (c) {
      if (!c || !c.id) return;
      if (S.learned[c.id]) return;
      var f = c.fields || {};
      var w = String(f.word || "").trim();
      if (!w) return;
      var cn = spellCnOf(f);
      var se = String((f.sentence || {}).en || "").trim();
      if (se) sent.push({ kind: "sentence", id: c.id, word: w, cn: cn, sentence: se });
      else single.push({ kind: "word", id: c.id, word: w, cn: cn });
    });
    return sent.concat(single);
  }

  /* 把例句里的目标词抠成 ______（返回题干 + 要拼的答案） */
  function srBlankSentence(text, word) {
    var src = String(text || "");
    var w = String(word || "").trim();
    if (!w) return { text: src, answer: "" };
    var safe = w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    var re = new RegExp("\\b" + safe + "\\w*", "i");
    var hit = src.match(re);
    if (!hit) return { text: src, answer: w };
    return {
      text: src.slice(0, hit.index) + "______" + src.slice(hit.index + hit[0].length),
      answer: hit[0]
    };
  }

  function srBegin() {
    var pool = arr(S.srItems).slice();
    S.srAsk = 0;
    S.sr = { pool: pool, total: pool.length, done: 0, cur: null,
             answer: "", typed: "", tries: 0, revealed: false, pending: null };
    srNext();
  }

  function srEnd() {
    S.sr = null; S.srItems = [];
    if (FC.onSpellDone) FC.onSpellDone();
    else { S.phase = "done"; paint(); }
  }

  function srNext() {
    var st = S.sr;
    if (!st) return;
    if (!st.pool.length) { srEnd(); return; }
    var it = st.pool[0];
    var answer = String(it.word || "");
    var prompt = "";
    if (it.kind === "sentence") {
      var r = srBlankSentence(it.sentence, it.word);
      prompt = r.text;
      answer = r.answer || it.word;
    }
    st.cur = it; st.answer = String(answer || "").trim();
    st.typed = ""; st.tries = 0; st.revealed = false; st.pending = null;
    st.prompt = prompt;
    paint();
    srFocus();
  }

  function srFocus() {
    var inp = root.querySelector('[data-role="sr"]');
    if (!inp) return;
    setTimeout(function () { try { inp.focus(); } catch (e) {} }, 60);
  }

  function srSlotsHtml() {
    var st = S.sr;
    if (!st) return "";
    var out = "";
    for (var i = 0; i < st.answer.length; i++) {
      var ch = st.typed.charAt(i);
      out += '<span class="flex h-[40px] w-[24px] items-end justify-center border-b-2 pb-[2px] font-mono text-[24px] leading-none ' +
        (ch ? "border-[#2ec4a5] text-[#2ec4a5]" : "border-[#4a4a4f] text-transparent") + '">' +
        esc(ch || "_") + "</span>";
    }
    return out;
  }

  /* 局部刷新格子 —— 输入时不整体 paint，否则输入框重建、焦点丢失 */
  function srRepaintCells() {
    var host = root.querySelector('[data-role="sr-slots"]');
    if (host) host.innerHTML = srSlotsHtml();
    var inp = root.querySelector('[data-role="sr"]');
    if (inp && S.sr) inp.value = S.sr.typed;
  }

  function srOnInput(v) {
    var st = S.sr;
    if (!st || st.revealed || st.pending) return;
    var s = String(v || "").replace(/[^A-Za-z'’-]/g, "");
    if (s.length > st.answer.length) s = s.slice(0, st.answer.length);
    st.typed = s;
    var inp = root.querySelector('[data-role="sr"]');
    if (inp) inp.value = s;
    srRepaintCells();
    if (st.answer.length && s.length >= st.answer.length) srCheck();
  }

  function srCheck() {
    var st = S.sr;
    if (!st || st.revealed || st.pending || !st.typed) return;
    if (st.typed.toLowerCase() === st.answer.toLowerCase()) {
      st.revealed = true;
      st.done += 1;
      speak(st.answer, TTS_WORD);
      paint();
      setTimeout(function () {
        if (!S.sr || S.sr !== st || !st.revealed) return;
        st.pool.shift();
        srNext();
      }, 650);
      return;
    }
    st.tries += 1;
    if (st.tries >= SR_MAX_TRIES) {
      st.pending = "forget";
      srReveal();
    } else {
      st.typed = "";
      paint();
      srFocus();
    }
  }

  function srReveal() {
    var st = S.sr;
    if (!st) return;
    st.revealed = true;
    st.typed = st.answer;
    speak(st.answer, TTS_WORD);
    paint();
  }

  function srAction(k) {
    var st = S.sr;
    if (!st) return;
    if (k === "quit") { srEnd(); return; }

    if (st.pending) {
      if (k !== "next") return;
      var p = st.pending;
      st.pending = null;
      if (p === "skip") { st.pool.shift(); st.done += 1; }
      else { var it = st.pool.shift(); if (it) st.pool.push(it); }   // 忘记 → 回队尾
      srNext();
      return;
    }
    if (k === "skip") { st.pending = "skip"; srReveal(); return; }
    if (k === "forget") { st.pending = "forget"; srReveal(); return; }
    if (k === "hint") {
      st.tries += 1;
      speak(st.answer, TTS_WORD);
      if (st.tries >= SR_MAX_TRIES) { st.pending = "forget"; srReveal(); }
      else { paint(); srFocus(); }
      return;
    }
  }

  function ovSpellAsk() {
    var n = S.srAsk;
    return '<div class="absolute inset-0 z-[78] flex items-center justify-center bg-black/60 px-8">' +
      '<div class="w-full rounded-[22px] bg-[#1e2338] px-[22px] pb-[22px] pt-[24px] text-center shadow-[0_18px_60px_rgba(0,0,0,0.55)]">' +
        '<p class="text-[19px] font-bold text-[#f0f0f2]">这一轮背完了 🎉</p>' +
        '<p class="mt-[8px] text-[14px] leading-relaxed text-[#8a91a8]">再拼写 ' + n + ' 个词？拼错回队尾重来，不计入复习进度。</p>' +
        '<div class="mt-[20px] grid grid-cols-2 gap-[12px]">' +
          '<button data-act="sr-no" class="rounded-[14px] bg-[#26262b] py-[14px] text-[16px] font-semibold text-[#c9c9ce]">先不拼</button>' +
          '<button data-act="sr-go" class="rounded-[14px] bg-[#2ec4a5] py-[14px] text-[16px] font-semibold text-[#0c2620]">开始拼写</button>' +
        "</div></div></div>";
  }

  function ovSpellRound() {
    var st = S.sr;
    if (!st || !st.cur) return "";
    var it = st.cur;
    var kind = it.kind === "sentence" ? "句子拼写" : "单词拼写";
    var left = Math.max(0, SR_MAX_TRIES - st.tries);

    var promptHtml = "";
    if (st.prompt && st.prompt.indexOf("______") >= 0) {
      promptHtml = esc(st.prompt).replace("______",
        '<span class="mx-[3px] inline-block min-w-[86px] border-b-2 border-[#e3a83c] align-middle"></span>');
    }

    var result = "";
    if (st.revealed) {
      result = st.pending
        ? '<p class="mt-[16px] text-[15px] font-medium text-[#e34d64]">✕ 正确拼写：' + esc(st.answer) + "</p>"
        : '<p class="mt-[16px] text-[15px] font-medium text-[#2ec4a5]">✓ ' + esc(st.answer) + "</p>";
    }

    var actions = st.pending
      ? '<div class="col-span-2 flex justify-center">' + dashBtn("继续", "bg-[#2ec4a5]", "sr-next") + '</div>'
      : dashBtn("忘记了", "bg-[#e34d64]", "sr-forget") + dashBtn("跳过", "bg-[#5a5a60]", "sr-skip", true);

    return '<div class="absolute inset-0 z-[76] flex flex-col" style="background:' + BG + '">' +
      '<header class="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2">' +
        '<span class="text-[15px] font-medium tabular-nums text-[#b9b9bf]">拼写 ' + st.done + " / " + st.total + "</span>" +
        '<button data-act="sr-quit" class="text-[14px] text-[#a8a8ae]">结束拼写</button>' +
      "</header>" +
      '<div class="flex min-h-0 flex-1 flex-col items-center px-[26px]">' +
        '<span class="mt-[8px] rounded-full bg-[#29292e] px-[12px] py-[4px] text-[12.5px] text-[#a8a8ae]">' + kind + "</span>" +
        '<p class="mt-[14px] text-center text-[16px] leading-relaxed text-[#d5d5da]">' + esc(it.cn || "") + "</p>" +
        (promptHtml ? '<p class="mt-[20px] text-center text-[19px] font-bold leading-[1.7] text-[#ececef]">' + promptHtml + "</p>" : "") +
        '<div class="relative mt-[30px] w-full">' +
          '<div data-role="sr-slots" class="flex flex-wrap justify-center gap-[7px]">' + srSlotsHtml() + "</div>" +
          '<input data-role="sr" type="text" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" value="' + esc(st.typed) + '" class="absolute inset-0 h-full w-full cursor-text bg-transparent text-transparent caret-transparent opacity-0 outline-none" />' +
        "</div>" +
        result +
        (st.pending ? "" : '<div class="mt-[14px] flex flex-col items-center gap-[8px]"><button data-act="sr-hint" class="flex h-[46px] w-[46px] items-center justify-center rounded-full bg-[#2e2e33]/90 text-[#c9c9ce] active:scale-95">' + ico(I.bulb, "h-[20px] w-[20px]") + '</button><span class="text-[13px] text-[#7c7c82]">提示一下</span></div>') +
        '<p class="mt-[14px] text-[12.5px] text-[#5a5a60]">剩余机会 ' + left + " / " + SR_MAX_TRIES + "</p>" +
        '<div class="flex-1"></div>' +
      "</div>" +
      '<footer class="grid flex-none grid-cols-2 gap-[12px] px-4 pb-[30px] pt-[10px]">' + actions + "</footer></div>";
  }

  /* workflow.js 接管进度上报与落账；本层不再自报 */
  function reportProgress() {}

  /* ---- 卡片流转（纯渲染：作答即回 workflow）---- */
  function flip(r) {
    S.pendingRating = r || "good";
    S.face = "back"; S.tab = "colloc";
    speakWordThenSentence(S.card);
    paint();
  }
  function nextCard(miss) {
    var r = miss ? "again" : (S.pendingRating || "good");
    if (FC.answer) FC.answer(r, answerMeta());
  }

  /* ---- 事件总入口 ---- */
  /* ===================== 纯渲染层：由 workflow.js 驱动 =====================
     workflow 通过 web.mount 把 (cardId, mode) 推下来。本层只画，
     作答回 FC.answer(rating, meta)；不再自管队列 / 重考 / 拼写决策。
     mode 取值：read / choice / cloze / passage / passage_cloze */
  function answerMeta() {
    if (S.clozeBlanks && S.clozeBlanks.length) {
      try { return { passageTag: exportPassageTag() }; } catch (e) {}
    }
    return null;
  }
  function mountFromCard(c) {
    if (!c) return;
    var mode = (c.session && c.session.mode) || "read";
    /* 统一场景 API：壳在 session.scene 里说明「当前是什么状态」——
       learn=背新词 / review=复习 / retest=背完再背一遍 / preview=查卡片(只读)。
       模板据此决定正反面、自评按钮，以及要不要收起底部动作条。 */
    var scene = (c.session && c.session.scene) || "";
    S.mode = mode; S.scene = scene;
    S.browse = (scene === "preview");
    if (scene === "learn") S.screen = "learn";
    else if (scene) S.screen = "review";
    S.idx = (c.index != null) ? c.index : 0;
    S.retestTotal = (c.total != null) ? c.total : 0;
    S.card = c;
    if (!S.seenCards) S.seenCards = {};
    if (c.id) S.seenCards[c.id] = c;
    S.face = (S.browse && mode === "read") ? "back" : "front"; S.tab = "colloc"; S.hinted = false;
    S.revealed = false; S.picked = null; S.postChoice = false;
    S._spokenId = null; S._passageSpoken = false;
    if (mode === "read") {
      S.phase = "cards";
      hydrateKv([c]);
    } else if (mode === "choice") {
      S.rCur = c; S.phase = "choice"; buildChoice(c);
    } else if (mode === "cloze") {
      S.rCur = c; S.phase = "sentCloze"; initSentCloze(c);
    } else if (mode === "passage") {
      S.passage = c.passage || (c.session && c.session.passage) || FC._wfPassage || S.passage;
      S.phase = "passage";
    } else if (mode === "passage_cloze") {
      S.passage = c.passage || (c.session && c.session.passage) || FC._wfPassage || S.passage;
      S.phase = "cloze"; initCloze();
    } else {
      S.phase = "cards";
    }
    paint();
  }

  /* 例句填空（重考 cloze 模式）：例句挖空 + 选词填入 */
  function initSentCloze(c) {
    var f = c.fields || {};
    var se = String((f.sentence && f.sentence.en) || "").trim();
    var w = String(f.word || "").trim();
    var hit = null;
    if (w) {
      var re = new RegExp("\\b" + w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\w*", "i");
      hit = se.match(re);
    }
    S.sentCloze = {
      word: w, sentence: se, cn: spellCnOf(f), sentenceCn: String((f.sentence && f.sentence.cn) || "").trim(),
      blanked: hit ? se.slice(0, hit.index) + "______" + se.slice(hit.index + hit[0].length) : "",
      answer: hit ? hit[0] : w, revealed: false, picked: null, hint: false
    };
    var byId = {}, cands = [];
    function add(o) {
      if (!o || !o.id || o.id === c.id) return;
      if (!o.fields || !Object.keys(o.fields).length) return;
      if (byId[o.id]) return;
      byId[o.id] = 1; cands.push(o);
    }
    // 壳给的 choices（易混项 / 整本书池）优先
    arr(c.choices).forEach(add);
    Object.keys(S.seenCards || {}).forEach(function (k) { add(S.seenCards[k]); });
    var opts = shuffle(cands, ((String(c.id || "x")).charCodeAt(1) || 7) * 17).slice(0, 3);
    opts.push(c);
    S.sentCloze.opts = shuffle(opts, 99);
  }
  function ovSentCloze() {
    var sc = S.sentCloze; if (!sc) return "";
    var card = S.rCur || {};
    var opts = (sc.opts && sc.opts.length) ? sc.opts.slice() : [card];
    if (opts.indexOf(card) < 0) opts.push(card);
    var optsHtml = opts.map(function (o, i) {
      var of = (o && o.fields) || {};
      var isRight = !!(o && o.id === card.id);
      // 正确项用「例句里的实际词形」（如 condemned），干扰项用各自原形；不再拿变形词硬比
      var label = isRight ? (sc.answer || of.word || "") : String(of.word || "");
      var cls = "bg-[#222226]/90";
      if (sc.revealed) cls = isRight ? "bg-[#1d4239]" : (sc.picked === i ? "bg-[#4a1a24]" : "bg-[#222226]/90");
      var inner = '<span class="block text-[19px] font-semibold text-[#f0f0f2]">' + esc(label) + "</span>";
      if (sc.revealed) {
        // 揭示后所有选项都给中文释义，跟「看英文选中文」一致
        var s0 = (arr(of.senses)[0]) || { pos: "", cn: [] };
        inner += '<span class="mt-[3px] block text-[15.5px] leading-snug text-[#d5d5da]/85">' + esc(s0.pos || "") + " " + esc(arr(s0.cn).join("；")) + "</span>";
      }
      return '<button data-act="sc-pick" data-i="' + i + '" data-right="' + (isRight ? 1 : 0) + '" class="relative block w-full rounded-[16px] px-[18px] text-left transition-colors ' + cls + " " + (sc.revealed ? "py-[17px]" : "py-[21px]") + '">' + inner + "</button>";
    }).join("");
    return topBar(((S.idx || 0) + 1) + "/" + (S.retestTotal || 1), { canUndo: false, fav: !!S.favs[card.id], showKnown: false }) +
      '<div data-scroll="sentcloze" class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px]">' +
        '<div class="px-[26px] pt-1"><span class="text-[13px] text-[#8c8c92]">例句填空 · 选词填入</span>' +
        (sc.blanked
          ? '<p class="mt-[16px] text-[20px] font-bold leading-[1.7] text-[#f0f0f2]">' + esc(sc.blanked) + "</p>"
          : '<p class="mt-[16px] text-[17px] leading-[1.7] text-[#c5c5ca]">看中文选词：<b class="text-[#f0f0f2]">' + esc(sc.cn || "") + "</b></p>") +
        (sc.revealed ? '<p class="mt-[10px] text-[16px] leading-relaxed text-[#d5d5da]">' + esc(sc.sentenceCn || sc.cn || "") + "</p>" : "") +
        (sc.hint && !sc.revealed ? '<p class="mt-[10px] text-[15px] text-[#e3a83c]">提示：' + esc(sc.cn || "") + "</p>" : "") + "</div>" +
        '<div class="min-h-[40px] flex-1"></div><div class="space-y-[13px] px-4 pb-5 pt-8">' + optsHtml + "</div></div>" +
      (sc.revealed ? "" : '<div class="mb-[14px] flex flex-none flex-col items-center gap-[10px]"><button data-act="sc-hint" class="flex h-[52px] w-[52px] items-center justify-center rounded-full bg-[#2e2e33]/90 text-[#c9c9ce] active:scale-95">' + ico(I.bulb, "h-[22px] w-[22px]") + '</button><span class="text-[14px] text-[#7c7c82]">提示一下</span></div>') +
      '<footer class="flex flex-none justify-center pb-[34px] pt-[6px]">' + (sc.revealed ? dashBtn("继续", "bg-[#2ec4a5]", "sc-next") : dashBtn("看答案", "bg-[#e34d64]", "sc-reveal")) + "</footer>";
  }

  /* —— workflow.js 复用原语 —— */
  FC.helpers = { speak: speak, blankSentence: srBlankSentence, ttsWord: TTS_WORD, ttsSentence: TTS_SENTENCE };
  /* —— 拼写轮：workflow.js 决策，本层渲染 —— */
  FC.spell = {
    ask: function (n) { S.srAsk = n; S.sr = null; paint(); },
    start: function (items) { S.srAsk = 0; S.srItems = items; srBegin(); }
  };

  function handle(act, el, e) {
    var i, m;
    switch (act) {
      case "home": case "exit":
        // 语篇点返回 = 进入下一阶段；其余 = 退出本次会话
        if (S.phase === "passage") { if (FC.answer) FC.answer("good", answerMeta()); }
        else { try { FC.post("web.finish", {}); } catch (e) {} }
        break;
      case "rate-good": flip("good"); break;
      case "rate-hard": flip("hard"); break;
      case "rate-again": flip("again"); break;
      case "next": nextCard(false); break;
      case "next-miss": nextCard(true); break;
      case "hint": S.hinted = true; speakSentence(S.card); paint(); break;
      case "known":
        call("state.kvPut", { id: S.card.id, key: "known", value: true });
        S.learned[S.card.id] = true;
        if (FC.answer) FC.answer("good", answerMeta());
        break;
      case "undo":
        if (S.face === "back") { S.face = "front"; S.hinted = false; paint(); }
        break;
      case "fav":
        S.favs[S.card.id] = !S.favs[S.card.id];
        call("state.kvPut", { id: S.card.id, key: "fav", value: !!S.favs[S.card.id] });
        paint(); break;
      case "tab": S.tab = el.getAttribute("data-t"); paint(); break;
      case "meaning": openSV(parseInt(el.getAttribute("data-m"), 10) || 0); break;
      case "sentence-view": openSV(0); break;
      case "word": openDict(el.getAttribute("data-w"), el); break;
      case "exam": S.examOpen = true; paint(); break;
      case "exam-close": S.examOpen = false; paint(); break;
      case "note": S.noteDraft = S.notes[S.card.id] || ""; S.noteOpen = true; paint(); break;
      case "note-close": S.noteOpen = false; paint(); break;
      case "note-save":
        S.notes[S.card.id] = (S.noteDraft || "").trim();
        call("state.kvPut", { id: S.card.id, key: "note", value: S.notes[S.card.id] });
        S.noteOpen = false; if (S.notes[S.card.id] && S.face === "back") S.tab = "note";
        paint(); break;
      case "spell": S.spellInput = ""; S.spellState = "idle"; S.spellOpen = true; paint(); break;
      case "spell-back": S.spellOpen = false; paint(); break;
      case "spell-done": S.spellOpen = false; paint(); break;
      case "spell-check":
        if (S.spellState === "right") break;
        if (String(S.spellInput).trim().toLowerCase() === String((S.card.fields || {}).word || "").toLowerCase()) { S.spellState = "right"; speak((S.card.fields || {}).word); }
        else S.spellState = "wrong";
        paint(); break;
      case "sr-go": if (FC.onSpellDecision) FC.onSpellDecision(true); else srBegin(); break;
      case "sr-no": if (FC.onSpellDecision) FC.onSpellDecision(false); else { S.srAsk = 0; paint(); } break;
      case "sr-quit": srEnd(); break;
      case "sr-skip": srAction("skip"); break;
      case "sr-forget": srAction("forget"); break;
      case "sr-hint": srAction("hint"); break;
      case "sr-next": srAction("next"); break;
      case "menu": S.menuOpen = true; paint(); break;
      case "menu-close": S.menuOpen = false; paint(); break;
      case "menu-settings": S.menuOpen = false; S.settingsOpen = true; paint(); break;
      case "menu-noop": S.menuOpen = false; paint(); break;
      case "settings-close": S.settingsOpen = false; paint(); break;
      case "dict-save": pluginCall("youdao", "setConfig", { appKey: S.dictKey || "", appSecret: S.dictSecret || "" }).then(function () { loadDictCfg(); _dictCache = {}; paint(); }); break;
      case "pref-toggle": var k = el.getAttribute("data-k"); S.prefs[k] = !S.prefs[k]; if (k === "topbar") call("ui.setChrome", { top: !!S.prefs[k] }); paint(); break;
      case "order-open": S.settingsOpen = false; S.orderOpen = true; paint(); break;
      case "order-close": S.orderOpen = false; paint(); break;
      case "order-up": i = parseInt(el.getAttribute("data-i"), 10); if (i > 0) { var a = S.tabOrder; var t = a[i]; a[i] = a[i - 1]; a[i - 1] = t; paint(); } break;
      case "order-down": i = parseInt(el.getAttribute("data-i"), 10); if (i < S.tabOrder.length - 1) { var b = S.tabOrder; var u = b[i]; b[i] = b[i + 1]; b[i + 1] = u; paint(); } break;
      case "dict-close": S.dictWord = null; S.dictExpanded = false; paint(); break;
      case "dict-expand": S.dictExpanded = true; paint(); break;
      case "dict-fav": var w = (S.dictEntry && S.dictEntry.word) || S.dictWord; S.dictFavs[w] = !S.dictFavs[w]; paint(); break;
      case "tts-word": if (S.card) speak(String((S.card.fields || {}).word || "").trim(), TTS_WORD); break;
      case "dict-speak": if (S.dictEntry) speak(S.dictEntry.word); break;
      case "sv-close": S.sentView = null; paint(); break;
      case "sv-next": S.sentView = null; paint(); break;
      case "sv-reveal": if (S.sentView) { S.sentView.revealed = true; paint(); } break;
      case "sv-m": if (S.sentView) { S.sentView.m = parseInt(el.getAttribute("data-m"), 10) || 0; S.sentView.ex = 0; S.sentView.revealed = false; paint(); } break;
      case "sv-star": if (S.sentView) { S.sentView.star = !S.sentView.star; paint(); } break;
      case "sv-speak": var d = S.sentView && arr((S.sentView.card.fields || {}).meaningDetails)[S.sentView.m]; var ex0 = d && arr(d.examples)[S.sentView.ex]; if (ex0) speak(ex0.en, TTS_PASSAGE); break;
      case "passage-speak": if (S.passage) speak(S.passage.plain || ""); break;
      case "cloze-start":
        if (S.clozeBlanks && S.clozeBlanks.length) { S.phase = "cloze"; paint(); }
        else if (FC.answer) FC.answer("good", answerMeta());
        break;
      case "cloze-back": S.phase = "passage"; paint(); break;
      case "cloze-chip": tapChip(el.getAttribute("data-w")); break;
      case "cloze-blank": var bi2 = parseInt(el.getAttribute("data-i"), 10); if (S.clozeFilled[bi2] === null) { S.clozeActive = bi2; paint(); } break;
      case "cards-start": if (FC.answer) FC.answer("good", answerMeta()); break;
      case "choice-pick":
        if (S.revealed) break;
        i = parseInt(el.getAttribute("data-i"), 10);
        S.picked = i; S.revealed = true;
        if (!S.choiceOpts[i] || S.choiceOpts[i].id !== S.rCur.id) S.wrongs++;
        speak((S.rCur.fields || {}).word); paint(); break;
      case "choice-reveal": S.revealed = true; S.wrongs++; speak((S.rCur.fields || {}).word); paint(); break;
      case "choice-next":
        { var okCh = (S.picked != null && S.choiceOpts[S.picked] && S.choiceOpts[S.picked].id === S.rCur.id);
          S.revealed = false; S.picked = null;
          S.card = S.rCur; S.postChoice = true;
          S.pendingRating = okCh ? "good" : "again";
          S.face = "back"; S.tab = "colloc"; S.phase = "cards";
          paint(); }
        break;
      case "sc-pick":
        if (S.sentCloze && !S.sentCloze.revealed) {
          S.sentCloze.picked = parseInt(el.getAttribute("data-i"), 10);
          S.sentCloze._right = (el.getAttribute("data-right") === "1");
          S.sentCloze.revealed = true; paint();
        }
        break;
      case "sc-reveal":
        if (S.sentCloze) { S.sentCloze.revealed = true; S.sentCloze._right = false; paint(); }
        break;
      case "sc-hint":
        if (S.sentCloze) { S.sentCloze.hint = true; paint(); }
        break;
      case "sc-forget":
        if (S.sentCloze) {
          if (!S.sentCloze.revealed) { S.sentCloze.revealed = true; S.sentCloze._right = false; paint(); }
          else { S.sentCloze = null; if (FC.answer) FC.answer("again", answerMeta()); }
        }
        break;
      case "sc-skip":
        if (S.sentCloze) {
          if (!S.sentCloze.revealed) { S.sentCloze.revealed = true; S.sentCloze._right = false; paint(); }
          else { S.sentCloze = null; if (FC.answer) FC.answer("good", answerMeta()); }
        }
        break;
      case "sc-next":
        { var okSc = !!(S.sentCloze && S.sentCloze._right === true);
          S.sentCloze = null;
          if (FC.answer) FC.answer(okSc ? "good" : "again", answerMeta()); }
        break;
    }
  }

  function initCloze() {
    var segs = arr((S.passage || {}).segments);
    S.clozeBlanks = segs.filter(function (x) { return x.w && x.blank !== false; }).map(function (x) { return { w: x.w, lemma: x.lemma || x.w, pos: x.pos || "", plain: x.plain || "", meaning: x.meaning || "" }; });
    S.clozeTargets = S.clozeBlanks.map(function (x) { return x.w; });
    S.clozeBank = shuffle(S.clozeTargets, 42);
    S.clozeFilled = S.clozeTargets.map(function () { return null; });
    S.clozeErr = null; S.clozeWrongs = 0;
    S.clozeActive = 0;
    S.clozeWrong = S.clozeTargets.map(function () { return 0; });
    S.clozeFailed = S.clozeTargets.map(function () { return false; });
  }

  /* 导出语篇每个目标词的检验状态：failed / tested / untested
     key = lemma 小写，跟壳里 plan 的 card.word 归一化后一一对应 */
  function exportPassageTag() {
    var tag = {};
    arr(S.clozeBlanks).forEach(function (b, i) {
      var k = String(b.lemma || b.w || "").trim().toLowerCase();
      if (!k) return;
      tag[k] = (S.clozeFailed || [])[i] ? "failed" : (S.clozeFilled[i] !== null ? "tested" : "untested");
    });
    return tag;
  }

  /* 选词填一个空。支持跳着填：先点空选中（S.clozeActive），再点词；
     没选中时退回「第一个未填空」——两种习惯都照顾。同一个空错满 3 次标 failed。 */
  function tapChip(w) {
    var filled = S.clozeFilled;
    if (filled.indexOf(w) >= 0) return;
    var idx = S.clozeActive;
    if (idx == null || idx < 0 || filled[idx] !== null) idx = filled.indexOf(null);
    if (idx === -1) return;
    if (String(S.clozeTargets[idx]).toLowerCase() === String(w).toLowerCase()) {
      filled[idx] = w;
      speak(w, TTS_WORD);
      S.clozeActive = filled.indexOf(null);
    } else {
      S.clozeErr = w; S.clozeWrongs++;
      S.clozeWrong[idx] = (S.clozeWrong[idx] || 0) + 1;
      if (S.clozeWrong[idx] >= 3) S.clozeFailed[idx] = true;
      setTimeout(function () { S.clozeErr = null; paint(); }, 550);
    }
    paint();
  }
  function buildChoice(c) {
    var cur = c || S.rCur;
    var byId = {}, cands = [];
    function add(o) {
      if (!o || !o.id || o.id === cur.id) return;
      if (!o.fields || !Object.keys(o.fields).length) return;   // 必须有字段，否则中文释义是空的
      if (byId[o.id]) return;
      byId[o.id] = 1; cands.push(o);
    }
    // 壳给的 choices 是「卡上易混项 / 整本书池」里挑好的干扰项，优先用
    arr(cur && cur.choices).forEach(add);
    // 不够再用本会话学过的卡补足（learn 阶段 mount 过，带 fields）
    Object.keys(S.seenCards || {}).forEach(function (k) { add(S.seenCards[k]); });
    var opts = shuffle(cands, ((String((cur && cur.id) || "x")).charCodeAt(1) || 7) * 17).slice(0, 3);
    opts.push(cur);
    S.choiceOpts = shuffle(opts, 99);
    if (S.choiceOpts.indexOf(cur) < 0) S.choiceOpts[0] = cur;
  }

  var _swipeAt = 0, _tch = null;
  root.addEventListener("click", function (e) {
    if (Date.now() - _swipeAt < 400) return;
    var hit = closestAct(e.target);
    if (!hit) return;
    if (hit.word) { openDict(hit.word, hit.el); return; }
    handle(hit.act, hit.el, e);
  });
  /* 例句轮播卡：左右滑动切换例句 */
  root.addEventListener("touchstart", function (e) {
    if (!S.sentView || !e.touches || e.touches.length !== 1) { _tch = null; return; }
    _tch = { x: e.touches[0].clientX, y: e.touches[0].clientY, t: Date.now() };
  }, { passive: true });
  root.addEventListener("touchend", function (e) {
    if (!_tch || !S.sentView) { _tch = null; return; }
    var t = e.changedTouches && e.changedTouches[0];
    var st = _tch; _tch = null;
    if (!t) return;
    var dx = t.clientX - st.x, dy = t.clientY - st.y;
    if (Date.now() - st.t > 700) return;
    if (Math.abs(dx) < 45 || Math.abs(dx) < Math.abs(dy) * 1.4) return;
    var v = S.sentView; if (!v) return;
    var d = arr((v.card.fields || {}).meaningDetails)[v.m || 0];
    var list = arr(d && d.examples), n = list.length;
    if (n <= 1) return;
    var nx = (v.ex || 0) + (dx < 0 ? 1 : -1);
    if (nx < 0) nx = n - 1;
    if (nx >= n) nx = 0;
    v.ex = nx; v.revealed = false;
    if (list[nx]) speak(list[nx].en, TTS_PASSAGE);
    _swipeAt = Date.now();
    paint();
  }, { passive: true });
  root.addEventListener("input", function (e) {
    var t = e.target;
    if (!t || !t.getAttribute) return;
    var role = t.getAttribute("data-role");
    if (role === "note") {
      S.noteDraft = t.value.slice(0, 1000);
      var cnt = root.querySelector('[data-role="note-count"]');
      if (cnt) cnt.textContent = S.noteDraft.length + "/1000";
    } else if (role === "spell") {
      S.spellInput = t.value;
      if (S.spellState === "wrong") { S.spellState = "idle"; }
    } else if (role === "sr") {
      srOnInput(t.value);
    } else if (role === "dict-key") {
      S.dictKey = t.value;
    } else if (role === "dict-secret") {
      S.dictSecret = t.value;
    }
  });
  root.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && e.target && e.target.getAttribute) {
      var r0 = e.target.getAttribute("data-role");
      if (r0 === "spell") handle("spell-check", e.target, e);
      else if (r0 === "sr" && S.sr && !S.sr.revealed && !S.sr.pending) srCheck();
    }
  });

  /* ---- 壳回调 ---- */
  if (FC.onMount) FC.onMount(function () {
    mountFromCard(FC.getCard());
  });

  /* ---- 启动 ----
     web_session 模式：壳只给「本轮计划」(session.plan)，**不推卡**。
     模板必须自己去拉队列 —— 否则停在主页 Learn 0 / Review 0，
     看起来就是一片空白（这就是之前「打开全是空的」的真因）。
     mountCard 模式：壳会把卡推进来（走 onMount），这时不用自驱。
     两条路用 started 去重，防止 web.start 和 boot 各启一次。 */
  var started = false;
  function autoStart() {
    if (started) return;
    started = true;
    /* 先看有没有上次没背完的断点；有就原地续上，没有才开新会话。 */
    var savedP = null;
    try { savedP = call("session.load", {}); } catch (e) { savedP = null; }
    Promise.all([
      call("session.plan", {}),
      savedP ? savedP.catch(function () { return null; }) : Promise.resolve(null)
    ]).then(function (rs) {
      var plan = rs[0], saved = rs[1];
      var pk = planKey(plan);
      if (saved && saved.workflow === WF_NAME && saved.session && pk &&
          saved.session.phase && saved.session.phase !== "done" &&
          saved.session.planKey === pk) {
        log("autoStart: 断点命中 phase=" + saved.session.phase + " idx=" + saved.session.idx);
        if (restoreSession(saved.session, plan)) return;
      } else if (saved && saved.session && saved.session.planKey !== pk) {
        log("autoStart: 计划变了(旧=" + String(saved.session.planKey).slice(0, 30) + " 新=" + pk.slice(0, 30) + ")，丢弃旧断点");
        clearSession();
      }
      var units = arr(plan && plan.units);
      /* 模式由壳直给（plan.mode）。老壳没这字段时退回本地聚合兜底。 */
      var mode = plan && plan.mode;
      if (mode !== "review" && mode !== "learn") {
        var anyReview = units.some(function (u) { return u && u.isReview; });
        var anyNew = units.some(function (u) { return u && !u.isReview; });
        mode = (anyReview && !anyNew) ? "review" : "learn";
      }
      log("autoStart mode=" + mode + " units=" + units.length);
      startSession(mode);
    }).catch(function (e) {
      log("autoStart ERR " + (e && e.message ? e.message : e));
      startSession("learn");
    });
  }
  (function boot() {
    var c0 = FC.getCard();
    log("boot cardId=[" + ((c0 && c0.id) || "") + "]");
    /* 顶部栏偏好：问壳要盘上值，回填设置开关状态 */
    loadDictCfg();
    call("ui.getChrome", {}).then(function (r) {
      if (r && r.top != null) { S.prefs.topbar = !!r.top; paint(); }
    }).catch(function () {});
    if (c0 && c0.id) { mountFromCard(c0); }
    else { paint(); }
    try { if (FC.ready) FC.ready(); } catch (e) {}
  })();
})();
