/// 书内页：有章节 -> 章节目录（文件夹）；无章节 -> 直接页面列表
library;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/study_settings.dart';
import 'page_list_screen.dart';

class BookDetailScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: Text(book.title,
            style: const TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: book.hasChapters
          ? _chapterList(context)
          : PageListBody(
              title: book.title,
              cards: book.allCards,
              book: book,
              template: template,
              store: store,
              settings: settings,
            ),
    );
  }

  Widget _chapterList(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: book.chapters.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        final ch = book.chapters[i];
        final ids = ch.cards.map((c) => c.id).toList();
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
                template: template,
                store: store,
                settings: settings,
              ),
            ),
          ),
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
