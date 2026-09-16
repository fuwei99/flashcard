/// 背诵模式：会话状态机驱动 + 全屏 WebView 卡牌
/// ================================================================
/// 一次会话 = 若干 StudyUnit 顺序走完（跨牌组复习时会有很多单元）。
/// 轮内流程交给 StudySession；只有「毕业」才写 CardStore（= 标记已背）。
///
/// 单元内：语篇（通读/选词）-> 逐卡 learn -> 重测轮 -> 下一个单元。
/// 语篇两阶段没有具体卡片，mountCard 时 card 传 null、passage 传当前单元的语篇，
/// 并用 blankLemmas 限定「只挖今天要复习的那几个词」。
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import '../services/card_store.dart';
import '../services/scheduler.dart';
import '../services/session_plan.dart';
import '../services/status_writer.dart';
import '../services/study_plan.dart';
import '../services/study_settings.dart';
import '../services/tts_log.dart';
import '../services/tts_service.dart';
import '../services/webview_bridge.dart';

class ReviewScreen extends StatefulWidget {
  final String title;

  /// 编排好的学习单元（复习段 + 新学段）
  final List<StudyUnit> units;

  final CardTemplate template;

  /// 骨架页字段顺序（跨牌组时取第一本书的）
  final List<String> fieldsOrder;

  /// 干扰项池：跨牌组复习时是所有单词卡，单本书时是本书卡片
  final List<FlashCard> distractorPool;

  final CardStore store;
  final StudySettings settings;

  /// 是否卡牌（Card Tab）：决定今日进度算进「单词」还是「卡牌」
  final bool isCard;

  const ReviewScreen({
    super.key,
    required this.title,
    required this.units,
    required this.template,
    required this.fieldsOrder,
    required this.distractorPool,
    required this.store,
    required this.settings,
    this.isCard = false,
  });

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen>
    with WidgetsBindingObserver {
  late final WebViewBridge _bridge;
  late final StudySession _session;
  WebViewController? _controller;
  bool _loading = true;

  /// 骨架页是否已加载完成（onPageFinished）—— 之后才能 mountCard
  bool _ready = false;

  /// 已写入 FSRS 的卡，避免重复落盘
  final Set<String> _written = {};

  /// 每背完一组（kGroupSize 个）暂停一下
  int _pausedAt = 0;
  bool _pausing = false;

  /// 正在处理一条 answer —— 防止两次点击并发推进状态（会一次跳两页）
  bool _handling = false;

  /// mount 世代号：只有最后一次 mount 算数，过期的那次只记日志
  int _mountGen = 0;

  /// 「要不要拼写」弹窗正在显示 —— 防止并发弹两次
  bool _spellDialogOpen = false;

  // ===== 阶段 4：Web 驱动模式 =====
  /// 模板 manifest 声明 web_session=true 时，切牌流程归 workflow.js，
  /// 壳只执行它发来的指令（web.mount / web.spell / web.finish…）。
  late final bool _webDriven;
  bool _webFinished = false;
  String _webPhase = '';
  int _webDone = 0;
  int _webTotal = 0;
  int _webGraduated = 0;

  /// cardId -> 卡（从所有 unit 建索引，web.mount 按 id 找卡）
  final Map<String, FlashCard> _webIndex = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 阶段 4：模板 manifest 声明 web_session=true 时，切牌流程交给 workflow.js
    _webDriven = widget.template.manifest['web_session'] == true;
    for (final u in widget.units) {
      for (final c in u.cards) {
        _webIndex[c.id] = c;
      }
    }
    _session = StudySession(
      widget.units,
      passageClozeEnabled: widget.settings.modePassageCloze,
      retestModes: [
        if (widget.settings.modeChoice) StudyMode.choice,
        if (widget.settings.modeSentenceCloze) StudyMode.cloze,
      ],
    );
    _bridge = WebViewBridge(
        store: widget.store, tts: TtsService(settings: widget.settings));
    _bridge.initTts();
    _bridge.messages.listen(_onMsg);
    if (_webDriven) {
      _bridge.setPlan(SessionPlan.build(
        units: widget.units,
        passageCloze: widget.settings.modePassageCloze,
        retestModes: [
          if (widget.settings.modeChoice) 'choice',
          if (widget.settings.modeSentenceCloze) 'cloze',
        ],
        passageJson: _bridge.passageJson,
      ));
    }
  }

