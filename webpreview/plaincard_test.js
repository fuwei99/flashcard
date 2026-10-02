/* plaincard_v1 渲染层 · 纯函数自测
   ================================================================
   跑法：node webpreview/plaincard_test.js

   测的是 script.js 里两个**最容易悄悄坏掉**的解析器：
     mdBlock       markdown-lite（粗体 / 高亮 / 代码 / 列表）
     renderInline  标记语法（{{c1::挖空}} / [[遮盖]]）

   为什么要专门测：这两处一旦写错，卡片**不报错** —— 只是把
   `{{c1::答案}}` 原样印在屏幕上，或者把挖空拆到独立一行
   （一句话被硬断成三行）。对背诵卡来说前者等于送答案、
   后者等于报废，而这两种错误在手机上都只是「看着有点怪」，
   肉眼验收一定会漏。

   环境：script.js 是给 WebView 写的，这里塞一份最小 DOM 桩，
   init() 会因为拿不到 #pc-root 直接返回，只留下 window.PC。
   ================================================================ */
"use strict";

var fs = require("fs");
var path = require("path");
var vm = require("vm");

var SRC = path.join(__dirname, "..", "templates", "plaincard_v1", "script.js");

// ---- 最小 DOM 桩 ----
var sandbox = {
  document: {
    readyState: "complete",
    addEventListener: function () {},
    getElementById: function () { return null; },
    createElement: function () { return {}; },
    querySelector: function () { return null; },
    querySelectorAll: function () { return []; }
  },
  console: console
};
sandbox.window = sandbox;
sandbox.Flashcard = {
  log: function () {},
  call: function () { return Promise.resolve({}); },
  tts: function () {}
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, "utf8"), sandbox, { filename: SRC });

var T = sandbox.PC && sandbox.PC.__test;
if (!T) { console.error("✗ script.js 没有导出 __test"); process.exit(1); }

var fails = 0, total = 0;
function ok(name, cond, extra) {
  total++;
  if (!cond) { fails++; console.log("  ✗ " + name + (extra ? "  → " + extra : "")); }
  else console.log("  ✓ " + name);
}
function eq(name, a, b) {
  ok(name, a === b, "got " + JSON.stringify(a) + ", want " + JSON.stringify(b));
}
function has(name, hay, needle) {
  ok(name, hay.indexOf(needle) >= 0,
     "missing " + JSON.stringify(needle) + " in " + JSON.stringify(hay));
}
function lacks(name, hay, needle) {
  ok(name, hay.indexOf(needle) < 0,
     "unexpected " + JSON.stringify(needle) + " in " + JSON.stringify(hay));
}
/** 把 pc-val（藏答案的容器）整段抠掉，剩下的才是「屏幕上直接能看见的东西」 */
function visibleOnly(html) {
  return html.replace(/<span class="pc-val">[\s\S]*?<\/span>/g, "");
}

console.log("\n[1] mdBlock：markdown-lite");
eq("单行不包 p", T.mdBlock("这是**重点**"), "这是<b>重点</b>");
eq("高亮", T.mdBlock("这是==关键==词"), '这是<span class="pc-mark">关键</span>词');
eq("行内代码", T.mdBlock("写 `ls -a` 看看"), '写 <span class="pc-code">ls -a</span> 看看');
eq("多行才分段", T.mdBlock("第一行\n\n第二行"), "<p>第一行</p><p>第二行</p>");
eq("无序列表", T.mdBlock("- a\n- b"), "<ul><li>a</li><li>b</li></ul>");
eq("有序列表", T.mdBlock("1. a\n2. b"), '<ol><li value="1">a</li><li value="2">b</li></ol>');
eq("列表与段落混排", T.mdBlock("前言\n- a\n- b"), "<p>前言</p><ul><li>a</li><li>b</li></ul>");
ok("HTML 被转义（不执行注入）",
   T.mdBlock("<script>alert(1)</script>").indexOf("&lt;script&gt;") >= 0,
   T.mdBlock("<script>alert(1)</script>"));

