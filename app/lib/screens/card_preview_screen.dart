/// 单卡预览：从章节词表点进来，只读展示一张卡的「词义页」。
/// ================================================================
/// 刻意**不**用 Flutter 原生重画一套释义 UI —— 那样等于把模板的
/// 义项 / 例句 / 派生词 / 近反义词 / 扩展块 六种渲染逻辑抄第二遍，
/// 以后模板一改就两边分叉。
///
/// 这里走跟背诵完全同一条路：WebView + 同一套模板，
/// 骨架页 -> mountCard 灌这张卡 -> 把状态切到 `back`（词义页），
/// 再打上 `data-preview="1"`，由模板 CSS 把底部动作条 / 进度收起。
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/study_settings.dart';
import '../services/tts_service.dart';
import '../services/webview_bridge.dart';

class CardPreviewScreen extends StatefulWidget {
  final FlashCard card;
  final CardTemplate template;
  final List<String> fieldsOrder;
  final CardStore store;
  final StudySettings settings;

  const CardPreviewScreen({
    super.key,
    required this.card,
    required this.template,
    required this.fieldsOrder,
    required this.store,
    required this.settings,
  });

  @override
  State<CardPreviewScreen> createState() => _CardPreviewScreenState();
}

class _CardPreviewScreenState extends State<CardPreviewScreen> {
  late final WebViewBridge _bridge;
  WebViewController? _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bridge = WebViewBridge(
        store: widget.store, tts: TtsService(settings: widget.settings));
    _bridge.initTts();
  }

  /// 骨架页加载完 -> 挂卡 -> 切到词义页 + 打只读标记
  Future<void> _mount() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    await _bridge.mountCard(
      ctrl,
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: widget.card,
      index: 0,
      total: 1,
      session: const {'phase': 'read', 'mode': 'read', 'round': 1},
    );
    // mount() 结束会把 data-state 重置成 front；预览要的是词义页。
    // data-preview 交给 CSS 收掉所有底部动作条。
    await ctrl.runJavaScript("(function(){"
        "var r=document.querySelector('.fc-root');"
        "if(r){r.setAttribute('data-state','back');r.setAttribute('data-preview','1');}"
        "return 1;})()");
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
          onPageFinished: (_) async {
            if (mounted) setState(() => _loading = false);
            await _mount();
          },
        ),
      );
    _controller = c;
    c.loadHtmlString(_bridge.buildCardPage(
      fieldsOrder: widget.fieldsOrder,
      template: widget.template,
      card: widget.card,
      index: 0,
      total: 1,
      session: const {'phase': 'read', 'mode': 'read', 'round': 1},
    ));
    return c;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: Text(widget.card.word,
            style: const TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _ensure()),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(
                  color: Color(0xFF00C08B), strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }
}