  Future<void> _onMsg(BridgeMessage m) async {
    // 阶段 4：Web 驱动模式下，会话推进全归 workflow.js，壳只执行指令。
    if (_webDriven) {
      await _onMsgWeb(m);
      return;
    }
    // 拼写轮：整轮循环在模板里跑，跑完回报 spellDone
    if (m.type == 'spellDone') {
      _session.endSpell();
      await _resume();
      return;
    }
    if (m.type == 'spellProgress') {
      final d = (m.data['done'] is num) ? (m.data['done'] as num).toInt() : 0;
      _session.setSpellProgress(d);
      if (mounted) setState(() {});
      return;
    }
    if (m.type != 'answer') return;
    // 卡顿根因之一：answer 从 broadcast stream 进来，天然可并发。
    // 两条并发 answer 会各推进一次状态 -> 「点一下没反应、再点跳两页」。
    // 这里串行化：忙就丢，宁可漏一次也不要跳页。
    if (_handling) {
      await SwitchLog.write('switch',
          'DROP answer（上一条还在处理）phase=${_session.phase.name} '
          'done=${_session.doneInRound}/${_session.roundTotal}');
      return;
    }
    final step = _session.current;
    if (step == null) return;

    _handling = true;
    final t0 = DateTime.now();
    try {
      // fromKey 对未知评分会 throw，且 _onMsg 是 async 没有捕获 —— 兜底成 good，
      // 避免一条脏消息把整个会话打断（例如 data-rating="next" 被误回传）。
      Rating rating;
      try {
        rating = Rating.fromKey((m.data['rating'] ?? 'good').toString());
      } catch (_) {
        rating = Rating.good;
      }

      final beforeCard = step.card?.id ?? '-';
      final beforePhase = _session.phase.name;

      switch (_session.phase) {
        case SessionPhase.passage:
          _session.submitPassage();
          break;
        case SessionPhase.passageCloze:
          _session.submitPassageCloze(rating != Rating.again);
          break;
        case SessionPhase.learn:
          _session.submitLearn(rating);
          break;
        case SessionPhase.choice:
        case SessionPhase.cloze:
          _session.submitRetest(step.mode, rating != Rating.again);
          break;
        case SessionPhase.spellPrompt:
        case SessionPhase.spell:
        case SessionPhase.done:
          break;
      }

      await SwitchLog.write('switch',
          'answer $beforePhase/${step.mode.key} rating=${rating.key} card=$beforeCard'
          ' → ${_session.phase.name} done=${_session.doneInRound}/${_session.roundTotal}');

      // 本轮刚毕业 → 这一刻才算「已背」：落盘 + 记今日进度。
      final s = widget.settings;
      final wasPassed = widget.isCard ? s.cardPassed : s.wordPassed;
      for (final cid in _session.graduated) {
        if (_written.contains(cid)) continue;
        _write(cid, _session.ratingFor(cid));
        await s.markDone(card: widget.isCard);
      }
      // 刷新给外部监工（AI）看的 status.json —— 限流，别每张卡都重算全书
      if (_session.graduated.isNotEmpty) {
        StatusWriter.I.writeThrottled();
      }
      // 完成每日背诵量 → 过关 😁
      final nowPassed = widget.isCard ? s.cardPassed : s.wordPassed;
      if (!wasPassed && nowPassed && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.isCard ? '🎉 今日卡牌背诵量已达成，过关！' : '🎉 今日单词背诵量已达成，过关！'),
          backgroundColor: const Color(0xFF00C08B),
          behavior: SnackBarBehavior.floating,
        ));
      }

      if (!mounted) return;
      setState(() {});
      if (_session.finished) return;
      // 一轮走完 → 先问要不要拼写（拼写轮不落 FSRS）
      if (_session.phase == SessionPhase.spellPrompt) {
        await _maybeSpellPrompt();
        return;
      }
      await _load();
      final ms = DateTime.now().difference(t0).inMilliseconds;
      await SwitchLog.write('switch', 'answer 处理完 ${ms}ms');
      await _maybePause();
    } finally {
      _handling = false;
    }
  }

  // ================================================================
  // 阶段 4：Web 驱动 —— 壳只执行 workflow.js 发来的指令
  // ================================================================

  Future<void> _onMsgWeb(BridgeMessage m) async {
    switch (m.type) {
      case 'web.mount':
        await _webMount(m.data);
        break;
      case 'web.spell':
        await _webSpell(m.data);
        break;
      case 'web.spellPrompt':
        await _webSpellPrompt(m.data);
        break;
      case 'web.progress':
        if (mounted) {
          setState(() {
            _webPhase = (m.data['phase'] ?? '').toString();
            _webDone = (m.data['done'] as num?)?.toInt() ?? 0;
            _webTotal = (m.data['total'] as num?)?.toInt() ?? 0;
            _webGraduated = (m.data['graduated'] as num?)?.toInt() ?? 0;
          });
        }
        break;
      case 'web.finish':
        if (mounted) {
          setState(() {
            _webFinished = true;
            _webGraduated =
                (m.data['graduated'] as num?)?.toInt() ?? _webGraduated;
          });
        }
        StatusWriter.I.write();
        break;
    }
  }

  /// workflow.js 要挂某张卡 / 某个语篇
  Future<void> _webMount(Map<String, dynamic> d) async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final unitIdx = (d['unit'] as num?)?.toInt() ?? 0;
    if (unitIdx < 0 || unitIdx >= widget.units.length) return;
    final unit = widget.units[unitIdx];
    final modeKey = (d['mode'] ?? 'read').toString();
    final cardId = (d['cardId'] ?? '').toString();
    final index = (d['index'] as num?)?.toInt() ?? 0;
    final total = (d['total'] as num?)?.toInt() ?? 0;
    final round = (d['round'] as num?)?.toInt() ?? 1;

    FlashCard? card;
    if (cardId.isNotEmpty) {
      for (final c in unit.cards) {
        if (c.id == cardId) {
          card = c;
          break;
        }
      }
      card ??= _webIndex[cardId];
    }

    final isPassage = modeKey == 'passage' || modeKey == 'passage_cloze';
    final stepMode = StudyMode.fromKey(modeKey);
    final choices = (card != null &&
            (stepMode == StudyMode.choice || stepMode == StudyMode.cloze))
        ? _choicesFor(StudyStep(card, stepMode, round))
        : const <Map<String, String>>[];

    await _bridge.mountCard(
      ctrl,
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: card,
      passage: isPassage ? unit.passage : null,
      passageCards: unit.passageLookup,
      blankLemmas: isPassage ? unit.blankLemmas : null,
      index: index,
      total: total,
      session: {
        'phase': modeKey,
        'mode': modeKey,
        'round': round,
        'review': unit.isReview ? 1 : 0,
      },
      choices: choices,
    );
  }

  /// workflow.js 要开拼写轮（给它要拼的卡 id，壳建条目并灌给模板）
  Future<void> _webSpell(Map<String, dynamic> d) async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final ids = (d['cardIds'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final cards = <FlashCard>[];
    for (final id in ids) {
      final c = _webIndex[id];
      if (c != null) cards.add(c);
    }
    final items = _buildSpellItems(cards);
    if (items.isEmpty) {
      await _bridge.emit('web.spellDecision', {'go': false});
      return;
    }
    await _bridge.startSpellRound(ctrl, items);
  }

  /// workflow.js 问「这一轮拼写吗」——壳弹原生弹窗，回执给它
  Future<void> _webSpellPrompt(Map<String, dynamic> d) async {
    final n = (d['count'] as num?)?.toInt() ?? 0;
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title: const Text('这一轮拼写吗？',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text('$n 个词 · 拼错回队尾重来，不计入复习进度',
            style: const TextStyle(color: Color(0xFFB7C4C8), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('跳过', style: TextStyle(color: Color(0xFF8C9DA2))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始拼写',
                style: TextStyle(color: Color(0xFF00C08B))),
          ),
        ],
      ),
    );
    await _bridge.emit('web.spellDecision', {'go': go == true});
  }

  static String _webPhaseLabel(String p) {
    switch (p) {
      case 'passage':
        return '语篇';
      case 'passageCloze':
      case 'passage_cloze':
        return '语篇选词';
      case 'learn':
        return '学习';
      case 'choice':
        return '重测·选义';
      case 'cloze':
        return '重测·填空';
      case 'spellPrompt':
      case 'spell':
        return '拼写';
      case 'done':
        return '完成';
      default:
        return '';
    }
  }

  /// 连续背诵时，每背完一组（20 个）停一下，让用户歇口气再继续。
  /// 只在会话没结束时触发，且每组只弹一次。
  Future<void> _maybePause() async {
    if (_pausing || _session.finished || !mounted) return;
    final n = _session.graduated.length;
    if (n - _pausedAt < kGroupSize) return;
    _pausedAt = n;
    _pausing = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title: Text('已背完 $n 个 🎉',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text('这一组完成，歇一下继续？',
            style: TextStyle(color: Color(0xFFB7C4C8), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续背',
                style: TextStyle(color: Color(0xFF00C08B))),
          ),
        ],
      ),
    );
    _pausing = false;
  }

  // ---------- 拼写轮 ----------

  /// 一轮走完的「要不要拼写」弹窗。不强制，不写 FSRS。
  Future<void> _maybeSpellPrompt() async {
    if (_spellDialogOpen) return;
    if (_session.phase != SessionPhase.spellPrompt) return;
    if (!mounted) return;
    _spellDialogOpen = true;

    final n = _session.spellCards.length;
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title: const Text('这一轮拼写吗？',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text('$n 个词 · 拼错回队尾重来，不计入复习进度',
            style: const TextStyle(color: Color(0xFFB7C4C8), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('跳过', style: TextStyle(color: Color(0xFF8C9DA2))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始拼写',
                style: TextStyle(color: Color(0xFF00C08B))),
          ),
        ],
      ),
    );
    _spellDialogOpen = false;
    if (!mounted) return;

    if (go == true) {
      _session.beginSpell();
      setState(() {});
      await _startSpellRound();
    } else {
      _session.endSpell();
      await _resume();
    }
  }

  /// 拼写轮结束后的「回主线」：可能接着开下一个单元，也可能整场结束
  Future<void> _resume() async {
    if (!mounted) return;
    setState(() {});
    if (_session.finished) return;
    if (_session.phase == SessionPhase.spellPrompt) {
      await _maybeSpellPrompt();
      return;
    }
    await _load();
  }

  Future<void> _startSpellRound() async {
    final ctrl = _controller;
    final items = _buildSpellItems(_session.spellCards);
    if (ctrl == null || items.isEmpty) {
      _session.endSpell();
      await _resume();
      return;
    }
    await _bridge.startSpellRound(ctrl, items);
  }

  /// 中文释义 —— 全部义项都显示
  static String _spellCn(FlashCard c) {
    final full = c.meaningFull.trim();
    return full.isNotEmpty ? full : c.meaningPlain.trim();
  }

  /// 语篇正文（目标词用文中表面形式），语篇拼写用
  static String _passagePlain(Passage p) {
    final sb = StringBuffer();
    for (final s in p.segments) {
      sb.write(s.isWord ? (s.surface ?? '') : (s.text ?? ''));
    }
    return sb.toString();
  }

  /// 这个词在语篇里的表面形式（可能是变形词）
  static String? _passageSurface(Passage p, String word) {
    final lemma = word.trim().toLowerCase();
    for (final s in p.segments) {
      if (!s.isWord) continue;
      if ((s.lemma ?? '').trim().toLowerCase() == lemma) {
        return (s.surface ?? '').trim();
      }
    }
    return null;
  }

  /// 拼这一轮的条目清单：
  ///   有例句 → 句子拼写；没例句 → 单独拼写；在语篇里出现过 → 语篇拼写（排最后）
  ///   标熟的词直接跳过。
  List<Map<String, dynamic>> _buildSpellItems(List<FlashCard> cards) {
    // 卡 -> 它所属单元的语篇
    final passageOf = <String, Passage>{};
    for (final u in _session.units) {
      final p = u.passage;
      if (p == null || !p.hasContent) continue;
      for (final c in u.cards) {
        passageOf[c.id] = p;
      }
    }

    final sentence = <Map<String, dynamic>>[];
    final single = <Map<String, dynamic>>[];
    final passage = <Map<String, dynamic>>[];

    for (final c in cards) {
      if (widget.store.isKnown(c.id)) continue; // 标熟 = 跳过拼写
      final w = c.word.trim();
      if (w.isEmpty) continue;
      final cn = _spellCn(c);

      if (c.hasSentence) {
        sentence.add({
          'kind': 'sentence',
          'id': c.id,
          'word': w,
          'cn': cn,
          'sentence': (c.fields['sentence_en'] ?? '').toString(),
        });
      } else {
        single.add({
          'kind': 'word',
          'id': c.id,
          'word': w,
          'cn': cn,
        });
      }

      final p = passageOf[c.id];
      if (p != null) {
        final surface = _passageSurface(p, w);
        if (surface != null && surface.isNotEmpty) {
          passage.add({
            'kind': 'passage',
            'id': c.id,
            'word': w,
            'cn': cn,
            'passage': _passagePlain(p),
            'surface': surface,
          });
        }
      }
    }
    return <Map<String, dynamic>>[...sentence, ...single, ...passage];
  }

  /// 毕业落盘：这一刻才算「已背」
  void _write(String cardId, Rating r) {
    if (_written.contains(cardId)) return;
    _written.add(cardId);
    final st = widget.store.stateOf(cardId);
    widget.store.putReview(cardId, st, review(st, r), r);
  }

  Future<void> _load() async {
    final step = _session.current;
    final ctrl = _controller;
    if (step == null || ctrl == null || !_ready) return;

    final gen = ++_mountGen;
    final unit = _session.currentUnit;
    final isPassage = _session.phase == SessionPhase.passage ||
        _session.phase == SessionPhase.passageCloze;
    final session = {
      'phase': _session.phase.name,
      'mode': step.mode.key,
      'round': step.round,
      'review': (unit?.isReview ?? false) ? 1 : 0,
    };
    final idx = isPassage ? 0 : _session.doneInRound;
    final total = isPassage ? 1 : _session.roundTotal;

    final t0 = DateTime.now();
    await SwitchLog.write('switch',
        'mount#$gen ← ${_session.phase.name} card=${step.card?.id ?? "passage"} '
        '$idx/$total unit=${_session.unitIndex + 1}/${_session.unitCount}');

    await _bridge.mountCard(
      ctrl,
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: step.card,
      passage: isPassage ? unit?.passage : null,
      passageCards: unit?.passageLookup ?? const [],
      blankLemmas: isPassage ? unit?.blankLemmas : null,
      index: idx,
      total: total,
      session: session,
      choices: _choicesFor(step),
    );

    final ms = DateTime.now().difference(t0).inMilliseconds;
    if (gen != _mountGen) {
      await SwitchLog.write(
          'switch', 'mount#$gen 已过期（当前 #$_mountGen）→ 画面可能是旧的');
      return;
    }
    await SwitchLog.write('switch', 'mount#$gen 完成 ${ms}ms');
  }

  /// 生成干扰项
  ///   choice : 中文义 —— 必须带词性，且带上该项原本的英文单词，便于选错后揭晓
  ///   cloze  : 英文词
  List<Map<String, String>> _choicesFor(StudyStep step) {
    final cur = step.card;
    if (cur == null) return const [];
    // 缺字段的卡直接作废对应考法（会话编排里已过滤，这里再兜一道，
    // 保证界面上永远不会出现「空题干 + 无选项」的死页面）：
    //   没有例句 -> 挖不出空，填空作废
    //   没有词义 -> 出不了选项，选义作废
    if (step.mode == StudyMode.cloze && !cur.hasSentence) return const [];
    if (step.mode == StudyMode.choice && cur.senses.isEmpty) return const [];
    final all = widget.distractorPool;
    final isChoice = step.mode == StudyMode.choice;

    // 选义用「纯中文释义」（剥掉括号里的短语，否则答案直接写在脸上）
    String textOf(FlashCard c) => isChoice
        ? c.meaningPlain
        : (c.fields['word'] ?? c.word).toString().trim();

    // 词性前缀：走 posLabel，多词性自动用 / 连（adj./vt.）
    String posOf(FlashCard c) => isChoice ? c.posLabel : '';

    String wordOf(FlashCard c) => (c.fields['word'] ?? c.word).toString().trim();

    final rightText = textOf(cur);
    if (rightText.isEmpty) return const [];

    final pool = <Map<String, String>>[];
    final seen = <String>{rightText};
    for (final c in all) {
      if (c.id == cur.id) continue;
      final t = textOf(c);
      if (t.isEmpty || seen.contains(t)) continue;
      seen.add(t);
      pool.add({
        'word': wordOf(c),
        'text': t,
        'pos': posOf(c),
        'plain': c.meaningPlain,
        'right': 'false',
      });
    }
    pool.shuffle();

    final opts = <Map<String, String>>[
      {
        'word': wordOf(cur),
        'text': rightText,
        'pos': posOf(cur),
        'plain': cur.meaningPlain,
        'right': 'true',
      },
      ...pool.take(3),
    ]..shuffle();

    return opts;
  }

  @override
  Widget build(BuildContext context) {
    if (_webDriven ? _webFinished : _session.finished) return _finished();

    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: Stack(
                children: [
                  if (_ensure() case final c?) WebViewWidget(controller: c),
                  if (_loading)
                    const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF00C08B), strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 原生顶部：轮次 + 本组进度 + 今日进度
  Widget _topBar() {
    final total = _webDriven ? _webTotal : _session.roundTotal;
    final doneNow = _webDriven ? _webDone : _session.doneInRound;
    final prog = total == 0 ? 0.0 : doneNow / total;
    final today = widget.settings;
    final doneToday = widget.isCard ? today.todayCardDone : today.todayWordDone;
    final limitToday = widget.isCard ? today.cardDailyLimit : today.wordDailyLimit;
    final phaseName = _webDriven
        ? _webPhaseLabel(_webPhase)
        : switch (_session.phase) {
            SessionPhase.passage => '语篇',
            SessionPhase.passageCloze => '语篇选词',
            SessionPhase.learn => '学习',
            SessionPhase.choice => '重测 R${_session.round - 1}·选义',
            SessionPhase.cloze => '重测 R${_session.round - 1}·填空',
            SessionPhase.spellPrompt => '拼写',
            SessionPhase.spell => '拼写',
            SessionPhase.done => '完成',
          };
    final unitLabel = (!_webDriven && _session.unitCount > 1)
        ? '第 ${_session.unitIndex + 1}/${_session.unitCount} 组 · '
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(Icons.arrow_back,
                    color: Color(0xFF8C9DA2), size: 20),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFFF0F4F5),
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
              Text('$unitLabel$phaseName $doneNow/$total',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: prog,
              minHeight: 4,
              backgroundColor: const Color(0x14FFFFFF),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF00C08B)),
            ),
          ),
          const SizedBox(height: 5),
          Text(
              [
                if (!_webDriven &&
                    (_session.currentUnit?.title ?? '').isNotEmpty)
                  _session.currentUnit!.title,
                '毕业 ${_webDriven ? _webGraduated : _session.graduated.length}',
                if (!_webDriven) '待重测 ${_session.retestPoolSize}',
                '今日 $doneToday/$limitToday',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF54666C), fontSize: 11)),
        ],
      ),
    );
  }

  WebViewController? _ensure() {
    if (_controller != null) return _controller!;
    final step = _session.current;
    if (step == null && !_webDriven) return null;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF141D1F))
      ..addJavaScriptChannel(
        'FCChannel',
        onMessageReceived: (msg) => _bridge.handleMessage(msg.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _ready = true;
            if (mounted) setState(() => _loading = false);
            if (_webDriven) {
              // 页面就绪 -> 让 workflow.js 拉计划、自己开跑
              _bridge.emit('web.start');
            } else {
              _load();
            }
          },
        ),
      );
    _controller = c;
    _bridge.attach(c); // 双向 RPC 回执 / 事件推送要用它
    // 骨架页：只在会话开始时 load 一次，之后全走 mountCard
    final html = _bridge.buildCardPage(
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: _webDriven ? null : step?.card,
      index: _webDriven ? 0 : _session.doneInRound,
      total: _webDriven ? 0 : _session.roundTotal,
      session: _webDriven
          ? const <String, dynamic>{}
          : {
              'phase': _session.phase.name,
              'mode': step!.mode.key,
              'round': step.round,
            },
    );
    c.loadHtmlString(html);
    return c;
  }

  Widget _finished() {
    final n = _webDriven ? _webGraduated : _session.graduated.length;
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎉 本轮清空',
                style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 22)),
            const SizedBox(height: 8),
            Text('毕业 $n 张 · 全部标记已背',
                style: const TextStyle(color: Color(0xFF54666C))),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C08B),
                foregroundColor: const Color(0xFF141D1F),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 进后台 / 失焦 -> 通知 Web 层立刻落盘；回前台 -> 通知恢复。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _bridge.emit('lifecycle.pause');
    } else if (state == AppLifecycleState.resumed) {
      _bridge.emit('lifecycle.resume');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 退出会话：写一份完整的 status 快照（尽力而为，不阻塞返回）
    StatusWriter.I.write();
    _bridge.dispose();
    super.dispose();
  }
}
