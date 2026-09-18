// 从 TemplateEngine.buildPage 的 Dart 三引号字符串里，抠出壳注入的 JS 错误钩子。
//
// 用途：本机没装 Flutter/Dart，跑不了 widget test —— 但这段钩子是纯 JS，
// 抠出来就能用 Node 做真实行为验证（见 verify_error_hook.js）。
//
// 用法：
//   require('./extract_hook').extract()   -> JS 源码字符串
//   node tools/extract_hook.js            -> 打到 stdout（调试用）
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DART = path.join(ROOT, 'app/lib/services/template_engine.dart');

// 起点：钩子的第一行注释
const START = '// ---- 全局错误捕获';
// 终点：模板 script.js 的插入点。注意文件是 CRLF，别拿 '\n' 拼
const END = '$js</script>';

function extract() {
  const dart = fs.readFileSync(DART, 'utf8');
  const a = dart.indexOf(START);
  const b = dart.indexOf(END);
  if (a < 0 || b < 0) {
    throw new Error('marker not found: ' + a + ' ' + b);
  }
  // Dart 三引号字符串里的 \\n 运行时会输出成 \n，这里还原成真实 JS
  let js = dart.slice(a, b).replace(/\\\\n/g, '\\n');
  // slice 停在 `$js` 之前，尾巴上还挂着 `</script>` + `<script>`，切掉
  return js.slice(0, js.lastIndexOf('</script>'));
}

module.exports = { extract };

if (require.main === module) {
  const js = extract();
  process.stdout.write(js);
  process.stderr.write('\n(' + js.length + ' bytes)\n');
}
