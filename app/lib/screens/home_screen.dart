/// 首页：今日总览 + 快捷开始
library;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/deck_repository.dart';
import '../services/study_settings.dart';
import 'library_screen.dart';
import 'review_screen.dart';

class HomeScreen extends StatefulWidget {
  final DeckRepository repo;
  final Map<String, CardTemplate> templates;
  final CardStore store;
  final StudySettings settings;

  const HomeScreen({
    super.key,
    required this.repo,
    required this.templates,
    required this.store,
    required this.settings,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  List<Book>? _books;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final all = await widget.repo.loadAllBooks();
    if (!mounted) return;
    setState(() => _books = all);
  }

  List<Book> _ofKind(LibraryKind k) => (_books ?? [])
      .where((b) => kindOfBook(b, widget.templates) == k)
      .toList();

  int _due(List<Book> books) {
    var n = 0;
    for (final b in books) {
      n += widget.store.reviewDueCount(b.allCards.map((c) => c.id).toList());
    }
    return n;
  }

  int _fresh(List<Book> books) {
    var n = 0;
    for (final b in books) {
      n += b.allCards.where((c) => !widget.store.isLearned(c.id)).length;
    }
    return n;
  }

  int _learned(List<Book> books) {
    var n = 0;
    for (final b in books) {
      n += widget.store.countLearned(b.allCards.map((c) => c.id).toList());
    }
    return n;
  }

  /// 开始某一类的背诵：优先复习到期，其次新学
  void _start(LibraryKind k) {
    final books = _ofKind(k);
    final name = k == LibraryKind.word ? '单词' : 'Card';
    if (books.isEmpty) {
      _toast('还没有$name内容，去「$name」页导入');
      return;
    }
    for (final b in books) {
      final ids = b.allCards.map((c) => c.id).toList();
      final dueIds = widget.store.reviewDue(ids).toSet();
      if (dueIds.isNotEmpty) {
        final dueCards =
            b.allCards.where((c) => dueIds.contains(c.id)).toList();
        _open(b, dueCards, '${b.title} · 复习');
        return;
      }
    }
    for (final b in books) {
      final fresh =
          b.allCards.where((c) => !widget.store.isLearned(c.id)).toList();
      if (fresh.isNotEmpty) {
        _open(b, fresh, '${b.title} · 新学');
        return;
      }
    }
    _toast('$name今天没有要背的卡片 🎉');
  }

  void _open(Book b, List<FlashCard> cards, String title) {
    final tpl = widget.templates[b.templateId];
    if (tpl == null) {
      _toast('模板缺失：${b.templateId}');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          title: title,
          cards: cards,
          book: b,
          template: tpl,
          store: widget.store,
          settings: widget.settings,
          passage: b.passage,
        ),
      ),
    ).then((_) => refresh());
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: const Color(0xFF1B2629),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final wordBooks = _ofKind(LibraryKind.word);
    final cardBooks = _ofKind(LibraryKind.card);

    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          color: const Color(0xFF00C08B),
          backgroundColor: const Color(0xFF1B2629),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              const Text('首页',
                  style: TextStyle(
                      color: Color(0xFFF0F4F5),
                      fontWeight: FontWeight.w700,
                      fontSize: 26)),
              const SizedBox(height: 4),
              Text(_todayLabel(),
                  style:
                      const TextStyle(color: Color(0xFF54666C), fontSize: 13)),
              const SizedBox(height: 20),
              _progressCard(s),
              const SizedBox(height: 16),
              _taskCard(
                icon: Icons.menu_book,
                title: '单词',
                due: _due(wordBooks),
                fresh: _fresh(wordBooks),
                learned: _learned(wordBooks),
                onStart: () => _start(LibraryKind.word),
              ),
              const SizedBox(height: 14),
              _taskCard(
                icon: Icons.style,
                title: 'Card',
                due: _due(cardBooks),
                fresh: _fresh(cardBooks),
                learned: _learned(cardBooks),
                onStart: () => _start(LibraryKind.card),
              ),
              const SizedBox(height: 20),
              const Text('快捷入口',
                  style: TextStyle(
                      color: Color(0xFF8C9DA2),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              _shortcut(
                icon: Icons.star_border,
                label: '生词本',
                sub: '收藏的单词（开发中）',
                onTap: () => _toast('生词本还在建设中 ⭐'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _todayLabel() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Widget _progressCard(StudySettings s) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('今日进度',
                  style: TextStyle(
                      color: Color(0xFFF0F4F5),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              Text('${s.todayDone} / ${s.dailyLimit}',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: s.todayProgress,
              minHeight: 6,
              backgroundColor: const Color(0x14FFFFFF),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF00C08B)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _taskCard({
    required IconData icon,
    required String title,
    required int due,
    required int fresh,
    required int learned,
    required VoidCallback onStart,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0x1F00C08B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF00C08B), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: Color(0xFFF0F4F5),
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('到期 $due · 新学 $fresh · 已掌握 $learned',
                        style: const TextStyle(
                            color: Color(0xFF54666C), fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C08B),
                foregroundColor: const Color(0xFF141D1F),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: onStart,
              child: Text(due > 0 ? '开始复习（$due）' : '开始背诵',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcut({
    required IconData icon,
    required String label,
    required String sub,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00C08B), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Color(0xFFF0F4F5), fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: const TextStyle(
                          color: Color(0xFF54666C), fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF54666C)),
          ],
        ),
      ),
    );
  }
}