console.log("\n[2] 公式必须原样透传（这条坏了 KaTeX 就全废）");
var m = T.mdBlock("公式 $a_1^2 + \\frac{b}{c}$ 结束");
has("下标没被吃", m, "a_1^2");
has("反斜杠没被吃", m, "\\frac{b}{c}");
has("美元符没被吃", m, "$a_1^2");
eq("独立公式块", T.mdBlock("$$\\int_0^1 x\\,dx$$"), "$$\\int_0^1 x\\,dx$$");

console.log("\n[3] renderInline：挖空 {{c1::答案}}");
var c1 = T.renderInline("最大应力在{{c1::紧边刚绕上小带轮处}}。");
// 答案只能出现在 pc-val 里（CSS 用 color:transparent 藏起来）。
// 一旦它同时出现在普通文本节点里，就等于把答案写在脸上。
eq("答案在文档里只出现一次", (c1.match(/紧边刚绕上小带轮处/g) || []).length, 1);
has("而且在 pc-val 里", c1, '<span class="pc-val">紧边刚绕上小带轮处</span>');
lacks("可见区里没有答案", visibleOnly(c1), "紧边刚绕上小带轮处");
ok("单行挖空不被 <p> 切开（否则整句被断行）", c1.indexOf("<p>") < 0, c1);
has("生成挖空 span", c1, 'class="pc-blank"');
has("保留前文", c1, "最大应力在");
ok("保留后文句号", c1.endsWith("。"), c1);

var c2 = T.renderInline("条件：{{c1::$\\lambda \\le \\varphi_v$::自锁条件}}");
has("带提示的挖空", c2, '<span class="pc-hint">自锁条件</span>');
has("挖空答案可含公式", c2, "\\lambda \\le \\varphi_v");

var c3 = T.renderInline("{{c2::第二个空}} 和 {{c1::第一个空}}");
eq("多个空各自成 span", (c3.match(/class="pc-blank"/g) || []).length, 2);

console.log("\n[4] renderInline：遮盖 [[文字]]");
var k1 = T.renderInline("答案是[[V 形牙侧把法向力放大]]了。");
lacks("可见区里没有遮盖内容", visibleOnly(k1), "V 形牙侧把法向力放大");
has("生成遮盖 span", k1, 'class="pc-cover"');
has("遮盖内容在 pc-val", k1, '<span class="pc-val">V 形牙侧把法向力放大</span>');

var k2 = T.renderInline("[[被遮内容::小提示]]");
has("遮盖带提示", k2, '<span class="pc-hint">小提示</span>');
has("遮盖内容在 pc-val", k2, '<span class="pc-val">被遮内容</span>');

console.log("\n[5] 混合：挖空 + 高亮 + 列表");
var mix = T.renderInline("1. 第一步 {{c1::甲}}\n2. 第二步 ==乙==\n\n结尾**粗**");
has("列表保留", mix, "<ol>");
has("挖空在内", mix, 'class="pc-blank"');
has("高亮在内", mix, "pc-mark");
has("粗体在内", mix, "<b>粗</b>");

console.log("\n[6] 边界：别把正常的方括号 / 大括号搞坏");
var e1 = T.renderInline("集合 {1,2,3} 是闭区间 [0,1] 的子集");
ok("单个 {} 不被当挖空", e1.indexOf('class="pc-blank"') < 0, e1);
ok("单个 [] 不被当遮盖", e1.indexOf('class="pc-cover"') < 0, e1);
has("原样保留", e1, "{1,2,3}");
eq("空串 → 空", T.renderInline(""), "");

console.log("\n[7] 转义只在文本层，不碰标记");
has("& 被转义", T.esc("a & b"), "a &amp; b");
has("< 被转义", T.esc("a<b"), "a&lt;b");
eq("反斜杠不动（公式命根子）", T.esc("\\frac"), "\\frac");

console.log("\n" + (fails ? "✗ " : "✓ ") + (total - fails) + "/" + total + " 通过");
process.exit(fails ? 1 : 0);
