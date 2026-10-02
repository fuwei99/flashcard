/* SM-2 内核自测：node webpreview/sm2_test.js
   覆盖「新卡 → 学习步 → 毕业 → 复习 → 答错重学」整条链，
   外加时间粒度（分钟级 due 不能被塌成天）和队列排序。
   改动 scheduler_sm2.dart / sm2.js 后跑一遍，防两端漂移。 */
"use strict";
var S = require("./sm2.js");

var fails = 0, total = 0;
function ok(name, cond, extra) {
  total++;
  if (!cond) { fails++; console.log("  ✗ " + name + (extra ? "  → " + extra : "")); }
  else console.log("  ✓ " + name);
}
function eq(name, a, b) { ok(name, a === b, "got " + a + ", want " + b); }
function near(name, a, b, tol) { ok(name, Math.abs(a - b) <= (tol || 1e-6), "got " + a + ", want " + b); }

var T0 = new Date("2026-10-02T21:00:00.000Z");
function at(min) { return new Date(T0.getTime() + min * 60000); }

console.log("\n[1] 新卡四档");
var s = S.newState();
var g1 = S.review(s, "good", T0);
eq("good → learn", g1.phase, "learn");
eq("good → 落在第 2 个学习步", g1.step, 1);
eq("good → +10 分钟", g1.due.getTime(), at(10).getTime());

var e1 = S.review(S.newState(), "easy", T0);
eq("easy → 直接毕业 review", e1.phase, "review");
eq("easy → 4 天", e1.interval, 4);

var a1 = S.review(S.newState(), "again", T0);
eq("again → learn 第 0 步", a1.step, 0);
eq("again → +1 分钟", a1.due.getTime(), at(1).getTime());

var h1 = S.review(S.newState(), "hard", T0);
eq("hard → 停在首步 +1 分钟", h1.due.getTime(), at(1).getTime());
var h2 = S.review(S.review(S.newState(), "good", T0), "hard", at(10));
eq("第 2 步 hard → 仍停在第 2 步 +10 分钟", h2.due.getTime(), at(20).getTime());
eq("第 2 步 hard 不毕业", h2.phase, "learn");

console.log("\n[2] 新卡 good → 学习步走完 → 毕业");
var g2 = S.review(g1, "good", at(10));
eq("第二步 good → 毕业", g2.phase, "review");
eq("毕业间隔 = 1 天", g2.interval, 1);
eq("毕业 due = 次日", g2.due.getTime(), at(10 + 24 * 60).getTime());

console.log("\n[3] 复习阶段（间隔按 ease 滚）");
var r1 = S.review(g2, "good", at(10 + 24 * 60));
eq("review good → 1*2.5 → 3 天", r1.interval, 3);
near("ease 不变", r1.ease, 2.5);
eq("仍在 review", r1.phase, "review");

var r2 = S.review(g2, "hard", at(10 + 24 * 60));
eq("review hard → max(1+1, 1*1.2) = 2 天", r2.interval, 2);
near("hard 扣 ease", r2.ease, 2.35);

var r3 = S.review(g2, "easy", at(10 + 24 * 60));
eq("review easy → 1*2.65*1.3 → 3 天", r3.interval, 3);
near("easy 加 ease", r3.ease, 2.65);

console.log("\n[4] 复习答错 → 重学");
var r4 = S.review(g2, "again", at(10 + 24 * 60));
eq("again → relearn", r4.phase, "relearn");
eq("lapses +1", r4.lapses, 1);
eq("重学步 +10 分钟", r4.due.getTime(), at(10 + 24 * 60 + 10).getTime());
near("again 扣 ease", r4.ease, 2.3);
var r5 = S.review(r4, "good", at(10 + 24 * 60 + 10));
eq("重学走完 → 回 review", r5.phase, "review");
eq("间隔保留（lapse_multiplier=0 → 最小 1 天）", r5.interval, 1);

console.log("\n[5] 分钟级 due 不能被压成天");
ok("learn 阶段 due 带时刻", g1.due.getHours() !== 0 || g1.due.getMinutes() === 10);
ok("due 精确到分钟", g1.due.getTime() % 60000 === 0);

console.log("\n[6] 间隔上限 & 保护");
var big = S.review({ phase: "review", interval: 30000, ease: 3.5, reps: 9, lapses: 0 }, "easy", T0);
eq("不越过 max_interval", big.interval, 36500);
var tiny = S.review({ phase: "review", interval: 1, ease: 1.3, reps: 3, lapses: 0 }, "hard", T0);
eq("间隔不塌成 0", tiny.interval >= 1, true);
var floorEase = S.review({ phase: "review", interval: 5, ease: 1.35, reps: 5, lapses: 1 }, "again", T0);
near("ease 有下限 1.3", floorEase.ease, 1.3, 1e-9);

console.log("\n[7] 队列：到期在前，新卡在后，标熟出队");
var now = new Date("2026-10-02T21:00:00Z");
var db = {
  "a-new": S.newState(),
  "b-due-early": S.review(S.review(S.newState(), "good", new Date("2026-09-01T09:00:00Z")), "good", new Date("2026-09-01T09:10:00Z")),
  "c-due-late": S.review(S.review(S.newState(), "good", new Date("2026-10-01T09:00:00Z")), "good", new Date("2026-10-01T09:10:00Z"))
};
var q = S.queue(["a-new", "b-due-early", "c-due-late"], function (id) { return db[id]; }, null, now);
ok("新卡排最后", q[q.length - 1] === "a-new", JSON.stringify(q));
ok("到期卡靠前", q.indexOf("b-due-early") < q.indexOf("c-due-late"), JSON.stringify(q));
var q2 = S.queue(["a-new", "b-due-early"], function (id) { return db[id]; }, function (id) { return id === "b-due-early"; }, now);
ok("标熟的出队", q2.indexOf("b-due-early") < 0, JSON.stringify(q2));

console.log("\n[8] 预览文案");
var pv = S.preview(S.newState(), T0);
eq("新卡 again = 1 分", pv.again, "1 分");
eq("新卡 good = 10 分", pv.good, "10 分");
eq("新卡 easy = 4 天", pv.easy, "4 天");
eq("格式：25 分", S.formatGap(25 * 60000), "25 分");
eq("格式：3 小时", S.formatGap(3 * 3600000), "3 小时");
eq("格式：45 天 → 1.5 个月", S.formatGap(45 * 86400000), "1.5 个月");
eq("格式：800 天 → 2.2 年", S.formatGap(800 * 86400000), "2.2 年");

console.log("\n[9] 非法评分必须报错（不兜底成 good）");
var threw = false;
try { S.review(S.newState(), "next", T0); } catch (e) { threw = true; }
ok("未知评分抛异常", threw);

console.log("\n[10] 参数覆盖");
var p2 = S.params({ learning_steps: [5], ease_interval: 9, interval_modifier: 0.5 });
ok("自定义学习步生效", p2.learning_steps.length === 1 && p2.learning_steps[0] === 5);
var custom = S.review(S.newState(), "good", T0, { learning_steps: [5] });
eq("单步 good → 直接毕业", custom.phase, "review");
var mod = S.review(S.newState(), "easy", T0, { interval_modifier: 0.5 });
eq("interval_modifier 生效 → 2 天", mod.interval, 2);

console.log("\n" + (fails ? "✗ " : "✓ ") + (total - fails) + "/" + total + " 通过");
process.exit(fails ? 1 : 0);
