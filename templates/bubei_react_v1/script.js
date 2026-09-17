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
  function call(m, p) { try { return FC.call ? FC.call(m, p) : Promise.resolve({}); } catch (e) { return Promise.resolve({}); } }
  function log(m) { try { if (FC.log) FC.log("[v1]", m); } catch (e) {} }
  function orangeWord(text, word) { if (!word) return esc(text); var re = new RegExp("(" + word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\w*)", "ig"); return String(text || "").split(re).map(function (seg) { if (!seg) return ""; return seg.toLowerCase().indexOf(word.toLowerCase()) === 0 ? '<b class="font-bold text-[#f0a824]">' + esc(seg) + "</b>" : esc(seg); }).join(""); }
  function clickable(text, boldWord, selected, cls) { var toks = String(text || "").split(/([A-Za-z][A-Za-z'-]*)/g); return '<p class="' + (cls || "") + '">' + toks.map(function (tk) { if (!/^[A-Za-z]/.test(tk)) return esc(tk); var isBold = boldWord && tk.toLowerCase().indexOf(boldWord.toLowerCase()) === 0; var isSel = selected && tk.toLowerCase() === selected.toLowerCase(); return '<span data-word="' + esc(tk) + '" class="cursor-pointer rounded-[4px] transition-colors ' + (isSel ? "bg-[#4a5578]/80 px-[2px] -mx-[2px] " : "active:bg-white/15 ") + (isBold ? "font-bold text-white" : "") + '">' + esc(tk) + "</span>"; }).join("") + "</p>"; }

  var S = {
    screen: "home", phase: "cards", face: "front", tab: "colloc",
    tabOrder: ["colloc", "deriv", "syn", "root"],
    card: null, queue: [], idx: 0, hinted: false,
    prefs: { passage: true, cloze: true, confusion: true, syllable: true, clozeEx: false, topbar: true },
    favs: {}, notes: {}, learned: {}, due: [],
    missed: [], history: [],
    dictWord: null, dictExpanded: false, dictFavs: {},
    examOpen: false, noteOpen: false, noteDraft: "", spellOpen: false,
    spellInput: "", spellState: "idle",
    menuOpen: false, settingsOpen: false, orderOpen: false,
    sentView: null, rIdx: 0, revealed: false, picked: null, wrongs: 0,
    passageStep: "read", clozeFilled: [], clozeErr: null
  };
  var TABS = { colloc: "词组搭配", deriv: "派生", syn: "近义", root: "词根", note: "笔记" };
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
        return '<p class="mb-[15px] flex items-baseline text-[16px] leading-snug"><span ' + (bound ? 'data-act="meaning" data-m="' + mIdx + '"' : "") + ' class="' + (bound ? "cursor-pointer pb-[4px] text-[#ececef] underline decoration-dashed decoration-[#5a5a60] decoration-[1.5px] underline-offset-[6px] " : "text-[#ececef]") + '">' + esc(c.en) + '</span><span class="ml-[13px] text-[#d5d5da]">' + esc(c.cn) + '</span><span class="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">' + esc(c.tag || (ci % 2 ? "核心高频" : "考研")) + "</span></p>";
      }).join("") + '<button data-act="exam" class="mt-[10px] text-[14px] text-[#a8a8ae]">学习所有考研真题词组 <span class="text-[#7c7c82]">›</span></button>';
    } else if (tab === "deriv") {
      body = arr(f.derivatives).map(function (d) {
        return '<p class="mb-[15px] flex items-baseline text-[16px]">' + (d.word === f.word ? '<span class="mr-[8px] text-[10px] text-[#e3a83c]">▶</span>' : "") + '<span data-act="word" data-w="' + esc(d.word) + '" class="cursor-pointer text-[#ececef] underline decoration-dotted decoration-white/20 decoration-[1.5px] underline-offset-4">' + esc(d.word) + '</span><span class="ml-[13px] text-[14px] text-[#a8a8ae]">' + esc(d.pos || "") + '</span><span class="ml-[8px] truncate text-[#d5d5da]">' + esc(d.cn || "") + '</span><span class="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">考研</span></p>';
      }).join("") + '<button class="mt-[6px] text-[14px] text-[#a8a8ae]">查看全部派生词 <span class="text-[#7c7c82]">›</span></button>';
    } else if (tab === "syn") {
      var syn = arr(f.synonyms), ant = arr(f.antonyms); body = '<div class="space-y-[15px]">';
      if (syn.length) body += '<p class="flex flex-wrap items-baseline gap-x-[6px] text-[16px] leading-relaxed"><span class="mr-[4px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">近义</span>' + syn.map(function (s, i) { return '<span data-act="word" data-w="' + esc(s) + '" class="cursor-pointer text-[#d5d5da] underline decoration-dotted decoration-white/20 decoration-[1.5px] underline-offset-4">' + esc(s) + (i < syn.length - 1 ? "," : "") + "</span>"; }).join("") + '<span class="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">核心高频</span></p>';
      if (ant.length) body += '<p class="flex flex-wrap items-baseline gap-x-[6px] text-[16px] leading-relaxed"><span class="mr-[4px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">反义</span>' + ant.map(function (s, i) { return '<span data-act="word" data-w="' + esc(s) + '" class="cursor-pointer text-[#d5d5da] underline decoration-dotted decoration-white/20 decoration-[1.5px] underline-offset-4">' + esc(s) + (i < ant.length - 1 ? "," : "") + "</span>"; }).join("") + '<span class="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">易混辨析</span></p>';
      body += "</div>";
    } else if (tab === "root") {
      body = arr(f.root).map(function (r) { return '<p class="mb-[14px] text-[16px]"><span class="mr-[12px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">' + esc(r.tag || "") + '</span><span class="text-[#ececef]">' + esc(r.text || "") + "</span></p>"; }).join("") + (f.rootSummary ? '<p class="mt-[4px] text-[16px] leading-[1.7] text-[#ececef]">' + esc(f.rootSummary) + "</p>" : "") + '<button class="mt-[16px] text-[14px] text-[#a8a8ae]">查看更多同根词 <span class="text-[#7c7c82]">›</span></button>';
    } else if (tab === "note") {
      body = '<p class="text-[16px] leading-relaxed text-[#ececef]">' + esc(S.notes[card.id] || "暂无笔记") + '</p><button data-act="note" class="mt-[16px] flex items-center gap-[6px] text-[14px] text-[#a8a8ae]">编辑笔记' + ico(I.noteadd, "h-[13px] w-[13px]") + "</button>";
    }
    return '<div class="relative mx-4 mt-[22px] rounded-[16px] bg-[#222226]/90 px-[18px] pb-[46px] pt-[17px]">' + clickable((f.sentence || {}).en, f.word, S.dictWord, "text-[17px] leading-[1.55] text-[#ececef]") + '<p class="mt-[6px] text-[15px] leading-relaxed text-[#c5c5ca]">' + esc((f.sentence || {}).cn) + '</p><button data-act="sentence-view" class="absolute bottom-[13px] right-[13px] flex h-[34px] w-[34px] items-center justify-center rounded-full bg-[#2e2e33] text-[#b9b9bf]">' + ico(I.sentswitch, "h-[17px] w-[17px]") + "</button></div>" +
      '<div class="mx-4 mb-4 mt-[13px] flex min-h-[280px] flex-1 flex-col rounded-[16px] bg-[#222226]/90 px-[18px] pt-[19px]"><div class="flex-1">' + body + '</div><div class="flex flex-none items-center gap-[6px] pb-[15px] pt-3">' + tabHtml + '<span class="flex-1"></span>' + (!S.notes[card.id] ? '<button data-act="note" class="mr-[4px] text-[#a8a8ae]">' + ico(I.noteadd, "h-[18px] w-[18px]") + "</button>" : "") + '<button data-act="exam" class="flex h-[32px] w-[32px] items-center justify-center rounded-full bg-[#2e2e33] text-[#b9b9bf]">' + ico(I.textsearch, "h-[16px] w-[16px]") + "</button></div></div>";
  }
  function home() {
    var learnN = 0, reviewN = S.due.length;
    return '<div class="relative flex h-full flex-col overflow-hidden"><div class="absolute inset-0" style="background:' + LEARN_BG + '"></div><div class="relative flex h-full flex-col">' +
      '<div class="px-5 pt-5"><button class="relative block"><span class="flex h-[46px] w-[46px] items-center justify-center rounded-full border-2 border-black/60 bg-[#f7c948] text-[24px] shadow-lg">🐶</span><span class="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-[#e34d64] px-1 text-[11px] font-bold text-white">1</span></button></div>' +
      '<h1 class="mt-[15%] text-center text-[44px] font-bold tracking-wide text-[#f0f0f2]">Fairytale</h1><div class="flex-1"></div>' +
      '<div class="grid grid-cols-2 gap-[13px] px-4">' + [["Learn", learnN, "learn"], ["Review", reviewN, "review"]].map(function (c) { return '<button data-act="start-' + c[2] + '" class="rounded-[16px] bg-[#1c1c20]/75 px-[20px] py-[16px] text-left backdrop-blur-md"><span class="block text-[22px] font-bold text-[#ececef]">' + c[0] + '</span><span class="mt-[2px] block text-[17px] font-semibold text-[#e3a83c]">' + c[1] + "</span></button>"; }).join("") + "</div>" +
      '<nav class="flex items-center justify-between px-[38px] pb-[26px] pt-[22px]"></nav></div></div>';
  }
  function sentenceText(card) { var en = String((card.fields.sentence || {}).en || ""); if (S.prefs.clozeEx) { var w = String(card.fields.word || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); en = en.replace(new RegExp(w + "\\w*", "i"), "______"); } return en; }
  function doneView() {
    var q = S.queue, missed = S.missed;
    return '<div class="flex flex-1 flex-col items-center justify-center px-9 pb-12"><svg viewBox="0 0 24 24" class="h-[52px] w-[52px]"><path fill="#1db373" d="M12 1.6l2.1 1.8 2.7-.5 1 2.6 2.6 1-.5 2.7 1.8 2.1-1.8 2.1.5 2.7-2.6 1-1 2.6-2.7-.5-2.1 1.8-2.1-1.8-2.7.5-1-2.6-2.6-1 .5-2.7L1.6 12l1.8-2.1-.5-2.7 2.6-1 1-2.6 2.7.5L12 1.6z"/><path d="M8.4 12.2l2.3 2.3 4.6-4.7" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
      '<h2 class="mt-5 text-[22px] font-bold text-[#f5f5f7]">' + (S.screen === "learn" ? "本组学习完成" : "本轮复习完成") + '</h2><p class="mt-2 text-[13.5px] text-[#7c7c82]">' + q.length + " 词 · 需复习 " + missed.length + " · 出错 " + S.wrongs + "</p>" +
      '<div class="mt-9 w-full space-y-[13px]">' + q.map(function (c) { var bad = missed.indexOf(c.id) >= 0; return '<div class="flex items-center justify-between rounded-[14px] bg-[#222226]/90 px-[18px] py-[13px]"><div class="flex items-center gap-3"><span class="h-[7px] w-[7px] rounded-full ' + (bad ? "bg-[#e34d64]" : "bg-[#2ec4a5]") + '"></span><span class="text-[16px] font-semibold text-[#ececef]">' + esc(c.fields.word) + '</span></div><span class="max-w-[45%] truncate text-[13px] text-[#8c8c92]">' + esc(arr((c.fields.senses || [])[0] && c.fields.senses[0].cn)[0] || "") + "</span></div>"; }).join("") + "</div>" +
      '<button data-act="home" class="mt-10 flex flex-col items-center gap-[9px]"><span class="text-[18px] font-semibold text-[#ececef]">返回主页</span><span class="h-[4px] w-[22px] rounded-full bg-[#2ec4a5]"></span></button></div>';
  }
  function overlays() { return ""; }

  function paint() {
    if (S.screen === "home") { root.innerHTML = home(); return; }
    var card = S.card;
    if (!card) { root.innerHTML = '<div class="flex h-full items-center justify-center p-8 text-center text-[15px] text-[#8a8a90]">' + (S.phase === "done" ? "没有可学的卡（已学完 / 已标熟）" : "加载中…") + "</div>"; return; }
    var bg = S.screen === "learn" ? LEARN_BG : BG;
    var counter = Math.min(S.idx, S.queue.length) + "/" + S.queue.length;
    var h = '<div class="relative flex h-full flex-col overflow-hidden text-[#f0f0f2]" style="background:' + bg + '">';
    if (S.phase === "cards") h += topBar(counter, { canUndo: S.face === "back" && S.history.length > 0, fav: !!S.favs[card.id], showKnown: S.face === "front" });
    if (S.phase === "cards" && S.face === "front") {
      if (S.screen === "learn") {
        h += '<div class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px]">' + hero(card) + '<div class="mt-[26px] space-y-[13px] px-[34px]"><div class="h-[26px] w-[168px] rounded-full bg-[#222226]"></div><div class="h-[26px] w-[100px] rounded-full bg-[#222226]"></div></div><div class="mx-4 mt-[56px] rounded-[16px] bg-[#28282c]/80 px-[18px] py-[19px]">' + clickable(sentenceText(card), card.fields.word, S.dictWord, "text-[17px] leading-[1.6] text-[#ececef]") + (S.hinted ? '<p class="mt-[8px] text-[15px] leading-relaxed text-[#c5c5ca]">' + esc((card.fields.sentence || {}).cn) + "</p>" : "") + "</div></div>";
        if (!S.hinted) h += '<div class="mb-[26px] flex flex-none flex-col items-center gap-[10px]"><button data-act="hint" class="flex h-[52px] w-[52px] items-center justify-center rounded-full bg-[#2e2e33]/90 text-[#c9c9ce]">' + ico(I.bulb, "h-[22px] w-[22px]") + '</button><span class="text-[14px] text-[#7c7c82]">提示一下</span></div>';
        h += '<footer class="grid flex-none grid-cols-2 pb-[34px]">' + dashBtn("认识", "bg-[#2ec4a5]", "flip-ok") + dashBtn("不认识", "bg-[#e34d64]", "flip-miss") + "</footer>";
      } else {
        h += '<div class="mt-[52px] flex-1">' + hero(card) + '<div class="mt-[26px] space-y-[13px] px-[34px]"><div class="h-[26px] w-[168px] rounded-full bg-[#222226]"></div><div class="h-[26px] w-[100px] rounded-full bg-[#222226]"></div></div></div><p class="mb-[30px] text-center text-[14px] leading-[1.9] text-[#7c7c82]">瞬间想起词义，选「认识」<br>思考后想起词义，选「模糊」</p><footer class="grid flex-none grid-cols-3 pb-[34px]">' + dashBtn("认识", "bg-[#2ec4a5]", "flip-ok") + dashBtn("模糊", "bg-[#e3a83c]", "flip-miss") + dashBtn("忘记了", "bg-[#e34d64]", "flip-miss") + "</footer>";
      }
    } else if (S.phase === "cards" && S.face === "back") {
      h += '<div class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[46px]">' + hero(card, { syllable: S.prefs.syllable }) + senseLine(card) + detailBody(card, S.tab) + '</div><footer class="grid flex-none grid-cols-2 pb-[34px] pt-[6px]">' + dashBtn("下一词", "bg-[#2ec4a5]", "next") + dashBtn("记错了", "bg-[#e34d64]", "next-miss") + "</footer>";
    } else if (S.phase === "done") { h += doneView(); }
    h += overlays() + "</div>";
    root.innerHTML = h;
  }

  window.__FCV1 = { S: S, paint: paint, esc: esc, arr: arr, speak: speak, call: call, ico: ico, I: I, orangeWord: orangeWord, clickable: clickable, topBar: topBar, hero: hero, dashBtn: dashBtn, BG: BG, LEARN_BG: LEARN_BG, shuffle: shuffle };
  /* ===================== PART2-A：浮层渲染 ===================== */
  function ovPassage() {
    var p = S.passage || {}; var parts = arr(p.parts);
    var body = parts.map(function (x) {
      if (x.word) return '<span data-act="word" data-w="' + esc(x.word) + '" class="mx-[2px] cursor-pointer pb-[3px] font-bold text-[#f0a824] underline decoration-dashed decoration-[#f0a824]/50 decoration-[1.5px] underline-offset-[6px]">' + esc(x.word) + "</span>";
      return clickable(x.t || "", null, S.dictWord, "inline");
    }).join("");
    return '<header class="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2"><button data-act="home" class="flex items-center gap-2 text-[#c9c9ce]">' + ico(I.chevron, "h-[22px] w-[22px]") + '<span class="text-[15px] font-medium text-[#b9b9bf]">语篇通读</span></button>' +
      '<button data-act="passage-speak" class="flex h-[34px] w-[34px] items-center justify-center rounded-full bg-[#29292e] text-[#b9b9bf]">' + ico(I.speaker, "h-[16px] w-[16px]") + "</button></header>" +
      '<div class="min-h-0 flex-1 overflow-y-auto px-[26px] pb-4"><div class="mt-[10px] flex items-baseline gap-3"><h1 class="text-[26px] font-extrabold text-[#f5f5f7]">' + esc(p.title || "") + '</h1><span class="rounded-[5px] bg-[#29292e] px-[8px] py-[3px] text-[12px] text-[#a8a8ae]">' + esc(p.tag || "") + '</span></div>' +
      '<p class="mt-[20px] text-[18px] leading-[1.85] text-[#d5d5da]">' + body + "</p>" +
      '<p class="mt-[22px] border-t border-white/[0.07] pt-[18px] text-[15px] leading-[1.9] text-[#8c8c92]">' + esc(p.cn || "") + "</p></div>" +
      '<footer class="grid flex-none ' + (S.prefs.cloze ? "grid-cols-2" : "grid-cols-1") + ' pb-[30px] pt-[10px]">' +
      (S.prefs.cloze ? dashBtn("语篇填空", "bg-[#e3a83c]", "cloze-start") : "") + dashBtn("进入单词背诵", "bg-[#2ec4a5]", "cards-start") + "</footer>";
  }

  function ovCloze() {
    var p = S.passage || {}; var parts = arr(p.parts); var bank = S.clozeBank || []; var filled = S.clozeFilled || [];
    var bi = -1; var nextBlank = filled.indexOf(null);
    var body = parts.map(function (x) {
      if (!x.word) return esc(x.t || "");
      bi += 1; var idx = bi; var val = filled[idx];
      var isActive = idx === nextBlank;
      return '<span class="mx-[3px] inline-block min-w-[92px] border-b-2 pb-[1px] text-center font-bold ' + (val ? "border-[#2ec4a5]/60 text-[#2ec4a5]" : isActive ? "border-[#e3a83c] text-transparent" : "border-[#4a4a4f] text-transparent") + '">' + esc(val || "____") + "</span>";
    }).join("");
    var used = filled.filter(Boolean);
    var done = nextBlank === -1;
    var chips = bank.map(function (w) {
      var u = used.indexOf(w) >= 0; var err = S.clozeErr === w;
      return '<button data-act="cloze-chip" data-w="' + esc(w) + '" ' + (u ? "disabled" : "") + ' class="rounded-[12px] px-[16px] py-[9px] text-[16px] font-semibold ' + (u ? "bg-[#1c1c20] text-[#4a4a4f]" : err ? "animate-pulse bg-[#4a1a24] text-[#ff8a8a]" : "bg-[#26262b] text-[#ececef]") + '">' + esc(w) + "</button>";
    }).join("");
    return '<header class="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2"><button data-act="cloze-back" class="flex items-center gap-2 text-[#c9c9ce]">' + ico(I.chevron, "h-[22px] w-[22px]") + '<span class="text-[15px] font-medium text-[#b9b9bf]">语篇填空</span></button></header>' +
      '<div class="min-h-0 flex-1 overflow-y-auto px-[26px] pb-4"><div class="mt-[10px] flex items-baseline justify-between"><h1 class="text-[26px] font-extrabold text-[#f5f5f7]">' + esc(p.title || "") + '</h1><span class="text-[13px] tabular-nums text-[#8c8c92]">' + used.length + "/" + (S.clozeTargets || []).length + "</span></div>" +
      '<p class="mt-[20px] text-[18px] leading-[2.05] text-[#d5d5da]">' + body + "</p>" +
      (done ? '<div class="mt-[26px] rounded-[14px] bg-[#1d4239]/60 px-[18px] py-[14px]"><p class="text-[15px] font-semibold text-[#3fe0b4]">✓ 全部填对！</p><p class="mt-[4px] text-[13px] text-[#8fccc4]">出错 ' + (S.clozeWrongs || 0) + " 次 · 建议现在进入单词背诵巩固</p></div>" : '<p class="mt-[20px] text-center text-[12.5px] text-[#5a5a60]">按顺序为琥珀色空格选择正确的单词</p>') +
      '<div class="mt-[18px] flex flex-wrap justify-center gap-[10px] pb-2">' + chips + "</div></div>" +
      '<footer class="grid flex-none grid-cols-2 pb-[30px] pt-[10px]">' + dashBtn("返回语篇", "bg-[#5a5a60]", "cloze-back", true) + dashBtn(done ? "进入单词背诵" : "跳过填空", "bg-[#2ec4a5]", "cards-start") + "</footer>";
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
      '<div class="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px]">' + hero(card) + '<div class="min-h-[60px] flex-1"></div><div class="space-y-[13px] px-4 pb-5 pt-8">' + optsHtml + "</div></div>" +
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
        '<div class="relative h-[212px] flex-none border-t border-white/[0.05] bg-[#232a48]"><div class="h-full overflow-y-auto px-[20px] pb-[40px] pt-[18px] ' + (v.revealed ? "" : "blur-[10px] opacity-50") + '">' +
          '<p class="text-[17px] leading-[1.6] text-[#ececef]"><b class="mr-2 font-bold">' + esc(pos) + "</b>" + esc(detail.enDef || detail.meaning || "") + "</p>" +
          (detail.pattern ? '<span class="mt-[14px] inline-block rounded-[10px] border border-[#4a5578] px-[13px] py-[7px] text-[15px] font-semibold text-[#c9cfdf]">' + esc(detail.pattern) + "</span>" : "") +
        "</div>" + (v.revealed ? "" : '<button data-act="sv-reveal" class="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 px-[18px] py-[10px] text-[16px] text-[#c9cfdf]">查看双语释义</button>') +
        '<span class="absolute bottom-[12px] right-[18px] text-[14px] tabular-nums text-[#8a91a8]">' + (exIdx + 1) + "/" + exs.length + "</span></div></div>" +
      '<div class="flex flex-none items-center justify-center gap-[10px] pt-[12px]"><span class="rounded-full bg-[#e3a83c] px-[11px] py-[3px] text-[12px] font-semibold text-[#241a05]">考义</span>' + dotsM + "</div>" +
      '<footer class="grid flex-none grid-cols-2 pb-[26px] pt-[16px]">' + dashBtn("下一词", "bg-[#2ec4a5]", "sv-next") + dashBtn("收起卡片", "bg-[#e3a83c]", "sv-close") + "</footer></div>";
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
        '<div class="min-h-0 flex-1 overflow-y-auto pb-24"><div class="flex items-start justify-between pt-[10px]"><h2 class="text-[34px] font-extrabold leading-tight text-[#f0a824]">' + esc(w) + '</h2>' +
        '<button data-act="dict-fav" class="mt-2 ' + (S.dictFavs[w] ? "text-[#f0a824]" : "text-[#a9b0c8]") + '">' + ico(I.star(!!S.dictFavs[w]), "h-[22px] w-[22px]") + "</button></div>" +
        (e.phonetic ? '<button data-act="dict-speak" class="mt-[10px] flex items-center gap-2"><span class="flex items-center gap-[6px] rounded-full bg-[#2c3350] px-[12px] py-[5px]"><span class="text-[11px] text-[#a9b0c8]">美</span>' + ico(I.speaker, "h-[11px] w-[11px] text-[#a9b0c8]") + '</span><span class="text-[15px] text-[#a9b0c8]">' + esc(e.phonetic) + "</span></button>" : "") +
        '<div class="mt-[18px] space-y-[6px]">' + senses + "</div>" +
        (colloc ? '<div class="mt-[18px] border-t border-white/[0.08] pt-[18px]">' + colloc + "</div>" : "") +
        '<div class="mt-[20px] space-y-[24px]">' + exs + "</div></div>" +
        '<button data-act="dict-close" class="absolute bottom-[26px] right-[22px] flex h-[54px] w-[54px] items-center justify-center rounded-full bg-[#2b3152]/95 text-[#ececef]">' + ico(I.close, "h-[20px] w-[20px]") + "</button></div></div>";
    }
    var inner;
    if (!e) inner = '<div class="py-6 text-center"><p class="text-[20px] font-bold text-[#f0a824]">' + esc(S.dictWord.toLowerCase()) + '</p><p class="mt-3 text-[14px] text-[#8a91a8]">没有查到这个词 🤔</p></div>';
    else inner = '<div class="flex items-start justify-between"><h2 class="text-[30px] font-extrabold leading-tight text-[#f0a824]">' + esc(w) + '</h2><button data-act="dict-fav" class="mt-1 ' + (S.dictFavs[w] ? "text-[#f0a824]" : "text-[#a9b0c8]") + '">' + ico(I.star(!!S.dictFavs[w]), "h-[22px] w-[22px]") + "</button></div>" +
      (e.phonetic ? '<button data-act="dict-speak" class="mt-[10px] flex items-center gap-2"><span class="flex items-center gap-[6px] rounded-full bg-[#2c3350] px-[12px] py-[5px]"><span class="text-[11px] text-[#a9b0c8]">美</span>' + ico(I.speaker, "h-[11px] w-[11px] text-[#a9b0c8]") + '</span><span class="text-[15px] text-[#a9b0c8]">' + esc(e.phonetic) + "</span></button>" : "") +
      '<div class="mt-[22px] space-y-[5px]">' + arr(e.senses).slice(0, 2).map(function (s, i) { return '<p class="text-[17px] leading-relaxed text-[#ececef]"><span class="mr-2 text-[15px] text-[#a9b0c8]">' + esc(s.pos) + '</span><span class="' + (i === 0 ? "font-bold" : "") + '">' + esc(s.cn) + "</span></p>"; }).join("") + "</div>" +
      '<button data-act="dict-expand" class="mt-[18px] text-[15px] text-[#a9b0c8]">查看详细释义 <span class="text-[#7a8098]">›</span></button>';
    return '<div data-act="dict-close" class="absolute inset-0 z-[70]"><div data-stop="1" class="absolute left-[22px] right-[22px] top-[38%] rounded-[18px] bg-[#262c44] px-[22px] pb-[22px] pt-[20px] shadow-[0_18px_60px_rgba(0,0,0,0.55)]">' + inner + "</div></div>";
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
      '<div class="mt-[18px] min-h-0 flex-1 overflow-y-auto px-5 pb-24"><p class="mb-[18px] text-[14px] text-[#a8a8ae]">在历年真题中出现 <b class="text-[#e3a83c]">' + exams.length + "</b> 次</p>" + list + "</div>" +
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
    if (S.sentView) h += ovSentence();
    if (S.dictWord) h += ovDict();
    if (S.examOpen) h += ovExam();
    if (S.noteOpen) h += ovNote();
    if (S.spellOpen) h += ovSpell();
    if (S.menuOpen) h += ovMenu();
    if (S.settingsOpen) h += ovSettings();
    if (S.orderOpen) h += ovOrder();
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

  /* ---- 本地小词库（照 dict.ts 的 LEXICON） ---- */
  var LEXICON = {
    event: { word: "event", phonetic: "/ɪˈvent/", level: "考研", senses: [{ pos: "n.", cn: "事件；公开活动；体育项目" }], collocations: [{ en: "a major event", cn: "重大事件" }, { en: "in the event of", cn: "万一，倘若" }], examples: [{ en: "The opening ceremony was a grand event.", cn: "开幕式是一场盛大的活动。", src: "柯林斯" }] },
    unfortunate: { word: "unfortunate", phonetic: "/ʌnˈfɔːrtʃənət/", level: "考研", senses: [{ pos: "adj.", cn: "不幸的；令人遗憾的；不适当的" }, { pos: "n.", cn: "不幸的人" }], examples: [{ en: "Unfortunate incidents had occurred; mistaken ideas had been current.", cn: "不幸的事件曾发生过。", src: "动物农场" }] },
    television: { word: "television", phonetic: "/ˈtelɪvɪʒn/", level: "中考", senses: [{ pos: "n.", cn: "电视，电视机" }] },
    computer: { word: "computer", phonetic: "/kəmˈpjuːtər/", level: "中考", senses: [{ pos: "n.", cn: "计算机，电脑" }] },
    show: { word: "show", phonetic: "/ʃoʊ/", level: "中考", senses: [{ pos: "n.", cn: "演出，节目；展览" }, { pos: "v.", cn: "给…看，展示；表明" }] },
    girl: { word: "girl", phonetic: "/ɡɜːrl/", level: "中考", senses: [{ pos: "n.", cn: "女孩，姑娘" }] },
    fighting: { word: "fighting", phonetic: "/ˈfaɪtɪŋ/", level: "高考", senses: [{ pos: "n.", cn: "战斗，打斗" }, { pos: "adj.", cn: "战斗的" }] },
    war: { word: "war", phonetic: "/wɔːr/", level: "中考", senses: [{ pos: "n.", cn: "战争；斗争" }], collocations: [{ en: "full-scale war", cn: "全面战争" }] },
    collect: { word: "collect", phonetic: "/kəˈlekt/", level: "四级", senses: [{ pos: "v.", cn: "收集，采集；领取" }] },
    signature: { word: "signature", phonetic: "/ˈsɪɡnətʃər/", level: "考研", senses: [{ pos: "n.", cn: "签名，署名" }], examples: [{ en: "He forged my signature.", cn: "他伪造了我的签名。", src: "柯林斯" }] },
    national: { word: "national", phonetic: "/ˈnæʃnəl/", level: "四级", senses: [{ pos: "adj.", cn: "国家的，全国的" }, { pos: "n.", cn: "国民" }] },
    internet: { word: "internet", phonetic: "/ˈɪntərnet/", level: "中考", senses: [{ pos: "n.", cn: "互联网，因特网" }] },
    impact: { word: "impact", phonetic: "/ˈɪmpækt/", level: "考研", senses: [{ pos: "n.", cn: "影响，冲击力" }, { pos: "v.", cn: "对…产生影响" }], collocations: [{ en: "have a profound impact on", cn: "对…产生深远影响" }] },
    life: { word: "life", phonetic: "/laɪf/", level: "中考", senses: [{ pos: "n.", cn: "生活；生命；一生" }] },
    measure: { word: "measure", phonetic: "/ˈmeʒər/", level: "考研", senses: [{ pos: "n.", cn: "措施，方法；度量" }, { pos: "v.", cn: "测量，衡量" }], collocations: [{ en: "take measures", cn: "采取措施" }] },
    housing: { word: "housing", phonetic: "/ˈhaʊzɪŋ/", level: "考研", senses: [{ pos: "n.", cn: "住房，住宅；住房供给" }] },
    shortage: { word: "shortage", phonetic: "/ˈʃɔːrtɪdʒ/", level: "考研", senses: [{ pos: "n.", cn: "短缺，不足" }], collocations: [{ en: "housing shortage", cn: "住房短缺" }] },
    behavior: { word: "behavior", phonetic: "/bɪˈheɪvjər/", level: "考研", senses: [{ pos: "n.", cn: "行为，举止" }] },
    multiple: { word: "multiple", phonetic: "/ˈmʌltɪpl/", level: "考研", senses: [{ pos: "adj.", cn: "多个的，多种的" }, { pos: "n.", cn: "倍数" }] },
    literacy: { word: "literacy", phonetic: "/ˈlɪtərəsi/", level: "考研", senses: [{ pos: "n.", cn: "读写能力；素养" }] },
    judgment: { word: "judgment", phonetic: "/ˈdʒʌdʒmənt/", level: "考研", senses: [{ pos: "n.", cn: "判断力；判决" }] },
    journalist: { word: "journalist", phonetic: "/ˈdʒɜːrnəlɪst/", level: "考研", senses: [{ pos: "n.", cn: "记者，新闻工作者" }] },
    dream: { word: "dream", phonetic: "/driːm/", level: "中考", senses: [{ pos: "n.", cn: "梦；梦想" }, { pos: "v.", cn: "做梦；梦想" }] },
    control: { word: "control", phonetic: "/kənˈtroʊl/", level: "四级", senses: [{ pos: "n./v.", cn: "控制，支配" }] },
    incident: { word: "incident", phonetic: "/ˈɪnsɪdənt/", level: "考研", senses: [{ pos: "n.", cn: "事件；(两国间的) 冲突；事变" }] }
  };
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
  function lookup(w) {
    var key = String(w || "").toLowerCase().replace(/[^a-z'-]/g, "");
    if (!key) return Promise.resolve(null);
    if (_dictCache.hasOwnProperty(key)) return Promise.resolve(_dictCache[key]);
    var cands = dictCandidates(key);
    for (var i = 0; i < cands.length; i++) if (LEXICON[cands[i]]) { _dictCache[key] = LEXICON[cands[i]]; return Promise.resolve(LEXICON[cands[i]]); }
    var pool = [];
    if (S.card) pool.push(S.card);
    S.queue.forEach(function (c) { if (c && c !== S.card) pool.push(c); });
    for (var j = 0; j < pool.length; j++) {
      var f = pool[j].fields || {};
      if (String(f.word || "").toLowerCase() === key) {
        var e = { word: f.word, phonetic: f.phonetic, level: "考研",
          senses: arr(f.senses).map(function (s) { return { pos: s.pos, cn: arr(s.cn).join("；") }; }),
          collocations: arr(f.collocations),
          examples: [{ en: (f.sentence || {}).en, cn: (f.sentence || {}).cn, src: "词书例句" }].concat(arr(f.exams).map(function (x) { return { en: x.en, src: x.src }; })) };
        _dictCache[key] = e; return Promise.resolve(e);
      }
    }
    if (typeof fetch !== "function") { _dictCache[key] = null; return Promise.resolve(null); }
    return fetch("https://api.dictionaryapi.dev/api/v2/entries/en/" + encodeURIComponent(key))
      .then(function (r) { if (!r.ok) throw 0; return r.json(); })
      .then(function (j) {
        var d = j[0];
        var senses = arr(d.meanings).slice(0, 3).map(function (m) {
          var p = m.partOfSpeech === "noun" ? "n." : m.partOfSpeech === "verb" ? "v." : m.partOfSpeech === "adjective" ? "adj." : m.partOfSpeech === "adverb" ? "adv." : (m.partOfSpeech || "") + ".";
          return { pos: p, cn: (arr(m.definitions)[0] || {}).definition || "" };
        });
        var exs = [];
        arr(d.meanings).forEach(function (m) { arr(m.definitions).forEach(function (df) { if (df.example && exs.length < 3) exs.push({ en: df.example, src: "Dictionary API" }); }); });
        var e = { word: d.word, phonetic: d.phonetic || "", senses: senses, examples: exs, fromApi: true };
        _dictCache[key] = e; return e;
      })
      .catch(function () { _dictCache[key] = null; return null; });
  }
  function openDict(w) {
    S.dictWord = w; S.dictExpanded = false; S.dictEntry = null; paint();
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
    S.hinted = false; S.missed = []; S.wrongs = 0; S.history = []; S.learned = {};
    S.queue = []; S.card = null; paint();
    log("startSession " + mode);
    call("session.plan", {}).then(function (plan) {
      var ids = extractIds(plan);
      log("session.plan -> ids=" + ids.length);
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
        reportProgress(); paint();
      });
    }).catch(function (e) { log("startSession ERR " + (e && e.message ? e.message : e)); });
  }
  function reportProgress() {
    try { FC.post("web.progress", { phase: S.phase, done: S.idx, total: S.queue.length, graduated: S.queue.length - S.missed.length }); } catch (e) {}
  }
  function finish() {
    S.queue.forEach(function (c) {
      call("review.commit", { id: c.id, rating: S.missed.indexOf(c.id) >= 0 ? "again" : "good" });
    });
    S.phase = "done";
    try { FC.post("web.finish", { graduated: S.queue.length - S.missed.length }); } catch (e) {}
    paint();
  }

  /* ---- 卡片流转 ---- */
  function flip(miss) {
    if (miss && S.missed.indexOf(S.card.id) < 0) S.missed.push(S.card.id);
    S.history.push({ idx: S.idx, face: "front" });
    S.face = "back"; S.tab = "colloc";
    speakWordThenSentence(S.card);
    paint();
  }
  function nextCard(miss) {
    if (miss && S.missed.indexOf(S.card.id) < 0) S.missed.push(S.card.id);
    S.history.push({ idx: S.idx, face: "back" });
    S.face = "front"; S.tab = "colloc"; S.hinted = false;
    if (S.idx + 1 < S.queue.length) { S.idx++; S.card = S.queue[S.idx]; }
    else { finish(); return; }
    reportProgress(); paint();
  }

  /* ---- 事件总入口 ---- */
  function handle(act, el, e) {
    var i, m;
    switch (act) {
      case "home": S.screen = "home"; S.phase = "cards"; S.sentView = null; S.dictWord = null; S.examOpen = S.noteOpen = S.spellOpen = false; paint(); break;
      case "start-learn": startSession("learn"); break;
      case "start-review": startSession("review"); break;
      case "flip-ok": flip(false); break;
      case "flip-miss": flip(true); break;
      case "next": nextCard(false); break;
      case "next-miss": nextCard(true); break;
      case "hint": S.hinted = true; paint(); break;
      case "known":
        call("state.kvPut", { id: S.card.id, key: "known", value: true });
        S.queue = S.queue.filter(function (c) { return c.id !== S.card.id; });
        S.face = "front"; S.hinted = false;
        if (S.idx >= S.queue.length) { finish(); } else { S.card = S.queue[S.idx]; paint(); }
        break;
      case "undo":
        if (S.history.length) { var last = S.history.pop(); S.idx = last.idx; S.face = last.face; S.tab = "colloc"; S.hinted = false; S.card = S.queue[S.idx]; paint(); }
        break;
      case "fav":
        S.favs[S.card.id] = !S.favs[S.card.id];
        call("state.kvPut", { id: S.card.id, key: "fav", value: !!S.favs[S.card.id] });
        paint(); break;
      case "tab": S.tab = el.getAttribute("data-t"); paint(); break;
      case "meaning": openSV(parseInt(el.getAttribute("data-m"), 10) || 0); break;
      case "sentence-view": openSV(0); break;
      case "word": openDict(el.getAttribute("data-w")); break;
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
      case "menu": S.menuOpen = true; paint(); break;
      case "menu-close": S.menuOpen = false; paint(); break;
      case "menu-settings": S.menuOpen = false; S.settingsOpen = true; paint(); break;
      case "menu-noop": S.menuOpen = false; paint(); break;
      case "settings-close": S.settingsOpen = false; paint(); break;
      case "pref-toggle": var k = el.getAttribute("data-k"); S.prefs[k] = !S.prefs[k]; if (k === "topbar") call("ui.setChrome", { top: !!S.prefs[k] }); paint(); break;
      case "order-open": S.settingsOpen = false; S.orderOpen = true; paint(); break;
      case "order-close": S.orderOpen = false; paint(); break;
      case "order-up": i = parseInt(el.getAttribute("data-i"), 10); if (i > 0) { var a = S.tabOrder; var t = a[i]; a[i] = a[i - 1]; a[i - 1] = t; paint(); } break;
      case "order-down": i = parseInt(el.getAttribute("data-i"), 10); if (i < S.tabOrder.length - 1) { var b = S.tabOrder; var u = b[i]; b[i] = b[i + 1]; b[i + 1] = u; paint(); } break;
      case "dict-close": S.dictWord = null; S.dictExpanded = false; paint(); break;
      case "dict-expand": S.dictExpanded = true; paint(); break;
      case "dict-fav": var w = (S.dictEntry && S.dictEntry.word) || S.dictWord; S.dictFavs[w] = !S.dictFavs[w]; paint(); break;
      case "dict-speak": if (S.dictEntry) speak(S.dictEntry.word); break;
      case "sv-close": S.sentView = null; paint(); break;
      case "sv-next": S.sentView = null; nextCard(false); break;
      case "sv-reveal": if (S.sentView) { S.sentView.revealed = true; paint(); } break;
      case "sv-m": if (S.sentView) { S.sentView.m = parseInt(el.getAttribute("data-m"), 10) || 0; S.sentView.ex = 0; S.sentView.revealed = false; paint(); } break;
      case "sv-star": if (S.sentView) { S.sentView.star = !S.sentView.star; paint(); } break;
      case "sv-speak": var d = S.sentView && arr((S.sentView.card.fields || {}).meaningDetails)[S.sentView.m]; var ex0 = d && arr(d.examples)[S.sentView.ex]; if (ex0) speak(ex0.en, TTS_PASSAGE); break;
      case "passage-speak": if (S.passage) speak(S.passage.plain || ""); break;
      case "cloze-start": if (S.passage) { S.phase = "cloze"; initCloze(); paint(); } break;
      case "cloze-back": S.phase = "passage"; paint(); break;
      case "cloze-chip": tapChip(el.getAttribute("data-w")); break;
      case "cards-start": S.phase = "cards"; paint(); break;
      case "choice-pick":
        if (S.revealed) break;
        i = parseInt(el.getAttribute("data-i"), 10);
        S.picked = i; S.revealed = true;
        if (!S.choiceOpts[i] || S.choiceOpts[i].id !== S.rCur.id) S.wrongs++;
        speak((S.rCur.fields || {}).word); paint(); break;
      case "choice-reveal": S.revealed = true; S.wrongs++; speak((S.rCur.fields || {}).word); paint(); break;
      case "choice-next":
        S.revealed = false; S.picked = null;
        if (S.rIdx + 1 < (S.retestCards || []).length) { S.rIdx++; S.rCur = S.retestCards[S.rIdx]; buildChoice(); }
        else { finish(); return; }
        paint(); break;
    }
  }

  function initCloze() {
    var parts = arr((S.passage || {}).parts);
    S.clozeTargets = parts.filter(function (x) { return x.word; }).map(function (x) { return x.word; });
    S.clozeBank = shuffle(S.clozeTargets, 42);
    S.clozeFilled = S.clozeTargets.map(function () { return null; });
    S.clozeErr = null; S.clozeWrongs = 0;
  }
  function tapChip(w) {
    var filled = S.clozeFilled, next = filled.indexOf(null);
    if (next === -1 || filled.indexOf(w) >= 0) return;
    if (S.clozeTargets[next] === w) { filled[next] = w; speak(w); }
    else { S.clozeErr = w; S.clozeWrongs++; setTimeout(function () { S.clozeErr = null; paint(); }, 550); }
    paint();
  }
  function buildChoice() {
    var pool = S.queue.slice();
    S.choiceOpts = shuffle(pool, (S.rCur.id.charCodeAt(1) || 7) * 17).slice(0, Math.min(4, pool.length));
    if (S.choiceOpts.indexOf(S.rCur) < 0) S.choiceOpts[0] = S.rCur;
  }

  root.addEventListener("click", function (e) {
    var hit = closestAct(e.target);
    if (!hit) return;
    if (hit.word) { openDict(hit.word); return; }
    handle(hit.act, hit.el, e);
  });
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
    }
  });
  root.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && e.target && e.target.getAttribute && e.target.getAttribute("data-role") === "spell") {
      handle("spell-check", e.target, e);
    }
  });

  /* ---- 壳回调 ---- */
  if (FC.onMount) FC.onMount(function () {
    var c = FC.getCard();
    if (c && c.id) {
      if (c.passage) S.passage = c.passage;
      if (S.phase === "cards" || S.screen === "home") { S.card = c; if (S.screen === "home") S.screen = "learn"; }
      paint();
    }
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
    call("session.plan", {}).then(function (plan) {
      var units = arr(plan && plan.units);
      var anyReview = units.some(function (u) { return u && u.isReview; });
      var anyNew = units.some(function (u) { return u && !u.isReview; });
      var mode = (anyReview && !anyNew) ? "review" : "learn";
      log("autoStart mode=" + mode + " units=" + units.length);
      startSession(mode);
    }).catch(function (e) {
      log("autoStart ERR " + (e && e.message ? e.message : e));
      startSession("learn");
    });
  }
  if (FC.on) FC.on("web.start", function () { log("event web.start"); autoStart(); });
  (function boot() {
    var c0 = FC.getCard();
    log("boot cardId=[" + ((c0 && c0.id) || "") + "]");
    /* 顶部栏偏好：问壳要盘上值，回填设置开关状态 */
    call("ui.getChrome", {}).then(function (r) {
      if (r && r.top != null) { S.prefs.topbar = !!r.top; paint(); }
    }).catch(function () {});
    if (c0 && c0.id) { S.card = c0; S.screen = "learn"; started = true; }
    paint();
    try { if (FC.ready) FC.ready(); } catch (e) {}
    if (!started) autoStart();
  })();
})();
