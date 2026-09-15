/// 书内页：顶部「开始复习」入口 + 章节/页面列表
/// 有章节 -> 章节目录（文件夹）；无章节 -> 直接页面列表
library;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';
import '../services/card_store.dart';
import '../services/study_plan.dart';
import '../services/study_settings.dart';
import 'page_list_screen.dart';
import 'review_screen.dart';

class BookDetailScreen extends StatefulWidget {
  final Book book;
  final CardTemplate? template;
  final CardStore store;
  final StudySettings settings;

  const BookDetailScreen({
    super.key,
    required this.book,
    required this.template,
    required this.store,
    required this.settings,
  });

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  // ---------- 复习：按 FSRS 到期队列 ----------
  void _startReview() {
    final tpl = widget.template;
    if (tpl == null) return;

    final units = StudyPlanner.wordPlan(
      books: [widget.book],
      store: widget.store,
      withReview: true,
      withNew: false,
    );

    if (units.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('今日没有要复习的卡片'),
        backgroundColor: Color(0xFF1B2629),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          title: '${widget.book.title} · 复习',
          units: units,
          template: tpl,
          fieldsOrder: widget.book.fieldsOrder,
          distractorPool: _poolFromUnits(units),
          store: widget.store,
          settings: widget.settings,
          isCard: tpl.engine == 'srs_basic',
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// 干扰项池：只从**已经载入的**单元里取
  List<FlashCard> _poolFromUnits(List<StudyUnit> units) {
    final out = <FlashCard>[];
    final seen = <String>{};
    for (final u in units) {
      final src = u.passageCards ?? u.cards;
      for (final c in src) {
        if (seen.add(c.id)) out.add(c);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final allIds = widget.book.allCardIds;
    final dueCount = widget.store.reviewDueCount(allIds);

    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: Text(widget.book.title,
            style: const TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: Column(
        children: [
          _reviewBar(dueCount),
          Expanded(
            child: widget.book.hasChapters
                ? _chapterList(context)
                : PageListBody(
                    title: widget.book.title,
                    cards: widget.book.allCards,
                    book: widget.book,
                    template: widget.template,
                    store: widget.store,
                    settings: widget.settings,
                  ),
          ),
        ],
      ),
    );
  }

  /// 顶部复习栏：直接显示今日待复习数量
  Widget _reviewBar(int dueCount) {
    final enabled = dueCount > 0 && widget.template != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? _startReview : null,
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: enabled ? const Color(0x1F00C08B) : const Color(0x08FFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: enabled
                    ? const Color(0x3300C08B)
                    : const Color(0x14FFFFFF)),
          ),
          child: Row(
            children: [
              Icon(Icons.refresh,
                  color: enabled
                      ? const Color(0xFF00C08B)
                      : const Color(0xFF54666C),
                  size: 20),
              const SizedBox(width: 10),
              Text('开始复习',
                  style: TextStyle(
                      color: enabled
                          ? const Color(0xFFF0F4F5)
                          : const Color(0xFF54666C),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: enabled
                      ? const Color(0xFF00C08B)
                      : const Color(0x14FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('$dueCount',
                    style: TextStyle(
                        color: enabled
                            ? const Color(0xFF141D1F)
                            : const Color(0xFF54666C),
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
              Text('待复习',
                  style: TextStyle(
                      color: enabled
                          ? const Color(0xFF00C08B)
                          : const Color(0xFF54666C),
                      fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chapterList(BuildContext context) {
    final book = widget.book;
    final store = widget.store;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: book.chapters.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final ch = book.chapters[i];
        final ids = ch.ids;
        final learned = store.countLearned(ids);
        final total = ids.length;
        final progress = total == 0 ? 0.0 : learned / total;

        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PageListScreen(
                title: ch.title,
                cards: ch.cards,
                book: book,
                template: widget.template,
                store: store,
                settings: widget.settings,
                passage: ch.passage,
              ),
            ),
          ).then((_) {
            if (mounted) setState(() {});
          }),
          child: Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: const Color(0x0BFFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0x1F00C08B),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(Icons.folder_outlined,
                      color: Color(0xFF00C08B), size: 22),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ch.title,
                          style: const TextStyle(
                              color: Color(0xFFF0F4F5),
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('$total 页 · 已背 $learned',
                          style: const TextStyle(
                              color: Color(0xFF54666C), fontSize: 12)),
                      const SizedBox(height: 7),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: const Color(0x14FFFFFF),
                          valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF00C08B)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right, color: Color(0xFF00C08B)),
              ],
            ),
          ),
        );
      },
    );
  }
}
