/// 页面列表：每一页 = 一张卡。顶部可选「顺序背诵 / 乱序背诵」
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/study_plan.dart';
import '../services/study_settings.dart';
import 'review_screen.dart';

/// 某一章的页面列表（带自己的 AppBar）
class PageListScreen extends StatelessWidget {
  final String title;
  final List<FlashCard> cards;
  final Book book;
  final CardTemplate? template;
  final CardStore store;
  final StudySettings settings;
  final Passage? passage;

  const PageListScreen({
    super.key,
    required this.title,
    required this.cards,
    required this.book,
    required this.template,
    required this.store,
    required this.settings,
    this.passage,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: Text(title,
            style: const TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: PageListBody(
        title: title,
        cards: cards,
        book: book,
        template: template,
        store: store,
        settings: settings,
        passage: passage,
      ),
    );
  }
}

/// 可复用的页面列表 body：无章节时直接嵌进 BookDetailScreen
class PageListBody extends StatelessWidget {
  final String title;
  final List<FlashCard> cards;
  final Book book;
  final CardTemplate? template;
  final CardStore store;
  final StudySettings settings;
  final Passage? passage;

  const PageListBody({
    super.key,
    required this.title,
    required this.cards,
    required this.book,
    required this.template,
    required this.store,
    required this.settings,
    this.passage,
  });

  void _startReview(BuildContext context, bool shuffle) {
    if (template == null) return;
    // 只背没学过的卡，已背过的不重复
    final list = cards.where((c) => !store.isLearned(c.id)).toList();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('本章新词已背完，去顶部「开始复习」巩固'),
        backgroundColor: Color(0xFF1B2629),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (shuffle) list.shuffle(math.Random());

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          title: title,
          units: [
            StudyPlanner.singleUnit(
              passage: passage,
              cards: list,
              passageCards: cards,
              readFirst: true,
            ),
          ],
          template: template!,
          fieldsOrder: book.fieldsOrder,
          distractorPool: cards,
          store: store,
          settings: settings,
          isCard: template!.engine == 'srs_basic',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _startBar(context),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: cards.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _pageTile(context, i),
          ),
        ),
      ],
    );
  }

  Widget _startBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _startBtn(
              context,
              icon: Icons.format_list_numbered,
              label: '顺序背诵',
              onTap: () => _startReview(context, false),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _startBtn(
              context,
              icon: Icons.shuffle,
              label: '乱序背诵',
              onTap: () => _startReview(context, true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _startBtn(BuildContext context,
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0x1F00C08B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x3300C08B)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: const Color(0xFF00C08B), size: 18),
            const SizedBox(width: 7),
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF00C08B),
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _pageTile(BuildContext context, int i) {
    final card = cards[i];
    final learned = store.isLearned(card.id);
    final phonetic = (card.fields['phonetic_us'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x10FFFFFF)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('${i + 1}',
                style: const TextStyle(
                    color: Color(0xFF54666C),
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(card.word,
                    style: const TextStyle(
                        color: Color(0xFFF0F4F5),
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600)),
                if (phonetic.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(phonetic,
                      style: const TextStyle(
                          color: Color(0xFF54666C), fontSize: 12)),
                ],
              ],
            ),
          ),
          if (learned)
            const Icon(Icons.check_circle,
                color: Color(0xFF00C08B), size: 18)
          else
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x33FFFFFF), width: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
