/// 插件系统（内核）
/// ================================================================
/// 一切皆插件：TTS 插件、LLM provider 插件，统一走这里。
///
/// 一个插件 = 一个目录（平铺，不按类型分层）：
///   plugins/<id>/
///     ├── manifest.json    清单（声明式，type 字段决定谁来消费）
///     ├── <entry>.js       脚本（engine = js 时才要）
///     └── kv.json          插件私有存储（运行时生成）
///
/// 目录两处，合并展示；用户插件同名覆盖内置插件：
///   · 内置：打包进 APK 的 assets/plugins/...（只读）
///   · 用户：/storage/emulated/0/Documents/Flashcard/plugins/...（可加可删）
///
/// engine 三种：
///   openai-tts   OpenAI 兼容 HTTP TTS（声明式，无需脚本）
///   openai-chat  OpenAI 兼容 Chat（LLM provider，声明式）
///   js           脚本插件，跑在内置 JS 引擎上（TTS Server 那套 ttsrv API）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'data_dir.dart';

/// 插件类型（能力种类）
///
/// 目录不再按类型分层 —— 所有插件平铺在 `plugins/<id>/`，
/// 类型只写在 manifest 的 `type` 里，决定「谁来消费它」：
///   tts  → TtsService 选一个当朗读引擎
///   llm  → 模型调用选一个当 provider
///   tool → 常驻工具（词典 / 翻译…），没有「启用」概念，随时可调
enum PluginType {
  tts,
  llm,
  tool;

  static PluginType? parse(String? s) => switch (s) {
        'tts' => PluginType.tts,
        'llm' => PluginType.llm,
        'tool' => PluginType.tool,
        _ => null,
      };

  String get wire => name;

  String get label => switch (this) {
        PluginType.tts => 'TTS 插件',
        PluginType.llm => 'LLM Provider 插件',
        PluginType.tool => '工具插件',
      };

  /// 单例能力：同一时刻只能启用一个。tool 是常驻能力，不存在「启用」
  bool get singleton => this == PluginType.tts || this == PluginType.llm;
}

/// 插件后端引擎
enum PluginEngine {
  openaiTts,
  openaiChat,
  js;

  static PluginEngine? parse(String? s) => switch (s) {
        'openai-tts' => PluginEngine.openaiTts,
        'openai-chat' => PluginEngine.openaiChat,
        'js' => PluginEngine.js,
        _ => null,
      };

  String get wire => switch (this) {
        PluginEngine.openaiTts => 'openai-tts',
        PluginEngine.openaiChat => 'openai-chat',
        PluginEngine.js => 'js',
      };

  String get label => switch (this) {
        PluginEngine.openaiTts => 'OpenAI 兼容 TTS',
        PluginEngine.openaiChat => 'OpenAI 兼容 Chat',
        PluginEngine.js => 'JS 脚本插件',
      };
}

/// 插件声明的一个配置项
class PluginVar {
  final String key;
  final String label;
  final String hint;
  final bool secret;
  final String def;

  const PluginVar({
    required this.key,
    required this.label,
    this.hint = '',
    this.secret = false,
    this.def = '',
  });

  factory PluginVar.fromJson(Map j) => PluginVar(
        key: '${j['key'] ?? ''}'.trim(),
        label: '${j['label'] ?? j['key'] ?? ''}',
        hint: '${j['hint'] ?? ''}',
        secret: j['secret'] == true,
        def: '${j['default'] ?? ''}',
      );
}

class PluginManifest {
  final String id;
  final String name;
  final PluginType type;
  final PluginEngine engine;
  final String author;
  final int version;
  final String icon;
  final String entry;
  final List<PluginVar> vars;
  final Map<String, dynamic> defaults;

  /// 内置 = asset 目录；用户 = 磁盘绝对目录
  final String location;
  final bool builtin;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.type,
    required this.engine,
    this.author = '',
    this.version = 1,
    this.icon = '',
    this.entry = '',
    this.vars = const [],
    this.defaults = const {},
    required this.location,
    required this.builtin,
  });

  static PluginManifest? parse(String raw,
      {required String location, required bool builtin}) {
    try {
      final j = json.decode(raw);
      if (j is! Map) return null;
      final type = PluginType.parse('${j['type']}');
      final engine = PluginEngine.parse('${j['engine']}');
      if (type == null || engine == null) return null;
      final vars = <PluginVar>[];
      final v = j['vars'];
      if (v is List) {
        for (final e in v) {
          if (e is Map) vars.add(PluginVar.fromJson(e));
        }
      }
      return PluginManifest(
        id: '${j['id'] ?? ''}'.trim(),
        name: '${j['name'] ?? j['id'] ?? ''}',
        type: type,
        engine: engine,
        author: '${j['author'] ?? ''}',
        version: j['version'] is int
            ? j['version'] as int
            : int.tryParse('${j['version']}') ?? 1,
        icon: '${j['icon'] ?? ''}',
        entry: '${j['entry'] ?? ''}',
        vars: vars,
        defaults: j['defaults'] is Map
            ? Map<String, dynamic>.from(j['defaults'] as Map)
            : const {},
        location: location,
        builtin: builtin,
      );
    } catch (_) {
      return null;
    }
  }

  /// 读 JS 源码（engine = js）
  Future<String?> loadScript() async {
    if (entry.isEmpty) return null;
    if (builtin) {
      try {
        return await rootBundle.loadString('$location/$entry');
      } catch (_) {
        return null;
      }
    }
    try {
      final f = File('$location/$entry');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }
}

