/* ============================================================================
   plaincard_v1 · 流程层（司机）
   ----------------------------------------------------------------------------
   壳在 `web_session: true` 时**不排课、不挂卡、不推进**，只执行模板发来的指令。
   所以这个文件是这张卡的「大脑」：

     排队    card.due（到期，分钟粒度）→ card.new（新卡，按今日剩余额度截断）
     出牌    card.get 取字段 → PC.mount 渲染
     预览    review.preview 把四档的下次间隔写成按钮小字
     交卷    review.commit（四档 → SM-2）→ stats.markDone 记今日
     重排    「重来」的卡按学习步塞回队尾（本场再见一次）
     收尾    web.progress / web.finish / session.save 断点

   这套写法就是「壳不过度介入」的样子：壳一行不知道什么是问答、什么是挖空，
   卡片想怎么考就怎么考；反过来模板也一行不碰存储和调度，全走 RPC。
   ========================================================================== */
(function () {
  "use strict";

  var F = window.Flashcard;
  var WORKFLOW = "plaincard_v1";
  var CARD = "pc/workflow";

  /** 一张卡本场最多被「重来」多少次，防死循环（学习步很短的卡会反复回队） */
  var MAX_REQUEUE = 3;

  var S = {
    book: "",
    engine: "sm2",
    mode: "learn",
    math: null,       // manifest.math：公式定界符（壳从 plan 里递过来）
    queue: [],
    idx: 0,
    done: 0,
    total: 0,
    graduated: 0,
    counted: {},    // id -> true：本场是否已计入今日背词量
    requeued: {},   // id -> 次数
    busy: false,
    started: false
  };

  function log(msg) {
    try { F.log(CARD, msg); } catch (e) {}
  }

  // ------------------------------------------------------------ 进度上报

  function report() {
    F.post("web.progress", {
      phase: S.mode,
      done: S.done,
      total: S.total,
      graduated: S.graduated
    });
  }

  function save() {
    var pending = S.queue.slice(S.idx);
    return F.call("session.save", {
      workflow: WORKFLOW,
      session: { book: S.book, mode: S.mode },
      cursor: {
        pending: pending,
        done: S.done,
        total: S.total,
        graduated: S.graduated,
        counted: Object.keys(S.counted),
        requeued: S.requeued
      }
    }).catch(function () {});
  }

  // ------------------------------------------------------------ 排队

  function buildQueue(plan) {
    plan = plan || {};
    S.book = plan.book || S.book || "";
    S.engine = plan.engine || S.engine || "sm2";
    S.mode = plan.mode === "review" ? "review" : "learn";

    var dueReq = F.call("card.due", { book: S.book, engine: S.engine });
    var newReq = Promise.resolve({ ids: [] });

    if (S.mode !== "review") {
      // 今日还能塞几张新卡 = 每日上限 − 今天已背。壳不替我们判这个，
      // 因为「今天算多少个」是流程问题，只有模板知道自己要推多少。
      newReq = F.call("stats.get", {}).then(function (s) {
        var t = (s && s.today) || {};
        var limit = t.card_limit || 20;
        var done = t.card_done || 0;
        var room = Math.max(0, limit - done);
        if (room <= 0) return { ids: [] };
        return F.call("card.new", { book: S.book, engine: S.engine, limit: room });
      }).catch(function () { return { ids: [] }; });
    }

    return Promise.all([dueReq, newReq]).then(function (r) {
      var due = (r[0] && r[0].ids) || [];
      var fresh = (r[1] && r[1].ids) || [];
      log("排队 book=" + S.book + " mode=" + S.mode +
          " 到期=" + due.length + " 新卡=" + fresh.length);
      return due.concat(fresh);
    });
  }

  // ------------------------------------------------------------ 出牌

  function showTop() {
    var id = S.queue[S.idx];
    if (!id) return finish();

    S.busy = true;
    F.call("card.get", { id: id, engine: S.engine }).then(function (res) {
      var c = res && res.card;
      if (!c) {
        log("card.get 取不到 " + id + "（跳过）");
        S.idx++;
        S.busy = false;
        return showTop();
      }

      var ctx = {
        book: S.book,
        engine: S.engine,
        scene: S.mode,
        index: S.idx,
        total: S.total,
        math: S.math
      };
      var st = PC.mount(c, ctx);
      log("挂卡 " + id + " type=" + (st && st.type) + " 公式=" + (st && st.math));

      report();

      // 四档间隔预览：算不动就算了，按钮上没小字不影响交卷
      F.call("review.preview", { id: id, engine: S.engine }).then(function (p) {
        if (p && p.ratings) PC.setPreview(p.ratings);
        else PC.setPreview(null);
      }).catch(function () { PC.setPreview(null); });

      PC.lock(false);
      S.busy = false;
    }).catch(function (e) {
      log("card.get 异常 " + id + " → " + e);
      S.busy = false;
      S.idx++;
      showTop();
    });
  }

  function next() {
    S.idx++;
    if (S.idx >= S.queue.length) return finish();
    save();
    showTop();
  }

  // ------------------------------------------------------------ 交卷

  function rate(rating) {
    if (S.busy) return;
    var id = S.queue[S.idx];
    if (!id) return;
    S.busy = true;
    PC.lock(true);

    F.call("review.commit", { id: id, rating: rating, engine: S.engine })
      .then(function (res) {
        if (!res || !res.ok) {
          // 非法评分 / 缺 id：宁可停住让人看见，也不要静默当「良好」写进调度
          log("commit 失败: " + (res && res.error));
          S.busy = false;
          PC.lock(false);
          return;
        }
        log("交卷 " + id + " → " + rating + " due_in=" + (res.due_in || "-"));

        if (rating !== "again" && !S.counted[id]) {
          S.counted[id] = true;
          S.done++;
          F.call("stats.markDone", { n: 1 }).catch(function () {});
        }
        if (rating !== "again") S.graduated++;

        // 「重来」→ 学习步里 1~10 分钟后要再见一次，直接塞回队尾。
        // 现实里不会真的等 10 分钟，那就在本场尾巴上再见 —— 这跟 Anki
        // 「学习中的卡留在本场轮次里」是一个意思。
        var again = rating === "again" || res.state.phase === "relearn";
        if (again && (S.requeued[id] || 0) < MAX_REQUEUE) {
          S.requeued[id] = (S.requeued[id] || 0) + 1;
          S.queue.push(id);
          S.total = S.queue.length;
          log("回队尾 " + id + "（第 " + S.requeued[id] + " 次）");
        }

        report();
        S.busy = false;
        next();
      })
      .catch(function (e) {
        log("commit 异常 " + id + " → " + e);
        S.busy = false;
        PC.lock(false);
      });
  }

  // ------------------------------------------------------------ 收尾

  function finish() {
    S.started = false;
    F.post("web.finish", { graduated: S.graduated });
    log("本场结束 交了 " + S.done + " 张（含重排共 " + S.total + "）");
    F.call("session.clear", {}).catch(function () {});
  }

  // ------------------------------------------------------------ 启动

  function resumeOrBuild(plan) {
    return F.call("session.load", {}).then(function (saved) {
      var cur = saved && saved.cursor;
      var ses = saved && saved.session;
      var ok = saved && saved.workflow === WORKFLOW &&
               ses && ses.book === S.book &&
               cur && cur.pending instanceof Array && cur.pending.length;

      // 断点只认「同一本书」的：换书了还接着上一本的队列 = 鬼故事
      if (!ok) return buildQueue(plan);

      log("续上断点：还剩 " + cur.pending.length + " 张");
      S.mode = ses.mode || S.mode;
      S.done = cur.done || 0;
      S.total = cur.total || cur.pending.length;
      S.graduated = cur.graduated || 0;
      S.requeued = cur.requeued || {};
      (cur.counted || []).forEach(function (id) { S.counted[id] = true; });
      return cur.pending.slice();
    }).catch(function () { return buildQueue(plan); });
  }

  function start() {
    if (S.started) return;
    S.started = true;

    // plan 是壳给的「这一场是什么」：哪本书、哪套引擎、复习还是新学。
    // srs_basic 的模板拿它定身份，但**不拿它排队** —— 队列归这里。
    F.call("session.plan", {}).then(function (plan) {
      plan = plan || {};
      S.book = plan.book || "";
      S.engine = plan.engine || "sm2";
      S.mode = plan.mode === "review" ? "review" : "learn";
      S.math = plan.math || null;

      return resumeOrBuild(plan).then(function (q) {
        S.queue = q || [];
        S.idx = 0;
        S.total = S.queue.length;
        report();

        if (!S.total) {
          log("没有要背的卡（到期 0 / 新卡 0）");
          return finish();
        }
        showTop();
      });
    }).catch(function (e) {
      log("启动失败: " + e);
      F.post("web.finish", { graduated: 0 });
    });
  }

  // ------------------------------------------------------------ 接线

  PC.onRate(rate);

  F.on("web.start", function () { start(); });

  // 进后台立刻落断点：Android 杀后台不打招呼，晚了就白背
  F.on("lifecycle.pause", function () { save(); });

  // 会话正常结束时断点也留着（下次进来还能接着背），清断点在 finish 里做。
  log("workflow 就绪");
})();
