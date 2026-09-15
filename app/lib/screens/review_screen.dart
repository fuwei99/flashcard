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

import '../models/deck.dart';
import '../models/study_session.dart';
import '../services/card_store.dart';
import '../services/scheduler.dart';
import '../services/study_plan.dart';
import '../services/study_settings.dart';
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

class _ReviewScreenState extends State<ReviewScreen> {
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

  @override
  void initState() {
    super.initState();
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
  }

  Future<void> _onMsg(BridgeMessage m) async {
    if (m.type != 'answer') return;
    final step = _session.current;
    if (step == null) return;

    // fromKey 对未知评分会 throw，且 _onMsg 是 async 没有捕获 —— 兜底成 good，
    // 避免一条脏消息把整个会话打断（例如 data-rating="next" 被误回传）。
    Rating rating;
    try {
      rating = Rating.fromKey((m.data['rating'] ?? 'good').toString());
    } catch (_) {
      rating = Rating.good;
    }

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
      case SessionPhase.done:
        break;
    }

    // 本轮刚毕业 → 这一刻才算「已背」：落盘 + 记今日进度。
    final s = widget.settings;
    final wasPassed = widget.isCard ? s.cardPassed : s.wordPassed;
    for (final cid in _session.graduated) {
      if (_written.contains(cid)) continue;
      _write(cid, _session.ratingFor(cid));
      await s.markDone(card: widget.isCard);
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
    _load();
    await _maybePause();
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

  /// 毕业落盘：这一刻才算「已背」
  void _write(String cardId, Rating r) {
    if (_written.contains(cardId)) return;
    _written.add(cardId);
    final st = widget.store.stateOf(cardId);
    widget.store.putState(cardId, review(st, r));
  }

  void _load() {
    final step = _session.current;
    final ctrl = _controller;
    if (step == null || ctrl == null || !_ready) return;

    final unit = _session.currentUnit;
    final isPassage = _session.phase == SessionPhase.passage ||
        _session.phase == SessionPhase.passageCloze;
    final session = {
      'phase': _session.phase.name,
      'mode': step.mode.key,
      'round': step.round,
      'review': (unit?.isReview ?? false) ? 1 : 0,
    };

    _bridge.mountCard(
      ctrl,
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: step.card,
      passage: isPassage ? unit?.passage : null,
      passageCards: unit?.passageLookup ?? const [],
      blankLemmas: isPassage ? unit?.blankLemmas : null,
      index: isPassage ? 0 : _session.doneInRound,
      total: isPassage ? 1 : _session.roundTotal,
      session: session,
      choices: _choicesFor(step),
    );
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
    if (_session.finished) return _finished();

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
    final total = _session.roundTotal;
    final prog = total == 0 ? 0.0 : _session.doneInRound / total;
    final today = widget.settings;
    final doneToday = widget.isCard ? today.todayCardDone : today.todayWordDone;
    final limitToday = widget.isCard ? today.cardDailyLimit : today.wordDailyLimit;
    final phaseName = switch (_session.phase) {
      SessionPhase.passage => '语篇',
      SessionPhase.passageCloze => '语篇选词',
      SessionPhase.learn => '学习',
      SessionPhase.choice => '重测 R${_session.round - 1}·选义',
      SessionPhase.cloze => '重测 R${_session.round - 1}·填空',
      SessionPhase.done => '完成',
    };
    final unitLabel = _session.unitCount > 1
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
              Text('$unitLabel$phaseName ${_session.doneInRound}/$total',
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
                if ((_session.currentUnit?.title ?? '').isNotEmpty)
                  _session.currentUnit!.title,
                '毕业 ${_session.graduated.length}',
                '待重测 ${_session.retestPoolSize}',
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
    if (step == null) return null;
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
            _load();
          },
        ),
      );
    _controller = c;
    // 骨架页：只在会话开始时 load 一次，之后全走 mountCard
    final html = _bridge.buildCardPage(
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: step.card,
      index: _session.doneInRound,
      total: _session.roundTotal,
      session: {
        'phase': _session.phase.name,
        'mode': step.mode.key,
        'round': step.round,
      },
    );
    c.loadHtmlString(html);
    return c;
  }

  Widget _finished() {
    final n = _session.graduated.length;
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
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }
}
