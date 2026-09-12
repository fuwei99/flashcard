/// 书架：所有书一目了然，点进去
library;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/study_settings.dart';
import 'book_detail_screen.dart';
import 'settings_screen.dart';

class BookShelfScreen extends StatelessWidget {
  final List<Book> books;
  final Map<String, CardTemplate> templates;
  final CardStore store;
  final StudySettings settings;

  const BookShelfScreen({
    super.key,
    required this.books,
    required this.templates,
    required this.store,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        title: const Text('书架',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Color(0xFF8C9DA2)),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(settings: settings),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _todayBar(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: books.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (context, i) => _bookTile(context, books[i]),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部今日进度条
  Widget _todayBar() {
    final s = settings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('今日进度',
                  style: TextStyle(color: Color(0xFF54666C), fontSize: 12)),
              Text('${s.todayDone} / ${s.dailyLimit}',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: s.todayProgress,
              minHeight: 5,
              backgroundColor: const Color(0x14FFFFFF),
              valueColor:
                  const AlwaysStoppedAnimation(Color(0xFF00C08B)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bookTile(BuildContext context, Book book) {
    final ids = book.allCards.map((c) => c.id).toList();
    final learned = store.countLearned(ids);
    final total = ids.length;
    final progress = total == 0 ? 0.0 : learned / total;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookDetailScreen(
            book: book,
            template: templates[book.templateId],
            store: store,
            settings: settings,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
            // 书脊色块
            Container(
              width: 46,
              height: 62,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF00C08B), Color(0xFF0A6B52)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.menu_book,
                  color: Color(0xFF141D1F), size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      style: const TextStyle(
                          color: Color(0xFFF0F4F5),
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                    book.hasChapters
                        ? '${book.chapters.length} 章 · 共 $total 页'
                        : '共 $total 页',
                    style: const TextStyle(
                        color: Color(0xFF54666C), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 5),
                  Text('已背 $learned / $total',
                      style: const TextStyle(
                          color: Color(0xFF8C9DA2), fontSize: 11.5)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF00C08B)),
          ],
        ),
      ),
    );
  }
}
