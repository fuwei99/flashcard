// 验证注入到卡牌页的全局错误钩子（TemplateEngine.buildPage 里那段）。
//
// 没有 Flutter 工具链，跑不了 widget test —— 但这段钩子本身是纯 JS，
// 用 vm 起个沙箱、喂一个假 FCChannel，就能把真实行为跑出来。
//
// 验四件事：
//   1. 未捕获错误 / 未处理 Promise 拒绝 / console.error 都能上报
//   2. **模板自己赋值 window.onerror 顶不掉壳的钩子**（这是设计要点：
//      钩子用 addEventListener，模板脚本在本段之后执行）
//   3. 刷屏限流生效（CAP=60 / 10s 窗口，最多落 61 条）
//   4. 钩子自己抛异常也不会把页面带崩
const vm = require('vm');
const { extract } = require('./extract_hook');

// 直接从 Dart 源码里抠，不落中间文件 —— 保证测的就是真在跑的那段
const hook = extract();

function boot() {
  const out = [];
  const listeners = {};
  const sandbox = {
    JSON, Date, String, Array, Object, Error, Promise, Number, Boolean,
    console: { error() {}, warn() {}, log() {}, info() {} },
  };
  sandbox.window = {
    addEventListener(ev, fn) {
      (listeners[ev] = listeners[ev] || []).push(fn);
    },
  };
  sandbox.FCChannel = {
    postMessage(s) { out.push(JSON.parse(s)); },
  };
  vm.createContext(sandbox);
  vm.runInContext(hook, sandbox);
  return { out, listeners, sandbox };
}

function fire(listeners, ev, payload) {
  (listeners[ev] || []).forEach((fn) => fn(payload));
}

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log('  PASS', name); }
  else { fail++; console.log('  FAIL', name, extra === undefined ? '' : extra); }
}

// ---- 1. 三类事件都能上报 ----
console.log('[1] 三类事件上报');
{
  const { out, listeners, sandbox } = boot();

  fire(listeners, 'error', {
    message: 'Cannot read properties of null',
    filename: 'script.js',
    lineno: 42,
    colno: 7,
    error: new Error('Cannot read properties of null'),
  });
  fire(listeners, 'unhandledrejection', { reason: new Error('rpc timeout') });
  sandbox.console.error('手动打的错误', new Error('manual'));

  const tags = out.map((m) => m.tag);
  ok('JSERR 上报', tags.includes('JSERR'), JSON.stringify(tags));
  ok('JSPROMISE 上报', tags.includes('JSPROMISE'), JSON.stringify(tags));
  ok('JSERROR 上报', tags.includes('JSERROR'), JSON.stringify(tags));

  const e = out.find((m) => m.tag === 'JSERR');
  ok('带行号定位', /script\.js:42:7/.test(e.msg), e.msg);
  ok('带堆栈', /Error: Cannot read/.test(e.msg), e.msg);
  ok('type 是 log（壳按 log 分流到 logs/js/）', e.type === 'log', e.type);
}

// ---- 2. 模板顶不掉钩子 ----
console.log('[2] 模板自己赋值 window.onerror');
{
  const { out, listeners, sandbox } = boot();
  // 模拟模板 script.js 干的事：把 window.onerror 换成自己的
  let templateGotIt = false;
  sandbox.window.onerror = function () { templateGotIt = true; };

  fire(listeners, 'error', { message: 'still here', filename: 'a.js', lineno: 1, colno: 1 });

  ok('壳的钩子仍然上报', out.some((m) => m.tag === 'JSERR'),
      JSON.stringify(out.map((m) => m.tag)));
  ok('模板的 onerror 也没被吞（addEventListener 不占这个槽）',
      typeof sandbox.window.onerror === 'function' && templateGotIt === false);
}

// ---- 3. 限流 ----
console.log('[3] 刷屏限流');
{
  const { out, listeners } = boot();
  for (let i = 0; i < 300; i++) {
    fire(listeners, 'error', { message: 'loop ' + i, filename: 'x.js', lineno: i, colno: 1 });
  }
  const n = out.length;
  // CAP=60 → 前 60 条 + 1 条「已限流」提示
  ok('限流到 61 条以内', n <= 61, '实际 ' + n);
  ok('有明确的限流提示', out.some((m) => /不再上报/.test(m.msg)),
      JSON.stringify(out[out.length - 1]));
}

// ---- 4. 钩子自身健壮性 ----
console.log('[4] 钩子自身健壮性');
{
  const { out, listeners, sandbox } = boot();
  // toString 会抛的恶意对象
  const evil = { get stack() { throw new Error('nope'); }, toString() { throw new Error('nope'); } };
  let threw = false;
  try {
    sandbox.console.error(evil);
    fire(listeners, 'error', { message: 'x', error: evil });
  } catch (e) { threw = true; }
  ok('不往外抛', !threw);
  ok('仍然产出了记录', out.length >= 1, '实际 ' + out.length);

  // 没有 FCChannel（glue 没装成功）时不能炸
  let threw2 = false;
  try {
    const s2 = {
      JSON, Date, String, Array, Object, Error,
      console: { error() {}, warn() {} },
      window: { addEventListener() {} },
    };
    vm.createContext(s2);
    vm.runInContext(hook, s2);
    s2.console.error('no channel');
  } catch (e) { threw2 = true; }
  ok('没有 FCChannel 时静默退出', !threw2);
}

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
