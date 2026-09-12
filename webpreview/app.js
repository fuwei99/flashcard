/* ============================================================================
   flashcard · 分层书架预览
   书架 -> 书 -> 章 -> 页 -> 背诵
   ============================================================================ */
(function () {
  "use strict";

  /* ---------- 迷你模板引擎 ---------- */
  function truthy(v) {
    if (v === null || v === undefined) return false;
    if (typeof v === "string") return v.trim() !== "";
    if (Array.isArray(v)) return v.length > 0;
    if (typeof v === "object") return Object.keys(v).length > 0;
    return !!v;
  }
  function renderTpl(tpl, data) {
    var prev;
    do {
      prev = tpl;
      tpl = tpl.replace(/\{\{([#^])(\w+)\}\}([\s\S]*?)\{\{\/\2\}\}/g,
        function (_, sign, name, body) {
          var t = truthy(data[name]);
          return sign === "#" ? (t ? body : "") : (t ? "" : body);
        });
    } while (tpl !== prev);
    return tpl.replace(/\{\{(\w+)\}\}/g, function (_, name) {
      var v = data[name];
      if (v === null || v === undefined || typeof v === "object") return "";
      return String(v);
    });
  }

  /* ---------- FSRS-lite ---------- */
  var W = [0.4872,1.4003,3.7145,13.8206,5.1618,1.2290,0.8975,0.0310,
           1.6474,0.1367,1.0461,2.1072,0.0793,0.3246,1.5870,0.2272,2.8755];
  var RET = 0.90, DECAY = -0.5, FACTOR = Math.pow(0.9, 1/DECAY) - 1;
  var RATING = { again: 1, hard: 2, good: 3 };
  var LEARNING_INTERVAL = 1;

  function clamp(x,a,b){ return Math.max(a, Math.min(b, x)); }
  function forgettingCurve(t,s){ return s<=0?0:Math.pow(1+FACTOR*t/s, DECAY); }
  function nextInterval(s){
    var ivl = s / FACTOR * (Math.pow(RET,1/DECAY) - 1);
    return Math.max(1, Math.min(365, Math.round(ivl)));
  }
  function initStability(r){ return Math.max(0.1, W[r-1]); }
  function initDifficulty(r){ return clamp(W[4]-(r-3)*W[5],1,10); }
  function nextDifficulty(d,r){
    var nd = d - W[6]*(r-3);
    nd = W[7]*initDifficulty(3) + (1-W[7])*nd;
    return clamp(nd,1,10);
  }
  function stabRecall(d,s,r,rating){
    var hp = rating===2?W[15]:1, eb = 1;
    var inc = Math.exp(W[8])*(11-d)*Math.pow(s,-W[9])*(Math.exp((1-r)*W[10])-1)*hp*eb;
    return Math.max(0.1, s*(1+inc));
  }
  function stabForget(d,s,r){
    var smin = s/Math.exp(2);
    var ns = W[11]*Math.pow(d,-W[12])*(Math.pow(s+1,W[13])-1)*Math.exp((1-r)*W[14]);
    return Math.max(0.1, Math.min(ns, smin));
  }
  function daysBetween(a,b){ return Math.max(0, Math.round((new Date(b)-new Date(a))/86400000)); }
  function todayStr(){ var d=new Date(); return d.toISOString().slice(0,10); }
  function addDays(s,n){ var d=new Date(s); d.setDate(d.getDate()+n); return d.toISOString().slice(0,10); }

  function reviewCard(state, ratingName, today) {
    var rating = RATING[ratingName];
    today = today || todayStr();
    var st = Object.assign(
      {stability:0,difficulty:0,reps:0,lapses:0,due:"",last_review:"",state:"new"},
      state || {});
    var ivl, elapsed, r;
    if (st.state === "new") {
      st.stability = initStability(rating);
      st.difficulty = initDifficulty(rating);
      st.state = "learning"; ivl = LEARNING_INTERVAL;
    } else if (st.state === "learning" || st.state === "relearning") {
      elapsed = daysBetween(st.last_review || today, today);
      r = st.stability > 0 ? forgettingCurve(elapsed, st.stability) : 0;
      if (rating === 1) {
        st.stability = stabForget(st.difficulty, st.stability, r);
        st.lapses++; st.state = "relearning"; ivl = LEARNING_INTERVAL;
      } else {
        st.stability = stabRecall(st.difficulty, st.stability, r, rating);
        st.state = "review"; ivl = nextInterval(st.stability);
      }
      st.difficulty = nextDifficulty(st.difficulty, rating);
    } else {
      elapsed = daysBetween(st.last_review || today, today);
      r = forgettingCurve(elapsed, st.stability);
      if (rating === 1) {
        st.stability = stabForget(st.difficulty, st.stability, r);
        st.lapses++; st.state = "relearning"; ivl = LEARNING_INTERVAL;
      } else {
        st.stability = stabRecall(st.difficulty, st.stability, r, rating);
        st.state = "review"; ivl = nextInterval(st.stability);
      }
      st.difficulty = nextDifficulty(st.difficulty, rating);
    }
    st.reps++; st.last_review = today; st.due = addDays(today, ivl);
    return st;
  }

  /* ---------- 存储 ---------- */
  var LS_STATES = "fc_card_states_v1";
  var LS_SET = "fc_settings_v1";
  var LS_TODAY = "fc_today_v1";
  function lsGet(k, dflt){ try{ var v=localStorage.getItem(k); return v?JSON.parse(v):dflt; }catch(e){ return dflt; } }
  function lsSet(k,v){ localStorage.setItem(k, JSON.stringify(v)); }

  var states = lsGet(LS_STATES, {});
  var settings = lsGet(LS_SET, { dailyLimit: 20 });
  var today = lsGet(LS_TODAY, { date: todayStr(), done: 0 });
  if (today.date !== todayStr()) { today = { date: todayStr(), done: 0 }; lsSet(LS_TODAY, today); }

  function saveStates(){ lsSet(LS_STATES, states); }
  function saveSettings(){ lsSet(LS_SET, settings); }
  function saveToday(){ lsSet(LS_TODAY, today); }

  /* ---------- 全局状态 ---------- */
  var book = null, template = null, currentChapter = null;
  var queue = [], qIdx = 0, orderShuffle = false;
  var $view = document.getElementById("view");
  var $title = document.getElementById("pageTitle");
  var $todayTxt = document.getElementById("todayTxt");
  var $todayBar = document.getElementById("todayBar");
  var $review = document.getElementById("reviewView");
  var $cardHost = document.getElementById("cardHost");

  /* ---------- 工具 ---------- */
  function el(html){ var d=document.createElement("div"); d.innerHTML=html.trim(); return d.firstChild; }
  function learnedCount(cards){
    return cards.filter(function(c){ var s=states[c.word]; return s && s.state && s.state!=="new"; }).length;
  }
  function allCardsOfBook(b){
    if (b.chapters && b.chapters.length) {
      var out=[]; b.chapters.forEach(function(ch){ out=out.concat(ch.cards); }); return out;
    }
    return b.cards || [];
  }
  function updateTodayBar(){
    $todayTxt.textContent = today.done + " / " + settings.dailyLimit;
    var p = settings.dailyLimit>0 ? Math.min(1, today.done/settings.dailyLimit) : 0;
    $todayBar.style.width = (p*100) + "%";
    document.getElementById("revToday").textContent = "今日 " + today.done + " / " + settings.dailyLimit;
  }

  /* ---------- 视图：书架 ---------- */
  function showShelf(){
    $title.textContent = "书架";
    $review.classList.remove("on");
    var cards = allCardsOfBook(book);
    var learned = learnedCount(cards);
    var total = cards.length;
    var p = total? learned/total : 0;
    $view.innerHTML = "";
    var node = el(
      '<div class="book">' +
        '<div class="spine">📖</div>' +
        '<div class="meta">' +
          '<div class="t">'+book.title+'</div>' +
          '<div class="s">'+(book.chapters&&book.chapters.length ? book.chapters.length+" 章 · 共 "+total+" 页" : "共 "+total+" 页")+'</div>' +
          '<div class="p"><i style="width:'+(p*100)+'%"></i></div>' +
          '<div class="c">已背 '+learned+' / '+total+'</div>' +
        '</div>' +
        '<div class="chev">›</div>' +
      '</div>'
    );
    node.onclick = function(){ showBook(); };
    $view.appendChild(node);
  }

  /* ---------- 视图：书内（章节 or 页面） ---------- */
  function showBook(){
    $review.classList.remove("on");
    if (book.chapters && book.chapters.length) {
      $title.textContent = book.title;
      $view.innerHTML = "";
      book.chapters.forEach(function(ch){
        var learned = learnedCount(ch.cards);
        var total = ch.cards.length;
        var p = total? learned/total : 0;
        var node = el(
          '<div class="chapter">' +
            '<div class="ico">📁</div>' +
            '<div class="m">' +
              '<div class="t">'+ch.title+'</div>' +
              '<div class="s">'+total+' 页 · 已背 '+learned+'</div>' +
              '<div class="p"><i style="width:'+(p*100)+'%"></i></div>' +
            '</div>' +
            '<div class="chev">›</div>' +
          '</div>'
        );
        node.onclick = function(){ currentChapter = ch; showPages(ch.title, ch.cards); };
        $view.appendChild(node);
      });
    } else {
      showPages(book.title, book.cards || []);
    }
  }

  /* ---------- 视图：页面列表 ---------- */
  function showPages(title, cards){
    $review.classList.remove("on");
    $title.textContent = title;
    $view.innerHTML = "";

    var back = el('<div class="backbar"><span class="a">←</span> 返回</div>');
    back.onclick = function(){
      if (book.chapters && book.chapters.length) { currentChapter=null; showBook(); }
      else showShelf();
    };
    $view.appendChild(back);

    var bar = el(
      '<div class="startbar">' +
        '<button id="btnSeq">▤ 顺序背诵</button>' +
        '<button id="btnShuf">🔀 乱序背诵</button>' +
      '</div>'
    );
    $view.appendChild(bar);

    cards.forEach(function(c, i){
      var s = states[c.word];
      var on = s && s.state && s.state!=="new";
      var ph = (c.phonetic_us || "");
      var node = el(
        '<div class="page">' +
          '<div class="n">'+(i+1)+'</div>' +
          '<div class="m"><div class="w">'+c.word+'</div>' +
          (ph?'<div class="ph">'+ph+'</div>':'')+'</div>' +
          '<div class="dot'+(on?" on":"")+'"></div>' +
        '</div>'
      );
      $view.appendChild(node);
    });

    bar.querySelector("#btnSeq").onclick = function(){ startReview(title, cards, false); };
    bar.querySelector("#btnShuf").onclick = function(){ startReview(title, cards, true); };
  }

  /* ---------- 视图：背诵 ---------- */
  function startReview(title, cards, shuffle){
    queue = cards.slice();
    if (shuffle) {
      for (var i=queue.length-1;i>0;i--){ var j=Math.floor(Math.random()*(i+1)); var t=queue[i]; queue[i]=queue[j]; queue[j]=t; }
    }
    qIdx = 0;
    document.getElementById("revTitle").textContent = title;
    $review.classList.add("on");
    renderCard();
  }

  function renderCard(){
    updateTodayBar();
    var total = queue.length;
    document.getElementById("revCnt").textContent = "已背 " + qIdx + " / " + total;
    document.getElementById("revBar").style.width = (total? qIdx/total*100 : 0) + "%";

    if (qIdx >= total) {
      $cardHost.innerHTML = '<div style="display:flex;height:100%;align-items:center;' +
        'justify-content:center;flex-direction:column;gap:14px;color:#8c9da2">' +
        '<div style="font-size:40px">🎉</div><div>本组背完</div></div>';
      return;
    }

    var card = queue[qIdx];
    var fields = {};
    (book.fields_order||[]).forEach(function(f){ fields[f] = card[f] || ""; });
    Object.keys(card).forEach(function(k){ if(k!=="word"||true) fields[k]=card[k]; });

    var html = renderTpl(template.html, fields);
    $cardHost.innerHTML = html;

    // 注入 API 后重新执行模板 script.js
    window.__FLASHCARD_CARD__ = {
      id: card.word, fields: fields,
      state: states[card.word] || {state:"new",reps:0},
      index: qIdx, total: total
    };
    var s = document.createElement("script");
    s.textContent = template.js;
    $cardHost.appendChild(s);
  }

  /* ---------- Flashcard API（预览壳版） ---------- */
  window.Flashcard = {
    getCard: function(){ return window.__FLASHCARD_CARD__ || {}; },
    answer: function(r){
      var c = queue[qIdx]; if (!c) return;
      if (["again","hard","good"].indexOf(r) < 0) return;
      states[c.word] = reviewCard(states[c.word], r);
      saveStates();
      today.done++; saveToday();
      if (r === "again") queue.push(c);  // 忘记的塞回队尾
      qIdx++;
      renderCard();
    },
    tts: function(text, lang){
      if (!("speechSynthesis" in window)) return;
      speechSynthesis.cancel();
      var u = new SpeechSynthesisUtterance(text);
      u.lang = lang || "en-US"; u.rate = 0.95;
      speechSynthesis.speak(u);
    },
    getState: function(){ return undefined; },
    setState: function(){},
    undo: function(){ if(qIdx>0){qIdx--; renderCard();} },
    next: function(){ if(qIdx<queue.length){qIdx++; renderCard();} },
    prev: function(){ if(qIdx>0){qIdx--; renderCard();} },
    ready: function(){}
  };

  document.getElementById("revBack").onclick = function(){
    $review.classList.remove("on");
    if (currentChapter) showPages(currentChapter.title, currentChapter.cards);
    else showBook();
  };

  /* ---------- 设置 ---------- */
  var $mask = document.getElementById("settingsMask");
  var $range = document.getElementById("limitRange");
  var $num = document.getElementById("limitNum");
  var chips = [10,20,30,50,80,100];

  function renderChips(){
    var box = document.getElementById("limitChips");
    box.innerHTML = "";
    chips.forEach(function(n){
      var c = el('<div class="chip'+(settings.dailyLimit===n?" sel":"")+'">'+n+'</div>');
      c.onclick = function(){ settings.dailyLimit=n; $range.value=n; $num.textContent=n; saveSettings(); renderChips(); updateTodayBar(); };
      box.appendChild(c);
    });
  }
  $range.oninput = function(){ settings.dailyLimit=+$range.value; $num.textContent=$range.value; saveSettings(); renderChips(); updateTodayBar(); };
  document.getElementById("gearBtn").onclick = function(){
    $range.value = settings.dailyLimit; $num.textContent = settings.dailyLimit;
    renderChips(); $mask.classList.add("on");
  };
  document.getElementById("settingsClose").onclick = function(){ $mask.classList.remove("on"); };
  $mask.onclick = function(e){ if (e.target === $mask) $mask.classList.remove("on"); };

  /* ---------- 启动 ---------- */
  Promise.all([
    fetch("../decks/kaoyan_core.json").then(function(r){ return r.json(); }),
    fetch("../templates/bubei_dark/manifest.json").then(function(r){ return r.json(); }),
    fetch("../templates/bubei_dark/template.html").then(function(r){ return r.text(); }),
    fetch("../templates/bubei_dark/style.css").then(function(r){ return r.text(); }),
    fetch("../templates/bubei_dark/script.js").then(function(r){ return r.text(); })
  ]).then(function(res){
    book = res[0];
    template = { manifest: res[1], html: res[2], css: res[3], js: res[4] };

    var st = document.createElement("style");
    st.textContent = template.css;
    document.head.appendChild(st);

    updateTodayBar();
    showShelf();
  }).catch(function(err){
    document.getElementById("view").innerHTML =
      '<div id="loading">加载失败：'+err.message+'<br><br>请起静态服务：<br>' +
      '<code>cd /workspace/flashcard && python3 -m http.server 8080</code><br>' +
      '访问 http://localhost:8080/webpreview/</div>';
  });
})();
