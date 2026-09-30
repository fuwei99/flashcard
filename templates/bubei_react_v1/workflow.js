/* ============================================================
   workflow.js —— bubei_react_v1 的学习流程定义（对齐 bubei_dark）
   ------------------------------------------------------------
   本层负责「流程」，渲染归 script.js，壳只提供原子能力：
     · 语篇通读 → 语篇填空 → 自评(learn) → 重考(choice/cloze) → 拼写
     · hard/good/again 判据：effort 状态机（0=good 1=hard >=2=again）
     · 重考池按卡片 modes 逐模式考，过完全部 mode 才毕业
   字段口径：v4（sentence.en / senses[].cn 数组 / phonetic 单串）
   脚本加载顺序：script.js 先，workflow.js 后（后者覆盖前者默认实现）。
   ============================================================ */
(function () {
  "use strict";
  var FC = window.Flashcard;
  if (!FC) return;
  var WF = (window.FlashcardWorkflow = window.FlashcardWorkflow || {});
  var H = FC.helpers || {};

  // ---------- 渲染原语（模板提供，缺了就退化）----------
  function speak(text, opts) {
    if (H.speak) { H.speak(text, opts); return; }
    try { if (FC.tts) FC.tts(text, opts); } catch (e) {}
  }
  var TTS_WORD = H.ttsWord || { lang: "en-US", cache: true, play: "file" };
  var TTS_SENTENCE = H.ttsSentence || { lang: "en-US", cache: false, play: "stream" };

  function log(msg) { if (FC.log) { try { FC.log("[WF]", msg); } catch (e) {} } }

  // 重测轮上限：一个单元内最多重来这么多轮，到顶放行剩下的卡，防死循环。
  var MAX_RETEST_ROUND = 10;
  var WF_NAME = "bubei_react_v1.word";

  // ---------- 会话断点 ----------
  var _cursor = null;
  var _timer = null;

  function sessionSnapshot() {
    if (!S) return null;
    var grad = [], settled = [];
    for (var g in S.graduated) { if (S.graduated[g]) grad.push(g); }
    for (var p in S.settled) { if (S.settled[p]) settled.push(p); }
    return {
      unitIdx: S.unitIdx,
      phase: S.phase,
      round: S.round,
      retestPool: S.retestPool.slice(),
      effort: S.effort,
      learnRating: S.learnRating,
      passageTag: S.passageTag,
      passedModes: S.passedModes,
      retestFailed: S.retestFailed,
      wrongCount: S.wrongCount,
      graduated: grad,
      settled: settled
    };
  }

  function saveNow(cursor) {
    if (cursor) _cursor = cursor;
    if (!FC.call) return;
    var session = sessionSnapshot();
    if (!session) return;
    try {
      FC.call("session.save", { workflow: WF_NAME, cursor: _cursor, session: session }).catch(function () {});
    } catch (e) {}
  }
  function saveSoon(cursor) {
    if (cursor) _cursor = cursor;
    if (_timer) return;
    _timer = setTimeout(function () { _timer = null; saveNow(null); }, 400);
  }
  function clearSaved() {
    _cursor = null;
    if (!FC.call) return;
    // 主学习会话还在跑 -> 只清 cursor，保留学习快照
    if (S && S.phase && S.phase !== "done") {
      try {
        FC.call("session.save", { workflow: WF_NAME, cursor: null, session: sessionSnapshot() }).catch(function () {});
      } catch (e) {}
      return;
    }
    try { FC.call("session.clear", {}).catch(function () {}); } catch (e) {}
  }

  WF.name = WF_NAME;
  WF.saveNow = saveNow;
  WF.saveSoon = saveSoon;
  WF.clear = clearSaved;
  WF.version = "0.1.0";

  if (FC.on) {
    FC.on("lifecycle.pause", function () { saveNow(null); });
  }

  // ============================================================
  //  阶段 4：会话驱动
  // ============================================================
  var S = null;
  var _committed = {};

  function sPost(type, data) { if (FC.post) FC.post(type, data || {}); }
  function cardMeta(id) { return S.cardById[id] || null; }
  function modesOf(id) {
    var c = cardMeta(id);
    var base = (c && c.modes) ? c.modes.slice() : [];
    // 兜底：壳对 v4 卡（sentence 是对象，不是 v3 的 sentence_en）可能算不出 cloze，
    // 只要本次开了 cloze 重考且这卡能考 choice，就补上 cloze —— 否则「例句填空」永不出现。
    // 但**得有例句才补**：没例句的卡硬塞 cloze，那页只能退化成「看中文选词」（2026-09-28）。
    if (S && S.retestModes.indexOf("cloze") >= 0 && base.indexOf("choice") >= 0 && base.indexOf("cloze") < 0) {
      var H = FC.helpers || {};
      var f = (c && (c.fields || c)) || {};
      var se = "";
      try {
        if (H.sentenceOf) se = H.sentenceOf(H.normalizeFields ? H.normalizeFields(f) : f, f.word);
        else se = String((f.sentence && f.sentence.en) || f.sentence_en || "").trim();
      } catch (e) { se = ""; }
      if (se) base.push("cloze");
    }
    return base;
  }

  function allPassed(id) {
    var modes = modesOf(id);
    if (!modes.length) return true;
    var p = S.passedModes[id] || {};
    for (var i = 0; i < modes.length; i++) { if (!p[modes[i]]) return false; }
    return true;
  }
  function bump(id, e) { if (e > (S.effort[id] || 0)) S.effort[id] = e; }
  function ratingFor(id) {
    var e = S.effort[id] || 0;
    return e === 0 ? "good" : (e === 1 ? "hard" : "again");
  }
  function cardsBetween(from, to) {
    var out = [], seen = {};
    for (var i = from; i < to && i < S.units.length; i++) {
      var cs = S.units[i].cards || [];
      for (var j = 0; j < cs.length; j++) {
        if (!seen[cs[j].id]) { seen[cs[j].id] = 1; out.push(cs[j].id); }
      }
    }
    return out;
  }
  function buildIndex() {
    S.cardById = {};
    S.cardIsReview = {};
    for (var i = 0; i < S.units.length; i++) {
      var cs = S.units[i].cards || [];
      for (var j = 0; j < cs.length; j++) {
        S.cardById[cs[j].id] = cs[j];
        S.cardIsReview[cs[j].id] = !!S.units[i].isReview;
      }
    }
  }
  function removePool(id) {
    var i = S.retestPool.indexOf(id);
    if (i >= 0) S.retestPool.splice(i, 1);
  }

  /// 本单元「已背完」几张 —— 进度条/角标的唯一口径。
  ///
  /// 以前角标画的是 `第几张/本轮几张`（roundTotal - queue.length），
  /// 重考轮分母还会跟着池子变，用户根本读不出「这一单元背完几个了」。
  /// 现在统一：分子 = 本单元已毕业（含标熟）的卡数，分母 = 本单元总卡数。
  function unitDone() {
    var ids = S.unitIds || [];
    var n = 0;
    for (var i = 0; i < ids.length; i++) { if (S.graduated[ids[i]]) n++; }
    return n;
  }

  function enterLearn() {
    if (!S.queue.length) {
      if (S.retestPool.length && S.retestModes.length) {
        S.round = 2; S.modeIdx = 0; startMode(); return;
      }
      nextUnit(); return;
    }
    S.phase = "learn";
    S.roundTotal = S.queue.length;
  }

  function startUnit() {
    S.queue = [];
    S.retestPool = [];
    S.passedModes = {};
    S.wrongCount = {};
    S.round = 1;
    S.modeIdx = 0;
    var u = S.units[S.unitIdx];
    if (!u) { S.phase = "done"; return; }
    // 进度分母：本单元卡数。整个单元（learn + 重考 + 拼写）都用它，
    // 不随重考轮次/考法变化。
    S.unitIds = (u.cards || []).map(function (c) { return c.id; });
    S.unitTotal = S.unitIds.length;
    S.queue = (u.cards || []).map(function (c) {
      return { cardId: c.id, mode: "read", round: 1 };
    });
    S.roundTotal = S.queue.length;
    if (u.hasPassage && u.readFirst) S.phase = "passage";
    else if (u.hasPassage && S.passageCloze) S.phase = "passageCloze";
    else enterLearn();
  }

  function nextUnit() {
    S.unitIdx++;
    if (!S.reviewSpellDone && S.leadingReviewCount > 0 &&
        S.unitIdx === S.leadingReviewCount && S.unitIdx < S.units.length) {
      S.reviewSpellDone = true;
      var cs = cardsBetween(0, S.leadingReviewCount);
      if (cs.length) {
        S.spellCards = cs; S.spellReturnsToUnits = true; S.spellDone = 0;
        S.phase = "spellPrompt"; return;
      }
    }
    if (S.unitIdx >= S.units.length) {
      if (!S.finalSpellDone) {
        S.finalSpellDone = true;
        var from = S.reviewSpellDone ? S.leadingReviewCount : 0;
        var cs2 = cardsBetween(from, S.units.length);
        if (cs2.length) {
          S.spellCards = cs2; S.spellReturnsToUnits = false; S.spellDone = 0;
          S.phase = "spellPrompt"; return;
        }
      }
      S.phase = "done"; return;
    }
    startUnit();
  }

  function startMode() {
    // 兜底一：池里「考不了任何启用中的考法」的卡 = 没有重考可做，自评即终评。
    // 以前不管自评是什么，这里一律 graduated + 计数 —— 「不认识」也成了「背完」。
    S.retestPool.slice().forEach(function (id) {
      var ms = modesOf(id);
      var playable = ms.filter(function (m) { return S.retestModes.indexOf(m) >= 0; });
      if (!playable.length) settleNoRetest(id);
    });
    while (S.modeIdx < S.retestModes.length) {
      var m = S.retestModes[S.modeIdx];
      var pending = S.retestPool.filter(function (id) {
        if (S.graduated[id]) return false;
        if (modesOf(id).indexOf(m) < 0) return false;
        var p = S.passedModes[id] || {};
        return !p[m];
      });
      if (!pending.length) { S.modeIdx++; continue; }
      S.phase = (m === "cloze") ? "cloze" : "choice";
      S.queue = pending.map(function (id) {
        return { cardId: id, mode: m, round: S.round };
      });
      S.roundTotal = S.queue.length;
      return;
    }
    if (!S.retestPool.length) { nextUnit(); return; }

    // 兜底二：轮数封顶。到顶直接终评放行 —— 但**不算背完**：
    // 连考 10 轮都没过，凭什么是「已背」？只落 FSRS，保住调度数据不丢。
    if (S.round >= MAX_RETEST_ROUND) {
      S.retestPool.slice().forEach(function (id) {
        if (S.graduated[id]) return;
        S.settled[id] = true;
        commitNow(id, ratingFor(id));
      });
      S.retestPool = [];
      nextUnit();
      return;
    }
    S.round++; S.modeIdx = 0; startMode();
  }

  function advance() {
    if (S.queue.length) return;
    if (S.phase === "learn") {
      if (!S.retestPool.length || !S.retestModes.length) { nextUnit(); return; }
      S.round = 2; S.modeIdx = 0; startMode(); return;
    }
    S.modeIdx++;
    startMode();
  }

  /// 自评落账（learn 阶段）。
  ///
  /// **铁律：只有毕业才写 FSRS。** 以前这里对 hard / again 直接
  /// `commitProvisional(hard)` —— 「不认识」当场落一笔 hard，FSRS 立刻把这张卡
  /// 记成已学、due 推到明天，加上壳按「首次学会」记今日背词量，
  /// 于是「没考过选词也算背过」（2026-09-30 实机）。
  ///
  /// effort 状态机：0=good / 1=hard / >=2=again。again 必须记 2，
  /// 不能像以前那样 bump(id,1) 压成 hard —— 那样 again 判据整个丢失。
  function submitLearn(rating) {
    if (!S.queue.length) return;
    var step = S.queue.shift();
    var id = step.cardId;
    var tag = S.passageTag[id] || "untested";
    S.learnRating[id] = rating;
    if (!modesOf(id).length) {
      // 壳没给可考量法：没有重考可做，自评就是终评。
      bump(id, rating === "good" ? 0 : (rating === "hard" ? 1 : 2));
      if (rating === "good") S.graduated[id] = true;
      else { S.settled[id] = true; commitNow(id, rating); }
      advance();
      return;
    }
    if (rating === "good" || (rating === "hard" && tag === "tested")) {
      S.graduated[id] = true;
    } else {
      if (S.retestPool.indexOf(id) < 0) S.retestPool.push(id);
      bump(id, rating === "again" ? 2 : 1);
    }
    advance();
  }

  function submitRetest(mode, ok) {
    if (!S.queue.length) return;
    var step = S.queue.shift();
    var id = step.cardId;
    if (ok) {
      (S.passedModes[id] = S.passedModes[id] || {})[mode] = true;
      if (allPassed(id)) { removePool(id); S.graduated[id] = true; }
    } else {
      S.retestFailed[id] = true;
      var n = (S.wrongCount[id] || 0) + 1;
      S.wrongCount[id] = n;
      bump(id, 2);
    }
    advance();
  }

  function submitPassage() {
    var u = S.units[S.unitIdx];
    if (S.passageCloze && u && u.hasPassage) S.phase = "passageCloze";
    else enterLearn();
  }

  function submitPassageCloze(ok, meta) {
    if (!ok) return;
    var tag = (meta && meta.passageTag) || {};
    S.passageTag = tag;
    // 语篇错 >= 3 的词：跳过自评，直接进重考池
    var failed = [];
    S.queue = S.queue.filter(function (step) {
      var m = cardMeta(step.cardId);
      var w = m && m.word ? String(m.word).trim().toLowerCase() : "";
      if (w && tag[w] === "failed") { failed.push(step.cardId); return false; }
      return true;
    });
    failed.forEach(function (id) {
      S.learnRating[id] = "hard";
      if (S.retestPool.indexOf(id) < 0) S.retestPool.push(id);
      bump(id, 2);
    });
    enterLearn();
  }

  /// 终评：语篇客观证据 + 本轮挣扎程度（effort 状态机）二合一。
  ///   语篇里错 >= 3 次的词（failed）→ again，不管自评怎么吹
  ///   其余按 effort：0 一次过 = good / 1 费了点劲 = hard / >=2 硬骨头 = again
  function finalRating(id) {
    if ((S.passageTag[id] || "untested") === "failed") return "again";
    return ratingFor(id);
  }

  /// 唯一 FSRS 写入口。落盘一次就记账，后续不会再重复提交。
  function commitNow(id, rating) {
    if (_committed[id]) return;
    _committed[id] = true;
    log("commit " + id + " rating=" + rating);
    try { FC.call("review.commit", { id: id, rating: rating }).catch(function () {}); } catch (e) {}
  }

  /// 池里那批「没有重考可考」的卡：自评即终评。
  /// 自评「认识」= 背完（计数）；hard / again 只落 FSRS，不算背完。
  function settleNoRetest(id) {
    removePool(id);
    if (S.graduated[id] || S.settled[id]) return;
    if (ratingFor(id) === "good") { S.graduated[id] = true; return; }
    S.settled[id] = true;
    commitNow(id, ratingFor(id));
  }

  /// 记「今日背词量」：复习卡（isReview 单元）不占新词额度，只走 FSRS。
  /// 封顶放行 / 无考法终评的卡（settled / forced）不算 —— 它们没背下来。
  /// 壳只提供 stats.markDone 这个原子能力，「何时算背下一个」归本层流程。
  function markCounted(id) {
    if (S.settled[id]) return;
    if (S.cardIsReview && S.cardIsReview[id]) return;
    try { FC.call("stats.markDone", {}).catch(function () {}); } catch (e) {}
  }

  function flushGraduated() {
    Object.keys(S.graduated).forEach(function (id) {
      if (_committed[id]) return;
      var r = finalRating(id);
      commitNow(id, r);
      markCounted(id);
    });
  }

  function progressDone() {
    if (S.phase === "spell" || S.phase === "spellPrompt") return S.spellDone;
    return unitDone();
  }
  function progressTotal() {
    if (S.phase === "spell" || S.phase === "spellPrompt") return S.spellCards.length;
    return S.unitTotal || 0;
  }
  function reportProgress() {
    sPost("web.progress", {
      phase: S.phase,
      done: progressDone(),
      total: progressTotal(),
      graduated: unitDone()
    });
  }

  // ============================================================
  //  拼写轮条目（v4 字段口径）
  // ============================================================
  function spellCnOf(f) {
    var parts = [];
    if (Array.isArray(f && f.senses)) {
      f.senses.forEach(function (s) {
        var cn = String((Array.isArray(s.cn) ? s.cn.join("；") : s.cn) || s.meaning || "")
          .replace(/[（(][^（()）]*[)）]/g, "").trim();
        if (!cn) return;
        var pos = String(s.pos || "").trim();
        parts.push((pos ? pos + " " : "") + cn);
      });
    }
    return parts.join("；");
  }
  function passagePlainOf(p) {
    var out = "", segs = (p && p.segments) || [];
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i] || {};
      out += (s.w != null) ? String(s.w) : (s.t != null ? String(s.t) : "");
    }
    return out;
  }
  function passageSurfaceOf(p, word) {
    var lemma = String(word || "").trim().toLowerCase();
    var segs = (p && p.segments) || [];
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i] || {};
      if (s.w == null) continue;
      if (String(s.lemma || "").trim().toLowerCase() === lemma) return String(s.w || "").trim();
    }
    return null;
  }
  /// 组这一轮要拼的条目：有例句→句子拼写；没例句→单词拼写；在语篇出现过→语篇拼写(排最后)
  function buildSpellItems(ids) {
    var passageOf = {};
    for (var i = 0; i < S.units.length; i++) {
      var u = S.units[i];
      if (!u || !u.hasPassage || !u.passage) continue;
      (u.cards || []).forEach(function (c) { passageOf[c.id] = u.passage; });
    }
    var jobs = (ids || []).map(function (id) {
      var meta = cardMeta(id);
      var w = meta && meta.word ? String(meta.word).trim() : "";
      if (!w) return Promise.resolve(null);
      return FC.call("card.get", { id: id }).then(function (r) {
        var c = r && r.card;
        if (!c) return null;
        if (c.kv && c.kv.known) return null;   // 标熟 = 跳过拼写
        var f = c.fields || {};
        var cn = spellCnOf(f);
        var sent = String((f.sentence && f.sentence.en) || "").trim();
        var main = sent
          ? { kind: "sentence", id: id, word: w, cn: cn, sentence: sent }
          : { kind: "word", id: id, word: w, cn: cn };
        var p = passageOf[id], pas = null;
        if (p) {
          var surface = passageSurfaceOf(p, w);
          if (surface) {
            pas = { kind: "passage", id: id, word: w, cn: cn, passage: passagePlainOf(p), surface: surface };
          }
        }
        return { main: main, pas: pas };
      }).catch(function () { return null; });
    });
    return Promise.all(jobs).then(function (rs) {
      var sent = [], single = [], pas = [];
      rs.forEach(function (r) {
        if (!r) return;
        if (r.main.kind === "sentence") sent.push(r.main); else single.push(r.main);
        if (r.pas) pas.push(r.pas);
      });
      return sent.concat(single, pas);
    });
  }

  function beginSpell() {
    if (!S || S.phase !== "spellPrompt") return;
    log("beginSpell n=" + S.spellCards.length);
    S.spellDone = 0;
    S.phase = "spell";
    saveSoon(null);
    buildSpellItems(S.spellCards).then(function (items) {
      if (!S || S.phase !== "spell") return;
      if (FC.spell && FC.spell.start) FC.spell.start(items);
      else if (FC.startSpellRound) FC.startSpellRound(items);
      else endSpell();
    }).catch(function (e) {
      log("buildSpellItems 失败 " + e);
      if (S && S.phase === "spell") endSpell();
    });
  }

  function endSpell() {
    if (!S) return;
    log("endSpell returns=" + S.spellReturnsToUnits);
    S.spellCards = []; S.spellDone = 0;
    if (S.spellReturnsToUnits) { S.spellReturnsToUnits = false; startUnit(); }
    else S.phase = "done";
    render();
  }

  // ============================================================
  //  渲染驱动：向壳要 mount（read / choice / cloze / passage / passage_cloze）
  // ============================================================
  function render() {
    if (!S) return;
    log("render phase=" + S.phase + " unit=" + S.unitIdx + " q=" + S.queue.length + " spell=" + S.spellCards.length);
    saveSoon(null);
    if (S.phase === "done") {
      clearSaved();
      sPost("web.finish", { graduated: Object.keys(S.graduated).length });
      return;
    }
    if (S.phase === "spellPrompt") {
      if (FC.spell && FC.spell.ask) FC.spell.ask(S.spellCards.length);
      else if (FC.spellAsk) FC.spellAsk(S.spellCards.length);
      return;
    }
    if (S.phase === "spell") return;   // 拼写轮 UI 归 script.js
    if (S.phase === "passage" || S.phase === "passageCloze") {
      sPost("web.mount", {
        unit: S.unitIdx,
        mode: S.phase === "passage" ? "passage" : "passage_cloze",
        // index/total 语义 = 「本单元已背完 N / 共 M」，不再是「第几张 / 本轮几张」。
        index: unitDone(), total: S.unitTotal, round: 1
      });
      return;
    }
    var step = S.queue[0];
    if (!step) return;
    sPost("web.mount", {
      unit: S.unitIdx,
      cardId: step.cardId,
      mode: step.mode,
      index: unitDone(),
      total: S.unitTotal,
      round: step.round
    });
  }

  function onAnswer(rating, meta) {
    if (!S) return;
    log("answer " + rating + " phase=" + S.phase + " q=" + S.queue.length);
    // 标熟：用户在任意阶段点「熟」= 人为判定这张卡已经背过 → 直接毕业 + 落 good。
    // 以前在重测页点「熟」只按 good 交了当前那一门考法，另一门还得再考一遍（白送），
    // 于是「标熟却毕不了业」。现在标熟 = 一次性出队，跟点「认识」一个待遇。
    if (meta && meta.known && S.queue.length) {
      var kid = S.queue.shift().cardId;
      S.learnRating[kid] = S.learnRating[kid] || "good";
      if (typeof S.effort[kid] === "number") S.effort[kid] = 0;
      removePool(kid);
      S.graduated[kid] = true;
      advance();
    } else if (S.phase === "learn") submitLearn(rating);
    else if (S.phase === "choice" || S.phase === "cloze") submitRetest(S.phase, rating !== "again");
    else if (S.phase === "passage") submitPassage();
    else if (S.phase === "passageCloze") submitPassageCloze(rating !== "again", meta);
    else return;
    flushGraduated();
    reportProgress();
    render();
  }

  // ============================================================
  //  会话启动 / 续上
  // ============================================================
  /* 断点是否真的属于当前 plan 的当前 unit？
     壳的 session.load 只有一份全局断点，跨书 / 跨章不区分：
     A 章学到一半退出，点进 B 章时会原样喂回来，把老进度
     (learnRating / effort / graduated …) 套到 B 章的卡上，还强行
     phase = learn —— 结果就是「所有书都跳过篇章」。
     这里用卡 id 有没有交集判：毫无交集 = 脏断点，丢弃重开，
     让 startUnit() 正常走 passage。 */
  function savedBelongsToUnit(sv, u) {
    var cur = {};
    ((u && u.cards) || []).forEach(function (c) { cur[c.id] = 1; });
    var ids = [];
    ["learnRating", "effort"].forEach(function (k) {
      var o = sv[k];
      if (o && typeof o === "object" && !Array.isArray(o)) ids = ids.concat(Object.keys(o));
    });
    ["graduated", "settled", "provisional"].forEach(function (k) {
      var a = sv[k];
      if (Array.isArray(a)) ids = ids.concat(a);
    });
    if (!ids.length) return false;         // 空断点：一点进度都没有，直接重开走篇章
    for (var i = 0; i < ids.length; i++) { if (cur[ids[i]]) return true; }
    return false;                          // 有进度但一张都对不上 = 跨章脏断点
  }

  function restoreSession(sv) {
    var ui = sv.unitIdx || 0;
    /* 收尾阶段：所有单元走完 → 最后一场拼写轮。这时快照里的 unitIdx ==
       units.length（越界），以前的 `ui >= units.length → false` 会把它判成
       脏断点，退出去再进来就从第一单元重来。这一段已经没有「没背完的卡」了
       （拼写轮本身不落 FSRS），所以续 = 本轮结束，别让人白背一遍。 */
    if (ui === S.units.length && (sv.phase === "spell" || sv.phase === "spellPrompt")) {
      S.unitIdx = S.units.length;
      S.unitIds = []; S.unitTotal = 0;
      S.retestPool = [];
      S.graduated = {};
      (sv.graduated || []).forEach(function (id) {
        S.graduated[id] = true;
        _committed[id] = true;
      });
      S.phase = "done";
      log("restore: 收尾拼写轮 → 本轮已结束");
      return true;
    }
    if (ui < 0 || ui >= S.units.length) return false;
    var okUnit = savedBelongsToUnit(sv, S.units[ui]);
    log("restore? unitIdx=" + ui + " savedPhase=" + (sv && sv.phase) + " 同unit=" + okUnit);
    if (!okUnit) return false;
    S.unitIdx = ui;
    S.retestPool = (sv.retestPool || []).filter(function (id) { return !!cardMeta(id); });
    S.effort = sv.effort || {};
    S.learnRating = sv.learnRating || {};
    S.passageTag = sv.passageTag || {};
    S.passedModes = sv.passedModes || {};
    S.retestFailed = sv.retestFailed || {};
    S.wrongCount = sv.wrongCount || {};
    S.graduated = {};
    (sv.graduated || []).forEach(function (id) { S.graduated[id] = true; });
    // 续上的毕业卡上一段会话已 commit 过（FSRS 已落盘）：补进 _committed，
    // 既避免重测时重复 commit，也避免重复记今日背词量。
    (sv.graduated || []).forEach(function (id) { _committed[id] = true; });
    // settled = 已终评但不算背完（封顶放行 / 无考法终评）的卡：FSRS 已落盘，
    // 续会话时同样补进 _committed，别重复提交、也别让它们混进毕业数。
    S.settled = {};
    (sv.settled || sv.provisional || []).forEach(function (id) {
      S.settled[id] = true;
      _committed[id] = true;
    });
    var uu = S.units[S.unitIdx];
    S.unitIds = ((uu && uu.cards) || []).map(function (c) { return c.id; });
    S.unitTotal = S.unitIds.length;
    S.retestPool = S.retestPool.filter(function (id) { return !S.graduated[id]; });
    S.round = Math.max(2, sv.round || 2);
    S.modeIdx = 0;
    if (S.retestPool.length && S.retestModes.length) { startMode(); return true; }
    var u = S.units[S.unitIdx];
    S.queue = ((u && u.cards) || []).filter(function (c) {
      return !S.graduated[c.id];
    }).map(function (c) { return { cardId: c.id, mode: "read", round: 1 }; });
    if (S.queue.length) {
      S.phase = "learn"; S.roundTotal = S.queue.length;
      return true;
    }
    return false;
  }

  function startSession(plan, saved) {
    _committed = {};
    var _c0 = ((plan.units || [])[0] || {}).cards || [];
    log("start units=" + (plan.units || []).length + " retestModes=" + JSON.stringify(plan.retestModes || []) + " card0modes=" + JSON.stringify((_c0[0] || {}).modes || []));
    var _u0 = (plan.units || [])[0] || {};
    log("u0 hasPassage=" + !!_u0.hasPassage + " readFirst=" + !!_u0.readFirst + " passage=" + !!_u0.passage + " segs=" + (((_u0.passage || {}).segments || []).length) + " savedPhase=" + (saved && saved.session && saved.session.phase));
    S = {
      units: plan.units || [],
      retestModes: (function () {
        var rm = (plan.retestModes || []).slice();
        if (rm.indexOf("choice") >= 0 && rm.indexOf("cloze") < 0) rm.push("cloze");
        return rm;
      })(),
      passageCloze: !!plan.passageCloze,
      cardById: {},
      cardIsReview: {},
      unitIdx: 0,
      phase: "done",
      queue: [], retestPool: [], graduated: {}, passedModes: {},
      effort: {}, wrongCount: {},
      passageTag: {}, learnRating: {}, retestFailed: {},
      settled: {},
      unitIds: [], unitTotal: 0,
      round: 1, modeIdx: 0, roundTotal: 0,
      leadingReviewCount: 0,
      reviewSpellDone: false, finalSpellDone: false,
      spellReturnsToUnits: false, spellCards: [], spellDone: 0
    };
    buildIndex();
    var n = 0;
    for (var i = 0; i < S.units.length; i++) { if (!S.units[i].isReview) break; n++; }
    S.leadingReviewCount = n;
    if (!S.units.length) { S.phase = "done"; render(); return; }

    // 接管：评分 / 拼写回报都归本层
    FC.answer = function (r, meta) { onAnswer(r, meta); };
    FC.spellDone = function () { endSpell(); };
    FC.spellProgress = function (d) { if (S) { S.spellDone = d || 0; reportProgress(); } };

    if (saved && saved.session && saved.session.phase &&
        saved.session.phase !== "done" && saved.workflow === WF_NAME) {
      if (restoreSession(saved.session)) {
        reportProgress();
        render();
        return;
      }
    }
    startUnit();
    reportProgress();
    render();
  }

  // 拼写决策 / 结束回调（script.js 调本层）
  FC.onSpellDecision = function (go) {
    if (!S || S.phase !== "spellPrompt") return;
    if (go) beginSpell(); else endSpell();
  };
  FC.onSpellDone = function () { endSpell(); };

  if (FC.on) {
    FC.on("web.start", function () {
      if (!FC.call) return;
      log("web.start -> 拉计划");
      var planP = FC.call("session.plan", {});
      var savedP = null;
      try { savedP = FC.call("session.load", {}); } catch (e) { savedP = null; }
      Promise.all([
        planP,
        savedP ? savedP.catch(function () { return null; }) : Promise.resolve(null)
      ]).then(function (rs) {
        var plan = rs[0], saved = rs[1];
        if (plan && plan.units && plan.units.length !== undefined) startSession(plan, saved);
        else log("web.start：没有计划（非 Web 驱动？）");
      }).catch(function () {});
    });
    // 老路径兼容：壳主动回执
    FC.on("web.spellDecision", function (d) {
      if (!S || S.phase !== "spellPrompt") return;
      if (d && d.go) beginSpell(); else endSpell();
    });
  }

  WF.session = {
    isOn: function () { return !!S; },
    state: function () { return S; },
    onAnswer: onAnswer
  };
})();
