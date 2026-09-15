/// 插件管理
/// ================================================================
/// 一切皆插件：
///   · TTS 插件        —— OpenAI 兼容 HTTP / JS 脚本（豆包那类）
///   · LLM Provider 插件 —— OpenAI 兼容 Chat
///
/// 内置插件打包在 assets/plugins/；用户插件丢在
/// /storage/emulated/0/Documents/Flashcard/plugins/<tts|llm>/<id>/
/// 同名覆盖内置。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/data_dir.dart';
import '../services/plugin.dart';
import '../services/study_settings.dart';
import '../services/tts_service.dart';

class PluginsScreen extends StatefulWidget {
  final StudySettings settings;
  const PluginsScreen({super.key, required this.settings});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  int _tab = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    await PluginManager.I.load(force: true);
    if (mounted) setState(() => _loading = false);
  }

  PluginType get _type => _tab == 0 ? PluginType.tts : PluginType.llm;

  Future<void> _open(PluginManifest m) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PluginDetailScreen(manifest: m, settings: widget.settings),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 装一个 .js 插件：文件落到 plugins/<type>/<id>/
  Future<void> _install() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['js', 'txt'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    final base = File(path).uri.pathSegments.last.replaceAll('.js', '');
    final id = base.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final dir = await DataDir.sub('plugins/${_type.wire}/$id');
    if (dir == null) return;
    await File(path).copy('${dir.path}/plugin.js');
    final manifest = {
      'id': id,
      'name': base,
      'type': _type.wire,
      'engine': 'js',
      'author': 'imported',
      'version': 1,
      'entry': 'plugin.js',
      'defaults': {'audio_format': 'aac'},
      'vars': [
        {'key': 'cookie', 'label': 'Cookie', 'hint': '完整请求头 Cookie', 'secret': true},
        {'key': 'voice', 'label': '音色 / speaker', 'hint': '插件要求的音色标识'},
        {'key': 'rate', 'label': '语速倍率', 'hint': '0.5 ~ 2.0', 'default': '1.0'},
      ],
    };
    await File('${dir.path}/manifest.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已装到 ${dir.path}'),
      backgroundColor: const Color(0xFF1B2629),
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showDir() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title: const Text('插件目录',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SelectableText(
          '${DataDir.publicPath}/plugins/\n'
          '  ├── tts/<插件id>/manifest.json + plugin.js\n'
          '  └── llm/<插件id>/manifest.json',
          style: const TextStyle(color: Color(0xFFB7C4C8), fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好', style: TextStyle(color: Color(0xFF00C08B))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = PluginManager.I.of(_type);
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        title: const Text('插件管理',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 20)),
        actions: [
          IconButton(
            tooltip: '插件目录',
            onPressed: _showDir,
            icon: const Icon(Icons.folder_open, color: Color(0xFF8C9DA2)),
          ),
          IconButton(
            tooltip: '重载',
            onPressed: _load,
            icon: const Icon(Icons.refresh, color: Color(0xFF8C9DA2)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                _tabBtn('TTS 插件', 0),
                const SizedBox(width: 8),
                _tabBtn('LLM Provider', 1),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child:
                        CircularProgressIndicator(color: Color(0xFF00C08B)))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                    children: [
                      if (list.isEmpty)
                        _card(child: const Text('这个分类下还没有插件',
                            style: TextStyle(
                                color: Color(0xFF54666C), fontSize: 13))),
                      for (final m in list) _pluginCard(m),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _install,
                        icon: const Icon(Icons.add, size: 18),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00C08B),
                          side: const BorderSide(color: Color(0x3300C08B)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        label: Text('安装 ${_type.label}（选 .js）'),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tabBtn(String t, int i) {
    final on = _tab == i;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: on ? const Color(0x1A00C08B) : const Color(0x0BFFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: on ? const Color(0x6600C08B) : const Color(0x14FFFFFF)),
          ),
          child: Text(t,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: on ? const Color(0xFF00C08B) : const Color(0xFF8C9DA2),
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _pluginCard(PluginManifest m) {
    final active = PluginManager.I.isActive(m);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open(m),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0x0BFFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color:
                    active ? const Color(0x6600C08B) : const Color(0x14FFFFFF)),
          ),
          child: Row(
            children: [
              Icon(
                m.engine == PluginEngine.js
                    ? Icons.code
                    : Icons.cloud_outlined,
                color: const Color(0xFF00C08B),
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(m.name,
                            style: const TextStyle(
                                color: Color(0xFFF0F4F5), fontSize: 15)),
                        if (active)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Text('使用中',
                                style: TextStyle(
                                    color: Color(0xFF00C08B), fontSize: 11)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${m.engine.label} · ${m.builtin ? "内置" : "用户"} · v${m.version}',
                      style: const TextStyle(
                          color: Color(0xFF54666C), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF54666C)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: child,
      );
}

/// 插件详情：配置项 + 切当前 + 测试
class PluginDetailScreen extends StatefulWidget {
  final PluginManifest manifest;
  final StudySettings settings;
  const PluginDetailScreen(
      {super.key, required this.manifest, required this.settings});

  @override
  State<PluginDetailScreen> createState() => _PluginDetailScreenState();
}

class _PluginDetailScreenState extends State<PluginDetailScreen> {
  final _controllers = <String, TextEditingController>{};
  final _test = TextEditingController(text: 'vulnerability');
  bool _busy = false;

  PluginManifest get m => widget.manifest;

  @override
  void initState() {
    super.initState();
    for (final v in m.vars) {
      _controllers[v.key] =
          TextEditingController(text: PluginManager.I.varOf(m.id, v.key));
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _test.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final map = <String, String>{};
    _controllers.forEach((k, c) => map[k] = c.text.trim());
    await PluginManager.I.setVars(m.id, map);
  }

  Future<void> _activate() async {
    await _save();
    await PluginManager.I.setActive(m.type, m.id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已启用 ${m.name}'),
      backgroundColor: const Color(0xFF1B2629),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _testSpeak() async {
    await _activate();
    setState(() => _busy = true);
    final svc = TtsService(settings: widget.settings);
    try {
      await svc.init();
      await svc.speak(_test.text.trim(), 'en-US');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已发起合成，听不到就看 调试日志 → TTS'),
        backgroundColor: Color(0xFF1B2629),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('测试异常：$e'),
          backgroundColor: const Color(0xFF3A2222),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      await svc.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = PluginManager.I.isActive(m);
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        title: Text(m.name,
            style: const TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('ID', m.id),
                _kv('类型', m.type.label),
                _kv('引擎', m.engine.label),
                _kv('来源', m.builtin ? '内置（APK）' : m.location),
                _kv('版本', 'v${m.version}  ${m.author}'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _label('配置'),
          if (m.vars.isEmpty)
            _card(
                child: const Text('这个插件没有可配置项',
                    style:
                        TextStyle(color: Color(0xFF54666C), fontSize: 13)))
          else
            _card(
              child: Column(
                children: [
                  for (final v in m.vars)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: TextField(
                        controller: _controllers[v.key],
                        obscureText: v.secret,
                        style: const TextStyle(
                            color: Color(0xFFF0F4F5), fontSize: 14),
                        decoration: InputDecoration(
                          labelText: v.label,
                          labelStyle: const TextStyle(
                              color: Color(0xFF8C9DA2), fontSize: 13),
                          hintText: v.hint.isEmpty ? v.key : v.hint,
                          hintStyle: const TextStyle(
                              color: Color(0xFF3E4E54), fontSize: 13),
                          isDense: true,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide:
                                  const BorderSide(color: Color(0x22FFFFFF))),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide:
                                  const BorderSide(color: Color(0x22FFFFFF))),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide:
                                  const BorderSide(color: Color(0xFF00C08B))),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (m.type == PluginType.tts) ...[
            _label('测试'),
            _card(
              child: Column(
                children: [
                  TextField(
                    controller: _test,
                    style: const TextStyle(
                        color: Color(0xFFF0F4F5), fontSize: 14),
                    decoration: InputDecoration(
                      labelText: '测试文本',
                      labelStyle: const TextStyle(
                          color: Color(0xFF8C9DA2), fontSize: 13),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0x22FFFFFF))),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0x22FFFFFF))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Color(0xFF00C08B))),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00C08B),
                        foregroundColor: const Color(0xFF141D1F),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _busy ? null : _testSpeak,
                      child: Text(_busy ? '合成中…' : '测试发音'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  active ? const Color(0xFF1B2629) : const Color(0xFF00C08B),
              foregroundColor:
                  active ? const Color(0xFF8C9DA2) : const Color(0xFF141D1F),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _activate,
            child: Text(active ? '当前使用中（点一下重新保存）' : '设为当前插件'),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 56,
                child: Text(k,
                    style: const TextStyle(
                        color: Color(0xFF8C9DA2), fontSize: 12))),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(
                      color: Color(0xFFF0F4F5), fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Text(t,
            style: const TextStyle(
                color: Color(0xFF8C9DA2),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: .5)),
      );

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: child,
      );
}
