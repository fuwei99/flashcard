/// 壳级 UI 偏好
/// ================================================================
/// 目前只有一项：原生顶部栏显隐。
///
/// 存盘位置：`Documents/Flashcard/settings/ui.json`
///   { "top_bar": true|false }
///
/// 链路：
///   模板设置里点开关 → RPC `ui.setChrome` → 这里写盘 + 通知屏幕实时切
///   下次进背诵 → ReviewScreen 调 `UiPrefs.load()` → 按盘上值决定显不显示
library;

import 'data_dir.dart';

class UiPrefs {
  /// null = 盘上还没值（回落到 manifest 默认）
  static bool? _topBar;

  /// 启动时异步读一次（先等数据根解析完）
  static Future<bool?> load() async {
    await DataDir.root();
    final d = DataDir.readJsonSync('settings/ui.json');
    final v = d?['top_bar'];
    _topBar = v is bool ? v : null;
    return _topBar;
  }

  static bool? get topBar => _topBar;

  /// 写内存 + 落盘，返回新值
  static bool setTopBar(bool v) {
    _topBar = v;
    DataDir.writeJsonSync('settings/ui.json', {'top_bar': v});
    return v;
  }
}
