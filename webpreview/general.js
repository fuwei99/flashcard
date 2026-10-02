/* ============================================================================
   webpreview · 通用卡（srs_basic / SM-2）预览壳
   ----------------------------------------------------------------------------
   这个文件的定位：**在浏览器里 1:1 扮演 Flutter 壳**。

   浏览器里没有 Dart，所以壳那一侧（RPC、SM-2 存储、会话计划、进度上报）
   必须有一份 JS 复刻，才能不进 APK 就看见卡片长什么样：

     ┌─────────────── 本文件（扮演壳）───────────────┐
     │  iframe                                        │
     │   ├── 模板 page（= buildPage 拼出来的那坨）    │
     │   │    ├── FCChannel shim  ←── 桥              │
     │   │    ├── window.Flashcard glue（同 Dart 版） │
     │   │    ├── KaTeX / auto-render                 │
     │   │    ├── script.js    （真模板，原样加载）   │
     │   │    └── workflow.js  （真流程，原样加载）   │
     │   └── postMessage ──→ 这里处理 RPC             │
     └────────────────────────────────────────────────┘

   关键：script.js / workflow.js 是**从 templates/ 目录直接读进来的真货**，
   不是复制粘贴。改模板 → 刷页面就生效，不存在两份代码漂移。
   ========================================================================== */
