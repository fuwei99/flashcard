/// 版本自检
/// ================================================================
/// 本机版本从 package_info_plus 读（真源 = pubspec 的 `version`），
/// 「检查更新」拿 GitHub 最新 release 的 tag 比一比。
///
/// 纯读公开仓库，不上传任何东西、不引第三方 SDK。
/// 未认证的 GitHub API 限速 60 次/小时，够用（只在手点时发一次请求）。
library;

import 'dart:convert';
import 'dart:io';

class UpdateService {
  static const repo = 'fuwei99/flashcard';

  /// 远端最新 release 的版本号（已去掉前缀 `v`）；失败返回 null
  static Future<String?> latestVersion() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri =
          Uri.parse('https://api.github.com/repos/$repo/releases/latest');
      final req = await client.getUrl(uri);
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'flashcard-app');
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;
      final tag = (data['tag_name'] ?? '').toString();
      if (tag.isEmpty) return null;
      return tag.startsWith('v') ? tag.substring(1) : tag;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// remote 是否比 local 新（按 x.y.z 逐段数字比）
  static bool isNewer(String remote, String local) {
    final a = _parse(remote);
    final b = _parse(local);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int> _parse(String v) {
    final out = <int>[0, 0, 0];
    final parts = v.split('.');
    for (var i = 0; i < 3 && i < parts.length; i++) {
      final m = RegExp(r'\d+').stringMatch(parts[i]);
      out[i] = (m == null ? 0 : int.tryParse(m)) ?? 0;
    }
    return out;
  }
}
