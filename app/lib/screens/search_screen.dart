/// 搜索：跨所有「单词」书搜单词 / 释义。
/// ================================================================
/// 从「单词」页左上角进入。数据量不大时直接全量载入 + 本地过滤，
/// 不建索引；命中的卡点开复用 CardPreviewScreen（同一套模板词义页）。
library;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/deck_repository.dart';
import '../services/study_settings.dart';
import 'card_preview_screen.dart';

/// 一条命中：卡片 + 它所属的书 / 模板（预览要用书的 fieldsOrder）
class _Hit {
  final Book book;
  final CardTemplate template;
  final FlashCard card;

  _Hit(this.book, this.template, this.card);
}

class SearchScreen extends StatefulWidget {
  final DeckRepository repo;
  final Map<String, CardTemplate> templates;
  final CardStore store;
  final StudySettings settings;

  const SearchScreen({
    super.key,
    required this.repo,
    required this.templates,
    required this.store,
    required this.settings,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<_Hit> _all = const [];
  List<_Hit> _hits = const [];
  String _q = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 只索引「单词」书：engine == srs_basic 的 Card 不进来
  Future<void> _load() async {
    final books = await widget.repo.loadAllBooks();
    final out = <_Hit>[];
    for (final b in books) {
      final tpl = widget.templates[b.templateId];
      if (tpl == null || tpl.engine == 'srs_basic') continue;
      for (final c in b.allCards) {
        out.add(_Hit(b, tpl, c));
      }
    }
    if (!mounted) return;
    setState(() {
      _all = out;
      _loading = false;
      _hits = _filter(out, _q);
    });
  }

  List<_Hit> _filter(List<_Hit> all, String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return const <_Hit>[];
    final out = <_Hit>[];
    for (final h in all) {
      final w = h.card.word.toLowerCase();
      if (w.contains(s) ||
          h.card.meaningFull.toLowerCase().contains(s) ||
          h.card.meaningPlain.toLowerCase().contains(s)) {
        out.add(h);
      }
    }
    // 前缀命中的排前面，其次按字母序
    out.sort((a, b) {
      final aw = a.card.word.toLowerCase();
      final bw = b.card.word.toLowerCase();
      final ap = aw.startsWith(s) ? 0 : 1;
      final bp = bw.startsWith(s) ? 0 : 1;
      if (ap != bp) return ap - bp;
      return aw.compareTo(bw);
    });
    return out;
  }

  void _onChanged(String v) {
    setState(() {
      _q = v;
      _hits = _filter(_all, v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(color: Color(0xFFF0F4F5), fontSize: 16),
          cursorColor: const Color(0xFF00C08B),
          decoration: const InputDecoration(
            hintText: '搜单词 / 释义',
            hintStyle: TextStyle(color: Color(0xFF54666C), fontSize: 15),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_q.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: Color(0xFF8C9DA2)),
              tooltip: '清空',
              onPressed: () {
                _controller.clear();
                _onChanged('');
              },
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
            color: Color(0xFF00C08B), strokeWidth: 2),
      );
    }
    if (_q.trim().isEmpty) {
      return const Center(
        child: Text('输入单词或中文释义开始搜索',
            style: TextStyle(color: Color(0xFF54666C), fontSize: 13)),
      );
    }
    if (_hits.isEmpty) {
      return const Center(
        child: Text('没有匹配的单词',
            style: TextStyle(color: Color(0xFF54666C), fontSize: 13)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _hits.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _tile(_hits[i]),
    );
  }

  Widget _tile(_Hit h) {
    final card = h.card;
    final pos = card.posLabel;
    final phonetic =
        (card.fields['phonetic_us'] ?? card.fields['phonetic_uk'] ?? '')
            .toString();
    final meaning = card.meaningFull;
    final known = widget.store.isKnown(card.id);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CardPreviewScreen(
            card: card,
            template: h.template,
            fieldsOrder: h.book.fieldsOrder,
            store: widget.store,
            settings: widget.settings,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: const Color(0x08FFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x10FFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(card.word,
                      style: const TextStyle(
                          color: Color(0xFFF0F4F5),
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600)),
                ),
                if (pos.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0x1F00C08B),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(pos,
                        style: const TextStyle(
                            color: Color(0xFF00C08B), fontSize: 10.5)),
                  ),
                ],
                const Spacer(),
                if (known)
                  const Text('熟',
                      style: TextStyle(
                          color: Color(0xFF00C08B),
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
              ],
            ),
            if (phonetic.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(phonetic,
                  style: const TextStyle(
                      color: Color(0xFF54666C), fontSize: 12)),
            ],
            if (meaning.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(meaning,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF8C9DA2), fontSize: 12.5, height: 1.35)),
            ],
            const SizedBox(height: 5),
            Text(h.book.title,
                style: const TextStyle(color: Color(0xFF54666C), fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
