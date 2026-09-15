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
        _open(b, dueCards, '${b.title} · 复习', k == LibraryKind.card);
        return;
      }
    }
    for (final b in books) {
      final fresh =
          b.allCards.where((c) => !widget.store.isLearned(c.id)).toList();
      if (fresh.isNotEmpty) {
        _open(b, fresh, '${b.title} · 新学', k == LibraryKind.card);
        return;
      }
    }
    _toast('$name今天没有要背的卡片 🎉');
  }

  void _open(Book b, List<FlashCard> cards, String title, bool isCard) {
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
          isCard: isCard,
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
              _streakCard(s),
              const SizedBox(height: 16),
              _progressCard(s),
              const SizedBox(height: 16),
              _weekChart(s),
              const SizedBox(height: 16),
              _taskCard(
                icon: Icons.menu_book,
                title: '单词',
                due: _due(wordBooks),
                fresh: _fresh(wordBooks),
                learned: _learned(wordBooks),
                passed: s.wordPassed,
                onStart: () => _start(LibraryKind.word),
              ),
              const SizedBox(height: 14),
              _taskCard(
                icon: Icons.style,
                title: 'Card',
                due: _due(cardBooks),
                fresh: _fresh(cardBooks),
                learned: _learned(cardBooks),
                passed: s.cardPassed,
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

  /// 连续打卡卡
  Widget _streakCard(StudySettings s) {
    final streak = s.currentStreak;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0x1FFF8A3D),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.local_fire_department,
                color: Color(0xFFFF8A3D), size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('$streak',
                        style: const TextStyle(
                            color: Color(0xFFF0F4F5),
                            fontSize: 26,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(width: 5),
                    const Text('天连续打卡',
                        style:
                            TextStyle(color: Color(0xFF8C9DA2), fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('最长 ${s.bestStreak} 天 · 累计学习 ${s.totalStudyDays} 天',
                    style:
                        const TextStyle(color: Color(0xFF54666C), fontSize: 12)),
              ],
            ),
          ),
          if (s.checkedInToday)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x1F00C08B),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text('今日已打卡',
                  style: TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }

  /// 近 7 天柱状图
  Widget _weekChart(StudySettings s) {
    final days = s.recentDays(7);
    var maxV = 1;
    for (final d in days) {
      final v = (d['word'] as int) + (d['card'] as int);
      if (v > maxV) maxV = v;
    }
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
              const Text('近 7 天',
                  style: TextStyle(
                      color: Color(0xFFF0F4F5),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              Text('累计 ${s.totalWordDone + s.totalCardDone} 张',
                  style:
                      const TextStyle(color: Color(0xFF54666C), fontSize: 12)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: days.map((d) {
                final total = (d['word'] as int) + (d['card'] as int);
                final h = total == 0 ? 4.0 : (total / maxV) * 62.0;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(total == 0 ? '' : '$total',
                          style: const TextStyle(
                              color: Color(0xFF8C9DA2), fontSize: 10)),
                      const SizedBox(height: 3),
                      Container(
                        height: h,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: total == 0
                              ? const Color(0x14FFFFFF)
                              : const Color(0xFF00C08B),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(d['label'] as String,
                          style: const TextStyle(
                              color: Color(0xFF54666C), fontSize: 10)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
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
          const Text('今日进度',
              style: TextStyle(
                  color: Color(0xFFF0F4F5),
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          _progressRow('单词', s.todayWordDone, s.wordDailyLimit, s.wordProgress,
              s.wordPassed),
          const SizedBox(height: 12),
          _progressRow('卡牌', s.todayCardDone, s.cardDailyLimit, s.cardProgress,
              s.cardPassed),
        ],
      ),
    );
  }

  Widget _progressRow(
      String label, int done, int limit, double prog, bool passed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(label,
                    style: const TextStyle(
                        color: Color(0xFF8C9DA2), fontSize: 13)),
                if (passed) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x1F00C08B),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('已过关 😁',
                        style: TextStyle(
                            color: Color(0xFF00C08B),
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
            Text('$done / $limit',
                style: TextStyle(
                    color: passed
                        ? const Color(0xFF00C08B)
                        : const Color(0xFFF0F4F5),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: prog,
            minHeight: 6,
            backgroundColor: const Color(0x14FFFFFF),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF00C08B)),
          ),
        ),
      ],
    );
  }

  Widget _taskCard({
    required IconData icon,
    required String title,
    required int due,
    required int fresh,
    required int learned,
    required bool passed,
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
                    Row(
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Color(0xFFF0F4F5),
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        if (passed) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0x1F00C08B),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text('已过关 😁',
                                style: TextStyle(
                                    color: Color(0xFF00C08B),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
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