/// 插件管家：扫描 / 启用 / 配置
class PluginManager {
  static final PluginManager I = PluginManager._();
  PluginManager._();

  final List<PluginManifest> _all = [];

  /// id -> { varKey: value }
  final Map<String, Map<String, String>> _vars = {};

  String _activeTts = '';
  String _activeLlm = '';
  bool _loaded = false;

  List<PluginManifest> get all => List.unmodifiable(_all);

  List<PluginManifest> of(PluginType t) =>
      _all.where((p) => p.type == t).toList();

  PluginManifest? byId(String id) {
    for (final p in _all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 当前选中的插件；没选/选的没了就取该类型第一个。
  /// tool 不是单例能力，没有「当前选中」这一说，恒返回 null。
  PluginManifest? active(PluginType t) {
    if (!t.singleton) return null;
    final id = t == PluginType.tts ? _activeTts : _activeLlm;
    final hit = byId(id);
    if (hit != null && hit.type == t) return hit;
    final list = of(t);
    return list.isEmpty ? null : list.first;
  }

  String activeId(PluginType t) => active(t)?.id ?? '';

  bool isActive(PluginManifest m) =>
      m.type.singleton && active(m.type)?.id == m.id;

  String varOf(String id, String key) {
    final m = _vars[id];
    if (m != null && m.containsKey(key)) return m[key]!;
    final p = byId(id);
    if (p != null) {
      for (final v in p.vars) {
        if (v.key == key) return v.def;
      }
    }
    return '';
  }

  Map<String, String> varsOf(String id) {
    final out = <String, String>{};
    final p = byId(id);
    if (p == null) return out;
    for (final v in p.vars) {
      out[v.key] = varOf(id, v.key);
    }
    return out;
  }

  Future<void> setVar(String id, String key, String value) async {
    (_vars[id] ??= {})[key] = value;
    await _save();
  }

  Future<void> setVars(String id, Map<String, String> values) async {
    final m = _vars[id] ??= {};
    m.addAll(values);
    await _save();
  }

  Future<void> setActive(PluginType t, String id) async {
    if (t == PluginType.tts) {
      _activeTts = id;
    } else {
      _activeLlm = id;
    }
    await _save();
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _loaded = true;
    _all.clear();
    await DataDir.root();
    await _scanBuiltin();
    await _scanUser();
    _loadConfig();
  }

  /// 内置插件：扫 assets/plugins/**/manifest.json，不再写死清单
  /// —— 往 assets/plugins/ 丢个目录就是一个内置插件，不用改代码
  Future<void> _scanBuiltin() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final k in manifest.listAssets()) {
        if (!k.startsWith('assets/plugins/') ||
            !k.endsWith('/manifest.json')) {
          continue;
        }
        final dir = k.substring(0, k.length - '/manifest.json'.length);
        final raw = await rootBundle.loadString(k);
        final m = PluginManifest.parse(raw, location: dir, builtin: true);
        if (m != null) _put(m);
      }
    } catch (_) {}
  }

  /// 用户插件：`Flashcard/plugins/<id>/manifest.json`（平铺）。
  /// 兼容旧布局 `plugins/<type>/<id>/manifest.json` —— 只多递归一层。
  Future<void> _scanUser() async {
    final base = await DataDir.sub('plugins');
    if (base == null) return;
    await _scanDir(base, depth: 0);
  }

  Future<void> _scanDir(Directory dir, {required int depth}) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is! Directory) continue;
      final mf = File('${e.path}/manifest.json');
      if (await mf.exists()) {
        try {
          final m = PluginManifest.parse(await mf.readAsString(),
              location: e.path, builtin: false);
          if (m != null) _put(m);
        } catch (_) {}
      } else if (depth < 1) {
        await _scanDir(e, depth: depth + 1);
      }
    }
  }

  void _put(PluginManifest m) {
    if (m.id.isEmpty) return;
    _all.removeWhere((p) => p.id == m.id);
    _all.add(m);
  }

  void _loadConfig() {
    final doc = DataDir.readJsonSync('plugins.json');
    if (doc == null) return;
    _activeTts = '${doc['active_tts'] ?? ''}';
    _activeLlm = '${doc['active_llm'] ?? ''}';
    final v = doc['vars'];
    if (v is Map) {
      v.forEach((k, val) {
        if (val is Map) {
          _vars['$k'] = val.map((a, b) => MapEntry('$a', '$b'));
        }
      });
    }
  }

  Future<void> _save() async {
    await DataDir.writeJson('plugins.json', {
      'active_tts': _activeTts,
      'active_llm': _activeLlm,
      'vars': _vars,
    });
  }
}