(function () {
  "use strict";

  var TPL_DIR = "../templates/plaincard_v1";
  var DECK = "../decks/general_demo.json";

  var F = null;              // 当前 iframe 的 window
  var book = null, tpl = null;
  var plan = null;
  var doneThisSession = 0;

  var $ = function (id) { return document.getElementById(id); };

  // ---------------------------------------------------------------- 日志
  var logEl = $("log");
  function log(tag, msg) {
    var line = document.createElement("div");
    line.innerHTML = "<b>" + tag + "</b> " + String(msg == null ? "" : msg)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;");
    logEl.appendChild(line);
    logEl.scrollTop = logEl.scrollHeight;
    while (logEl.childNodes.length > 300) logEl.removeChild(logEl.firstChild);
  }
  $("logToggle").onclick = function () { logEl.classList.toggle("on"); };

  // ---------------------------------------------------------------- 存储
  // 对应 Dart 侧的 CardStore（内存 + progress.json）与 StudySettings。
  // 这里退化成一个 localStorage 文档 —— 目录结构、追加日志、compact 都不需要
  // 在浏览器里复刻，那是「可靠性」问题，不是「功能」问题。
  var K = { sm2: "fcpv_sm2_v1", stats: "fcpv_stats_v1", session: "fcpv_session_v1", ui: "fcpv_ui_v1" };

  function lsGet(k, d) { try { var v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  function lsSet(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }

  var db = lsGet(K.sm2, { sm2: {}, kv: {} });
  var stats = lsGet(K.stats, null);
  var sess = lsGet(K.session, null);
  var ui = lsGet(K.ui, { card_limit: 20 });

  function today() { return new Date().toISOString().slice(0, 10); }
  function rollStats() {
    if (!stats || stats.date !== today()) {
      stats = { date: today(), card_done: 0, total_card_done: (stats && stats.total_card_done) || 0 };
      lsSet(K.stats, stats);
    }
  }
  rollStats();
  function saveDb() { lsSet(K.sm2, db); }

  // ---------------------------------------------------------------- 卡索引
  var cardIndex = {};   // id -> fields
  var bookIds = [];     // 顺序

  function indexBook(b) {
    cardIndex = {}; bookIds = [];
    var chs = b.chapters && b.chapters.length
      ? b.chapters
      : [{ chapter_id: "all", title: b.title, cards: b.cards || [] }];
    chs.forEach(function (ch) {
      (ch.cards || []).forEach(function (c) {
        var f = {};
        (b.fields_order || []).forEach(function (k) { if (c[k] !== undefined) f[k] = c[k]; });
        Object.keys(c).forEach(function (k) { if (k !== "id") f[k] = c[k]; });
        cardIndex[c.id] = f;
        bookIds.push(c.id);
      });
    });
  }

  // ---------------------------------------------------------------- SM-2
  function stateOf(id) { return db.sm2[id] ? Sm2.norm(db.sm2[id]) : Sm2.newState(); }
  function isKnown(id) { return db.kv[id] && db.kv[id].known === true; }

  // ---------------------------------------------------------------- RPC
  // 方法名 / 入参 / 返回形状全部对齐 docs/API.md 与 webview_bridge.dart。
  var RPC = {
    ping: function () { return { pong: true }; },

    "session.plan": function () { return plan; },

    "session.save": function (p) {
      sess = { workflow: p.workflow, cursor: p.cursor, session: p.session };
      lsSet(K.session, sess);
      return { ok: true };
    },
    "session.load": function () { return sess || {}; },
    "session.clear": function () { sess = null; lsSet(K.session, null); return { ok: true }; },

    "card.get": function (p) {
      var f = cardIndex[p.id];
      if (!f) return { card: null, engine: "sm2" };
      return {
        engine: "sm2",
        card: { id: p.id, fields: f, engine: "sm2", state: Sm2.toJson(stateOf(p.id)), kv: db.kv[p.id] || {} }
      };
    },

    "card.due": function (p) {
      var now = new Date();
      var out = bookIds.filter(function (id) {
        if (isKnown(id)) return false;
        var st = stateOf(id);
        return st.phase !== "new" && Sm2.isDue(st, now);
      });
      out.sort(function (a, b) {
        return (stateOf(a).due || 0) - (stateOf(b).due || 0);
      });
      return { ids: out, count: out.length };
    },

    "card.new": function (p) {
      var lim = p.limit || 0;
      var out = bookIds.filter(function (id) {
        return !isKnown(id) && stateOf(id).phase === "new";
      });
      return { ids: lim > 0 ? out.slice(0, lim) : out, count: out.length };
    },

    "review.commit": function (p) {
      var st = stateOf(p.id);
      var nxt;
      try {
        nxt = Sm2.review(st, p.rating, new Date(), tpl.srs);
      } catch (e) {
        return { ok: false, id: p.id, engine: "sm2", error: String(e.message || e) };
      }
      db.sm2[p.id] = Sm2.toJson(nxt);
      saveDb();
      return {
        ok: true, id: p.id, engine: "sm2", rating: p.rating,
        state: Sm2.toJson(nxt),
        due_in: nxt.due ? Sm2.formatGap(nxt.due - new Date()) : null
      };
    },

    "review.preview": function (p) {
      var st = p.id && cardIndex[p.id] ? stateOf(p.id) : Sm2.newState();
      return { ok: true, engine: "sm2", phase: st.phase, ratings: Sm2.preview(st, new Date(), tpl.srs) };
    },

    "state.getReview": function (p) {
      var st = stateOf(p.id);
      return {
        ok: true, id: p.id, engine: "sm2",
        is_new: st.phase === "new", is_learned: st.phase !== "new",
        due_now: Sm2.isDue(st, new Date()), known: isKnown(p.id),
        state: Sm2.toJson(st)
      };
    },

    "state.kvGet": function (p) { return db.kv[p.id] || {}; },
    "state.kvPut": function (p) {
      (db.kv[p.id] = db.kv[p.id] || {})[p.key] = p.value;
      saveDb();
      return { ok: true };
    },
    "card.markKnown": function (p) {
      (db.kv[p.id] = db.kv[p.id] || {}).known = p.known !== false;
      saveDb();
      return { ok: true, id: p.id, known: p.known !== false };
    },

    "stats.get": function () {
      rollStats();
      return {
        ok: true,
        today: {
          date: stats.date, card_done: stats.card_done, card_limit: ui.card_limit,
          word_done: 0, word_limit: 20
        },
        card_passed: stats.card_done >= ui.card_limit
      };
    },
    "stats.markDone": function (p) {
      rollStats();
      var n = p.n || 1;
      stats.card_done += n;
      stats.total_card_done = (stats.total_card_done || 0) + n;
      lsSet(K.stats, stats);
      paintToday();
      return { ok: true };
    },

    "book.index": function () {
      return {
        ok: true,
        books: [{
          book_id: book.book_id, title: book.title, template: book.template,
          fields_order: book.fields_order, count: bookIds.length, ids: bookIds,
          chapters: (book.chapters || []).map(function (ch) {
            return { chapter_id: ch.chapter_id, title: ch.title, count: (ch.cards || []).length,
                     ids: (ch.cards || []).map(function (c) { return c.id; }) };
          })
        }]
      };
    },

    // 本地图片 → data-uri。浏览器里没有 Documents/ 目录，只能按相对路径 fetch。
    // 演示卡组用的是内嵌 data-uri，走不到这里；这里保留实现是为了接口完整。
    "media.get": function (p) {
      return fetch(p.path).then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.blob();
      }).then(function (b) {
        return new Promise(function (res) {
          var fr = new FileReader();
          fr.onload = function () { res({ ok: true, path: p.path, data_uri: fr.result }); };
          fr.onerror = function () { res({ ok: false, error: "read failed" }); };
          fr.readAsDataURL(b);
        });
      }).catch(function (e) { return { ok: false, error: String(e) }; });
    },

    "ui.setChrome": function () { return { ok: true }; },
    "ui.getChrome": function () { return { ok: true, top: true }; },
    "sys.log": function (p) { log("sys/" + (p.tag || "log"), p.msg); return { ok: true }; }
  };

  // ---------------------------------------------------------------- 桥
  // 壳 → Web：把一段 JS 丢进 iframe 执行（就是 Dart 侧的 runJavaScript）
  function runJs(code) {
    if (!F) return;
    try { F.eval(code); } catch (e) { log("ERR", "runJavaScript 失败: " + e); }
  }
  function emit(evt, data) {
    runJs("window.Flashcard.__emit(" + JSON.stringify(evt) + "," +
          JSON.stringify(JSON.stringify(data || {})) + ")");
  }

  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || d.__fc !== 1) return;

    var msg;
    try { msg = JSON.parse(d.s); } catch (err) { return; }

    // JS 日志走独立通道，别和切卡时序搅在一起（同 Dart 侧的处理）
    if (msg.type === "log") { log("js/" + (msg.tag || ""), msg.msg); return; }

    if (msg.type === "rpc") {
      var fn = RPC[msg.method];
      var out;
      if (!fn) {
        out = Promise.resolve({ ok: false, error: "no such method: " + msg.method });
      } else {
        try { out = Promise.resolve(fn(msg.params || {})); }
        catch (err) { out = Promise.resolve({ ok: false, error: String(err) }); }
      }
      out.then(function (result) {
        var payload = JSON.stringify({ id: msg.id, ok: true, result: result });
        runJs("window.Flashcard.__resolve('" + payload.replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "')");
      });
      return;
    }

    if (msg.type === "web.progress") {
      $("sbPhase").textContent = msg.phase === "review" ? "复习" : "新学";
      $("sbCnt").textContent = "已背 " + msg.done + " / " + msg.total;
      var p = msg.total > 0 ? msg.done / msg.total : 0;
      $("sbBar").style.width = (p * 100) + "%";
      return;
    }
    if (msg.type === "web.finish") {
      log("shell", "web.finish · 本轮毕业 " + (msg.graduated || 0) + " 张");
      $("doneText").textContent = "本场背完 · 毕业 " + (msg.graduated || 0) + " 张";
      $("done").classList.add("on");
      return;
    }
    log("web→shell", msg.type);
  });

  function paintToday() {
    rollStats();
    $("sbToday").textContent = "今日 " + stats.card_done + " / " + ui.card_limit;
  }

  // ---------------------------------------------------------------- 组装页面
  // TemplateEngine.buildPage 的 JS 镜像。差别只有一处：
  // 真实壳把 KaTeX **内联**进 HTML（因为 loadHtmlString 没有 baseUrl），
  // 这里用 <link>/<script src> 引同一份 vendor 文件 —— 路径解析得动，
  // 而且改 vendor 不用重跑 Dart。
  function buildPage() {
    var glue = sandboxGlue();
    return "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\">" +
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1," +
      "user-scalable=no,viewport-fit=cover\">" +
      "<link rel=\"stylesheet\" href=\"" + TPL_DIR + "/vendor/katex.css\">" +
      "</head><body>" +
      tpl.html +
      "<script>" + shim() + "<\/script>" +
      "<script>" + glue + "<\/script>" +
      "<script src=\"" + TPL_DIR + "/vendor/katex.min.js\"><\/script>" +
      "<script src=\"" + TPL_DIR + "/vendor/auto-render.min.js\"><\/script>" +
      "<script>" + tpl.js + "<\/script>" +
      "<script>" + tpl.workflow + "<\/script>" +
      "</body></html>";
  }

  /** FCChannel：iframe 里的“壳通道”。只做一件事 —— 把消息丢给 parent。 */
  function shim() {
    return "(function(){" +
      "window.FCChannel={postMessage:function(s){parent.postMessage({__fc:1,s:String(s)},'*');}};" +
      "window.addEventListener('message',function(e){var d=e.data;" +
      "if(!d||d.__fc!==1||d.k!=='js')return;" +
      "try{(new Function(d.code))();}catch(err){console.error('eval fail',err);}});" +
      "})();";
  }

  /** window.Flashcard glue —— 逐字对齐 template_engine.dart 里注入的那份。 */
  function sandboxGlue() {
    return [
      "(function(){",
      "var ch=(typeof FCChannel!=='undefined')?FCChannel:null;",
      "function post(obj){if(ch)ch.postMessage(JSON.stringify(obj));}",
      "var seq=0,pending={},listeners={};",
      "function call(method,params){return new Promise(function(resolve,reject){",
      "  if(!ch){reject(new Error('no channel'));return;}",
      "  var id=++seq;pending[id]={resolve:resolve,reject:reject};",
      "  post({type:'rpc',id:id,method:method,params:params||{}});});}",
      "function on(evt,fn){(listeners[evt]=listeners[evt]||[]).push(fn);}",
      "window.Flashcard={",
      "  getCard:function(){return window.__FLASHCARD_CARD__;},",
      "  answer:function(r){post({type:'answer',rating:r});},",
      "  tts:function(t,o){if(o==null||typeof o==='string'){post({type:'tts',text:t,lang:o||'en-US'});}",
      "    else{post(Object.assign({type:'tts',text:t},o));}},",
      "  ttsSeq:function(l){post({type:'ttsSeq',items:l||[]});},",
      "  ttsStop:function(){post({type:'ttsStop'});},",
      "  getState:function(k){return (window.__FLASHCARD_KV__||{})[k];},",
      "  setState:function(k,v){window.__FLASHCARD_KV__[k]=v;post({type:'setState',key:k,value:v});},",
      "  log:function(tag,msg){post({type:'log',tag:String(tag==null?'js':tag),msg:String(msg==null?'':msg)});},",
      "  post:function(type,data){var o={type:type};if(data){for(var k in data){",
      "    if(Object.prototype.hasOwnProperty.call(data,k))o[k]=data[k];}}post(o);},",
      "  call:call,on:on,",
      "  __resolve:function(s){var m;try{m=JSON.parse(s);}catch(e){return;}",
      "    var p=pending[m.id];if(!p)return;delete pending[m.id];",
      "    if(m.ok)p.resolve(m.result);else p.reject(new Error((m.result&&m.result.error)||'rpc error'));},",
      "  __emit:function(evt,s){var ls=listeners[evt];if(!ls)return;var d={};",
      "    if(s){try{d=JSON.parse(s);}catch(e){}}",
      "    for(var i=0;i<ls.length;i++){try{ls[i](d);}catch(e){}}}",
      "};})();"
    ].join("\n");
  }

  // ---------------------------------------------------------------- 启动
  var iframe = $("card");

  function boot() {
    $("done").classList.remove("on");
    $("sbBar").style.width = "0%";
    $("sbCnt").textContent = "已背 0 / 0";
    iframe.srcdoc = buildPage();
  }

  iframe.addEventListener("load", function () {
    F = iframe.contentWindow;
    if (!F || !F.Flashcard) {
      log("ERR", "iframe 里没有 window.Flashcard —— 页面没组装对");
      return;
    }
    // 等价于 Dart 侧 onPageFinished → emit('web.start')
    setTimeout(function () {
      log("shell", "web.start → 交给 workflow.js");
      emit("web.start");
    }, 30);
  });

  Promise.all([
    fetch(DECK).then(function (r) { return r.json(); }),
    fetch(TPL_DIR + "/manifest.json").then(function (r) { return r.json(); }),
    fetch(TPL_DIR + "/template.html").then(function (r) { return r.text(); }),
    fetch(TPL_DIR + "/style.css").then(function (r) { return r.text(); }),
    fetch(TPL_DIR + "/script.js").then(function (r) { return r.text(); }),
    fetch(TPL_DIR + "/workflow.js").then(function (r) { return r.text(); })
  ]).then(function (r) {
    book = r[0];
    tpl = {
      manifest: r[1], html: r[2], css: r[3], js: r[4], workflow: r[5],
      srs: r[1].srs || null
    };
    indexBook(book);

    // 模板的 style.css 在这里注入到**外层**文档吗？不行 ——
    // 卡片的样式归 iframe 里的页面。这里只把 title / 今日 画好。
    $("sbTitle").textContent = book.title;
    document.title = "flashcard · " + book.title;
    plan = {
      book: book.book_id,
      title: book.title,
      engine: "sm2",
      mode: "learn",
      units: []
    };
    paintToday();
    log("shell", "已载入《" + book.title + "》" + bookIds.length + " 张卡，模板 " + tpl.manifest.id);
    boot();
  }).catch(function (e) {
    log("ERR", "加载失败: " + e +
        "　—— 需要用静态服务打开：python3 -m http.server 8080");
  });

  $("again").onclick = function () {
    sess = null; lsSet(K.session, null);
    boot();
  };

  // 进后台/切走的等价物：真实壳在 lifecycle.pause 时会通知模板落断点
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") emit("lifecycle.pause");
  });
})();
