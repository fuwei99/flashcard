/// 背诵模式：会话状态机驱动 + 全屏 WebView 卡牌
/// ================================================================
/// 轮内流程交给 StudySession；只有「毕业」才写 CardStore（= 标记已背）。
/// 忘记 / 模糊 只记在会话内存里，不落盘。
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import '../services/card_store.dart';
import '../services/scheduler.dart';
import '../services/study_settings.dart';
import '../services/webview_bridge.dart';

class ReviewScreen extends StatefulWidget {
  final String title;
  final List<FlashCard> cards;
  final Book book;
  final CardTemplate template;
  final CardStore store;
  final StudySettings settings;

  const ReviewScreen({
    super.key,
    required this.title,
    required this.cards,
    required this.book,
    required this.template,
    required this.store,
    required this.settings,
  });

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final WebViewBridge _bridge;
  late final StudySession _session;
  WebViewController? _controller;
  bool _loading = true;

  /// 已写入 FSRS 的卡，避免重复落盘
  final Set<String> _written = {};

  @override
  void initState() {
    super.initState();
    _session = StudySession(widget.cards);
    _bridge = WebViewBridge(store: widget.store);
    _bridge.initTts();
    _bridge.messages.listen(_onMsg);
  }

  Future<void> _onMsg(BridgeMessage m) async {
    if (m.type != 'answer') return;
    final step = _session.current;
    if (step == null) return;

    final rating = Rating.fromKey((m.data['rating'] ?? 'good').toString());
    final id = step.card.id;

    if (_session.phase == SessionPhase.learn) {
      _session.submitLearn(rating);
    } else {
      _session.submitRetest(step.mode, rating != Rating.again);
    }

    // 本轮刚毕业 → 这一刻才算「已背」：落盘 + 记今日进度。
    // 评分不是恒定的 good，而是 StudySession 按本轮挣扎程度算出来的
    // （一次过 good / 费劲 hard / 硬骨头 again），三档终于真的进了 FSRS。
    if (_session.graduated.contains(id) && !_written.contains(id)) {
      _write(id, _session.ratingFor(id));
      await widget.settings.markDone();
    }

    if (!mounted) return;
    setState(() {});
    if (!_session.finished) _load();
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
    if (step == null || ctrl == null) return;
    final html = _bridge.buildCardPage(
      book: widget.book,
      template: widget.template,
      card: step.card,
      index: _session.doneInRound,
      total: _session.roundTotal,
      session: {
        'phase': _session.phase.name,
        'mode': step.mode.key,
        'round': step.round,
      },
      choices: _choicesFor(step),
    );
    ctrl.loadHtmlString(html);
  }

  /// 生成干扰项：choice 用中文义，cloze 用英文词
  List<Map<String, String>> _choicesFor(StudyStep step) {
    final all = widget.book.allCards;
    final cur = step.card;
    final key = step.mode == StudyMode.choice ? 'meaning' : 'word';
    final right = (cur.fields[key] ?? cur.word).toString();

    final pool = <String>[];
    for (final c in all) {
      if (c.id == cur.id) continue;
      final v = (c.fields[key] ?? c.word).toString();
      if (v.isNotEmpty && v != right && !pool.contains(v)) pool.add(v);
    }
    pool.shuffle();

    final opts = <String>[right, ...pool.take(3)]..shuffle();
    return opts
        .map((t) => {'text': t, 'right': (t == right).toString()})
        .toList();
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
                  WebViewWidget(controller: _ensure()),
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
    final phaseName = _session.phase == SessionPhase.learn
        ? '学习'
        : '重测 R${_session.round - 1}';

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
              Text('$phaseName ${_session.doneInRound}/$total',
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
              '毕业 ${_session.graduated.length} · 待重测 ${_session.retestPoolSize} · 今日 ${today.todayDone}/${today.dailyLimit}',
              style: const TextStyle(color: Color(0xFF54666C), fontSize: 11)),
        ],
      ),
    );
  }

  WebViewController _ensure() {
    if (_controller != null) return _controller!;
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
            if (mounted) setState(() => _loading = false);
          },
        ),
      );
    _controller = c;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
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
