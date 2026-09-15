/// 插件系统（内核）
/// ================================================================
/// 一切皆插件：TTS 插件、LLM provider 插件，统一走这里。
///
/// 一个插件 = 一个目录：
///   plugins/<type>/<id>/
///     ├── manifest.json    清单（声明式）
///     └── <entry>.js       脚本（engine = js 时才要）
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

import 'package:flutter/services.dart' show rootBundle;

import 'data_dir.dart';

/// 插件类型
enum PluginType {
  tts,
  llm;

  static PluginType? parse(String? s) => switch (s) {
        'tts' => PluginType.tts,
        'llm' => PluginType.llm,
        _ => null,
      };

  String get wire => name;

  String get label => this == PluginType.tts ? 'TTS 插件' : 'LLM Provider 插件';
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

  /// 当前选中的插件；没选/选的没了就取该类型第一个
  PluginManifest? active(PluginType t) {
    final id = t == PluginType.tts ? _activeTts : _activeLlm;
    final hit = byId(id);
    if (hit != null && hit.type == t) return hit;
    final list = of(t);
    return list.isEmpty ? null : list.first;
  }

  String activeId(PluginType t) => active(t)?.id ?? '';

  bool isActive(PluginManifest m) => active(m.type)?.id == m.id;

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

  // 内置插件目录（写死清单，省得列 asset 目录）
  static const _builtinDirs = [
    'assets/plugins/tts/openai',
    'assets/plugins/tts/doubao',
    'assets/plugins/llm/openai',
  ];

  Future<void> _scanBuiltin() async {
    for (final dir in _builtinDirs) {
      try {
        final raw = await rootBundle.loadString('$dir/manifest.json');
        final m = PluginManifest.parse(raw, location: dir, builtin: true);
        if (m != null) _put(m);
      } catch (_) {}
    }
  }

  Future<void> _scanUser() async {
    final base = await DataDir.sub('plugins');
    if (base == null) return;
    for (final t in ['tts', 'llm']) {
      final d = Directory('${base.path}/$t');
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        if (e is! Directory) continue;
        final mf = File('${e.path}/manifest.json');
        if (!await mf.exists()) continue;
        try {
          final m = PluginManifest.parse(await mf.readAsString(),
              location: e.path, builtin: false);
          if (m != null) _put(m);
        } catch (_) {}
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
