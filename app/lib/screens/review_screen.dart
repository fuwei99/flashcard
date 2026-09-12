/// 背诵模式：顶部原生进度条 + 全屏 WebView 卡牌
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
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
  WebViewController? _controller;
  int _done = 0;      // 本组已完成
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bridge = WebViewBridge(store: widget.store);
    _bridge.initTts();
    _bridge.messages.listen(_onMsg);
  }

  Future<void> _onMsg(BridgeMessage m) async {
    if (m.type == 'answer') {
      await widget.settings.markDone();
      _next();
    } else if (m.type == 'next') {
      _next();
    } else if (m.type == 'prev' || m.type == 'undo') {
      if (_done > 0) {
        setState(() => _done--);
        _load();
      }
    }
  }

  void _next() {
    if (_done + 1 >= widget.cards.length) {
      setState(() => _done = widget.cards.length);
      return;
    }
    setState(() => _done++);
    _load();
  }

  FlashCard? get _current =>
      _done < widget.cards.length ? widget.cards[_done] : null;

  void _load() {
    final card = _current;
    final ctrl = _controller;
    if (card == null || ctrl == null) return;
    final html = _bridge.buildCardPage(
      book: widget.book,
      template: widget.template,
      card: card,
      index: _done,
      total: widget.cards.length,
    );
    ctrl.loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) {
    if (_done >= widget.cards.length) return _finished();

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

  /// 原生顶部：本组进度 + 今日进度
  Widget _topBar() {
    final total = widget.cards.length;
    final prog = total == 0 ? 0.0 : _done / total;
    final today = widget.settings;

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
              Text('已背 $_done / $total',
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
          Text('今日 ${today.todayDone} / ${today.dailyLimit}',
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
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎉 本组背完',
                style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 22)),
            const SizedBox(height: 8),
            Text('共 ${widget.cards.length} 页',
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
