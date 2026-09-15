/// TTS 引擎设置
/// ================================================================
/// 在线 OpenAI 兼容 TTS（主） / 系统 TTS（兜底）
///
/// 开了在线引擎后：
///   单词 → 首次 POST {base_url}/audio/speech 拿音频 → 存 cache/tts/ → 播；
///          之后再读直接秒播（读缓存）
///   长句 → 响应字节流直接喂播放器，边收边播（不缓存）
/// 在线没配置 / 合成失败时才退回系统 TTS。
library;

import 'package:flutter/material.dart';

import '../services/study_settings.dart';
import '../services/tts_service.dart';

class TtsSettingsScreen extends StatefulWidget {
  final StudySettings settings;
  const TtsSettingsScreen({super.key, required this.settings});

  @override
  State<TtsSettingsScreen> createState() => _TtsSettingsScreenState();
}

class _TtsSettingsScreenState extends State<TtsSettingsScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _voice;
  late final TextEditingController _test;
  bool _busy = false;

  StudySettings get s => widget.settings;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: s.ttsOpenAiBaseUrl);
    _apiKey = TextEditingController(text: s.ttsOpenAiApiKey);
    _model = TextEditingController(text: s.ttsOpenAiModel);
    _voice = TextEditingController(text: s.ttsOpenAiVoice);
    _test = TextEditingController(text: 'vulnerability');
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _voice.dispose();
    _test.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await s.setTtsOpenAi(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
      voice: _voice.text.trim(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('已保存'),
      backgroundColor: Color(0xFF1B2629),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _testSpeak() async {
    final text = _test.text.trim();
    if (text.isEmpty) return;
    // 先把当前输入框的值写进设置，保证测试用的是最新配置
    await _save();
    setState(() => _busy = true);
    final svc = TtsService(settings: s);
    try {
      final ok = await svc.testOpenAi(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '✅ 合成成功，音频已可缓存' : '❌ 合成失败，看 logs/tts/'),
        backgroundColor: ok ? const Color(0xFF00C08B) : const Color(0xFF3A2222),
        behavior: SnackBarBehavior.floating,
      ));
      if (ok) {
        // 再走一遍正式路径，顺便落缓存 + 试听
        await svc.init();
        await svc.speak(text, 'en-US');
      }
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
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        title: const Text('TTS 引擎',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 20)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _label('发音引擎'),
          _card(child: Column(children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('用在线 TTS（单词缓存 · 长句流式）',
                  style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 15)),
              subtitle: const Text('开：全部走下面的 HTTP 接口——单词缓存秒播，长句边收边播',
                  style: TextStyle(color: Color(0xFF54666C), fontSize: 12)),
              value: s.ttsOpenAiEnabled,
              activeColor: const Color(0xFF00C08B),
              onChanged: (v) async {
                await s.setTtsOpenAiEnabled(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('缓存开关',
                  style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 15)),
              subtitle: const Text('关掉则每次都重新请求（不建议）',
                  style: TextStyle(color: Color(0xFF54666C), fontSize: 12)),
              value: s.ttsWordCacheEnabled,
              activeColor: const Color(0xFF00C08B),
              onChanged: (v) async {
                await s.setTtsWordCacheEnabled(v);
                setState(() {});
              },
            ),
          ])),
          const SizedBox(height: 18),
          _label('OpenAI 兼容接口'),
          _card(child: Column(children: [
            _field('Base URL', _baseUrl, 'https://aihubmix.com/v1'),
            _field('API Key', _apiKey, 'sk-...', obscure: true),
            _field('Model', _model, 'gpt-4o-mini-tts'),
            _field('Voice', _voice, 'alloy'),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Text('语速', style: TextStyle(color: Color(0xFFB7C4C8), fontSize: 13)),
                  Expanded(
                    child: Slider(
                      value: s.ttsOpenAiSpeed.clamp(0.5, 2.0).toDouble(),
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      activeColor: const Color(0xFF00C08B),
                      label: s.ttsOpenAiSpeed.toStringAsFixed(1),
                      onChanged: (v) async {
                        await s.setTtsOpenAi(speed: v);
                        setState(() {});
                      },
                    ),
                  ),
                  Text(s.ttsOpenAiSpeed.toStringAsFixed(1),
                      style: const TextStyle(color: Color(0xFF00C08B), fontSize: 13)),
                ],
              ),
            ),
          ])),
          const SizedBox(height: 18),
          _label('测试'),
          _card(child: Column(children: [
            _field('测试文本', _test, 'vulnerability'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
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
            ]),
          ])),
          const SizedBox(height: 18),
          _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            Text('缓存目录', style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 14)),
            SizedBox(height: 6),
            SelectableText('/storage/emulated/0/Documents/Flashcard/cache/tts/',
                style: TextStyle(color: Color(0xFF8C9DA2), fontSize: 12)),
            SizedBox(height: 6),
            Text('换模型 / 音色 / 语速会自动按新键重建缓存，不会串音。长句不缓存、走流式播放。',
                style: TextStyle(color: Color(0xFF54666C), fontSize: 12)),
          ])),
          const SizedBox(height: 22),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00C08B),
              foregroundColor: const Color(0xFF141D1F),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

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

  Widget _field(String label, TextEditingController c, String hint,
      {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        obscureText: obscure,
        style: const TextStyle(color: Color(0xFFF0F4F5), fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Color(0xFF8C9DA2), fontSize: 13),
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFF3E4E54), fontSize: 13),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0x22FFFFFF)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0x22FFFFFF)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF00C08B)),
          ),
        ),
      ),
    );
  }
}
