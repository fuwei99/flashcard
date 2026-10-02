/* ============================================================================
   SM-2 variant —— scheduler_sm2.dart 的 1:1 JS 镜像
   ----------------------------------------------------------------------------
   两份必须同步改：
     app/lib/services/scheduler_sm2.dart   ← 生产（Flutter 壳）
     webpreview/sm2.js                     ← 预览壳（浏览器 1:1 模拟）
   改动任何一边，另一边要跑 `node webpreview/sm2_test.js` 对齐。

   为什么预览壳要自己实现一份调度：预览壳的定位是「在浏览器里 1:1 模拟
   原生壳的 API」。原生那边跑的是 Dart，浏览器里没有 Dart，所以算法必须
   有一份 JS。这跟 FSRS-lite 在 app.js 里也有一份是同一回事。
   ============================================================================ */
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.Sm2 = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var RATING = { again: 1, hard: 2, good: 3, easy: 4 };
  var KEYS = ["again", "hard", "good", "easy"];

  var DEFAULTS = {
    learning_steps: [1, 10],
    relearning_steps: [10],
    graduating_interval: 1,
    easy_interval: 4,
    starting_ease: 2.5,
    min_ease: 1.3,
    easy_bonus: 1.3,
    hard_factor: 1.2,
    interval_modifier: 1.0,
    max_interval: 36500,
    lapse_multiplier: 0.0
  };

  function params(p) {
    var out = {};
    for (var k in DEFAULTS) out[k] = DEFAULTS[k];
    if (p) for (var k2 in p) if (p[k2] !== undefined && p[k2] !== null) out[k2] = p[k2];
    // 空数组兜底：steps 全空会让学习步死循环
    if (!out.learning_steps || !out.learning_steps.length) out.learning_steps = DEFAULTS.learning_steps;
    if (!out.relearning_steps || !out.relearning_steps.length) out.relearning_steps = DEFAULTS.relearning_steps;
    return out;
  }

  function clamp(x, a, b) { return Math.max(a, Math.min(b, x)); }
  function clampi(x, a, b) { return Math.max(a, Math.min(b, Math.round(x))); }
  function iso(d) { return d.toISOString(); }
  function addMin(t, m) { return new Date(t.getTime() + m * 60000); }
  function addDay(t, d) { return new Date(t.getTime() + d * 86400000); }

  function newState() {
    return { phase: "new", step: 0, ease: 2.5, interval: 0, due: null,
             reps: 0, lapses: 0, last_review: null };
  }

  /** 容错读盘：坏字段退回默认值，不让一行脏 json 把整本书读崩 */
  function norm(st) {
    var s = newState();
    if (!st) return s;
    s.phase = st.phase || "new";
    s.step = st.step | 0;
    s.ease = typeof st.ease === "number" ? st.ease : 2.5;
    s.interval = st.interval | 0;
    s.due = st.due ? new Date(st.due) : null;
    s.reps = st.reps | 0;
    s.lapses = st.lapses | 0;
    s.last_review = st.last_review ? new Date(st.last_review) : null;
    return s;
  }

  function clone(s) {
    return { phase: s.phase, step: s.step, ease: s.ease, interval: s.interval,
             due: s.due ? new Date(s.due.getTime()) : null,
             reps: s.reps, lapses: s.lapses,
             last_review: s.last_review ? new Date(s.last_review.getTime()) : null };
  }

  function isDue(st, now) {
    if (!st || st.phase === "new") return false;
    if (!st.due) return true;
    return st.due.getTime() <= (now || new Date()).getTime();
  }

  function graduate(st, days, t, p) {
    st.phase = "review";
    st.step = 0;
    st.interval = clampi(days * p.interval_modifier, 1, p.max_interval);
    st.due = addDay(t, st.interval);
  }

  function enterFromNew(st, r, t, p) {
    if (r === 4) { graduate(st, p.easy_interval, t, p); return; }
    if (r === 3) {
      if (p.learning_steps.length <= 1) graduate(st, p.graduating_interval, t, p);
      else { st.phase = "learn"; st.step = 1; st.due = addMin(t, p.learning_steps[1]); }
      return;
    }
    if (r === 2) {
      st.phase = "learn"; st.step = 0;
      st.due = addMin(t, p.learning_steps[0]);
      return;
    }
    st.phase = "learn"; st.step = 0; st.due = addMin(t, p.learning_steps[0]);
  }

  function stepThrough(st, r, t, p, steps) {
    var last = clamp(st.step | 0, 0, steps.length - 1);
    if (r === 1) { st.step = 0; st.due = addMin(t, steps[0]); return; }
    if (r === 2) { st.step = last; st.due = addMin(t, steps[last]); return; }
    if (r === 3) {
      var nxt = last + 1;
      if (nxt >= steps.length) graduate(st, st.interval > 0 ? st.interval : p.graduating_interval, t, p);
      else { st.step = nxt; st.due = addMin(t, steps[nxt]); }
      return;
    }
    graduate(st, p.easy_interval, t, p);
  }

  function reviewStep(st, r, t, p) {
    var ivl = st.interval <= 0 ? 1 : st.interval;
    if (r === 1) {
      st.lapses += 1;
      st.ease = clamp(st.ease - 0.20, p.min_ease, 5.0);
      st.phase = "relearn"; st.step = 0;
      st.interval = clampi(ivl * p.lapse_multiplier, 1, p.max_interval);
      st.due = addMin(t, p.relearning_steps[0]);
      return;
    }
    if (r === 2) {
      st.ease = clamp(st.ease - 0.15, p.min_ease, 5.0);
      st.interval = clampi(Math.max(ivl + 1, Math.round(ivl * p.hard_factor * p.interval_modifier)), 1, p.max_interval);
      st.due = addDay(t, st.interval);
      return;
    }
    if (r === 3) {
      st.interval = clampi(Math.round(ivl * st.ease * p.interval_modifier), 1, p.max_interval);
      st.due = addDay(t, st.interval);
      return;
    }
    st.ease = clamp(st.ease + 0.15, p.min_ease, 5.0);
    st.interval = clampi(Math.round(ivl * st.ease * p.easy_bonus * p.interval_modifier), 1, p.max_interval);
    st.due = addDay(t, st.interval);
  }

  function review(card, ratingKey, now, rawParams) {
    var r = typeof ratingKey === "number" ? ratingKey : RATING[String(ratingKey).toLowerCase()];
    if (!r) throw new Error("非法评分: " + ratingKey);
    var p = params(rawParams);
    var t = now || new Date();
    var st = clone(norm(card));
    st.last_review = t;
    st.reps += 1;

    if (st.phase === "new") { st.ease = p.starting_ease; enterFromNew(st, r, t, p); }
    else if (st.phase === "learn" || st.phase === "relearn") {
      stepThrough(st, r, t, p, st.phase === "learn" ? p.learning_steps : p.relearning_steps);
    } else if (st.phase === "review") { reviewStep(st, r, t, p); }
    else { st.phase = "new"; st.ease = p.starting_ease; enterFromNew(st, r, t, p); }

    return st;
  }

  function formatGap(ms) {
    var m = Math.floor(ms / 60000);
    if (m < 1) return "1 分内";
    if (m < 60) return m + " 分";
    var h = Math.floor(m / 60);
    if (h < 24) return h + " 小时";
    var d = Math.floor(h / 24);
    if (d < 30) return d + " 天";
    if (d < 365) { var mo = d / 30; return (mo < 10 ? mo.toFixed(1) : Math.round(mo)) + " 个月"; }
    var y = d / 365;
    return (y < 10 ? y.toFixed(1) : Math.round(y)) + " 年";
  }

  /** 四档的下次间隔预览：按钮上的小字 */
  function preview(card, now, rawParams) {
    var t = now || new Date();
    var out = {};
    for (var i = 0; i < KEYS.length; i++) {
      var n = review(card, KEYS[i], t, rawParams);
      out[KEYS[i]] = n.due ? formatGap(n.due.getTime() - t.getTime()) : "-";
    }
    return out;
  }

  /** 到期优先、新卡殿后的队列 */
  function queue(ids, stateOf, isKnown, now) {
    var t = now || new Date();
    var due = [], fresh = [];
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i];
      if (isKnown && isKnown(id)) continue;
      var st = norm(stateOf(id));
      if (st.phase === "new") fresh.push(id);
      else if (isDue(st, t)) due.push(id);
    }
    due.sort(function (a, b) {
      var da = norm(stateOf(a)).due, db = norm(stateOf(b)).due;
      if (!da && !db) return 0;
      if (!da) return -1;
      if (!db) return 1;
      return da - db;
    });
    return due.concat(fresh);
  }

  return {
    RATING: RATING, KEYS: KEYS, DEFAULTS: DEFAULTS,
    newState: newState, norm: norm, isDue: isDue, review: review,
    preview: preview, queue: queue, formatGap: formatGap, params: params,
    toJson: function (s) {
      return {
        phase: s.phase, step: s.step,
        ease: Math.round(s.ease * 10000) / 10000,
        interval: s.interval,
        due: s.due ? iso(s.due) : null,
        reps: s.reps, lapses: s.lapses,
        last_review: s.last_review ? iso(s.last_review) : null
      };
    }
  };
});
