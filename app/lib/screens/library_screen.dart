/// 书架（单词 / Card 共用）
/// ================================================================
/// 同一套「书 → 章 → 页」导航，按模板引擎过滤出两类内容：
///   language  -> 单词 Tab（英语背诵）
///   srs_basic -> Card Tab（Anki 式）
library;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/deck_repository.dart';
import '../services/study_settings.dart';
import '../services/transfer_service.dart';
import 'book_detail_screen.dart';
import 'search_screen.dart';

/// 书架的两种归类
enum LibraryKind { word, card }

/// 一本书属于哪个书架：看它绑定的模板引擎。
/// 没写 engine 的模板一律当英语书（language）。
LibraryKind kindOfBook(Book book, Map<String, CardTemplate> templates) {
  final engine = templates[book.templateId]?.engine ?? 'language';
  return engine == 'srs_basic' ? LibraryKind.card : LibraryKind.word;
}

class LibraryScreen extends StatefulWidget {
  final LibraryKind kind;
  final DeckRepository repo;
  final Map<String, CardTemplate> templates;
  final CardStore store;
  final StudySettings settings;

  const LibraryScreen({
    super.key,
    required this.kind,
    required this.repo,
    required this.templates,
    required this.store,
    required this.settings,
  });

  @override
  State<LibraryScreen> createState() => LibraryScreenState();
}

class LibraryScreenState extends State<LibraryScreen> {
  List<Book>? _books;

  String get _title => widget.kind == LibraryKind.word ? '单词' : 'Card';

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final all = await widget.repo.loadAllBooks();
    final filtered = all
        .where((b) => kindOfBook(b, widget.templates) == widget.kind)
        .toList();
    if (!mounted) return;
    setState(() => _books = filtered);
  }

  // ---------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------
  Future<void> _import() async {
    try {
      final preview = await TransferService.pickAndParse();
      if (preview == null || !mounted) return;

      bool withProgress = false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            backgroundColor: const Color(0xFF1B2629),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18)),
            title: const Text('导入卡片',
                style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 17)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('《${preview.book.title}》',
                    style: const TextStyle(
                        color: Color(0xFF00C08B),
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  '${preview.book.totalPages} 页'
                  '${preview.book.hasChapters ? " · ${preview.book.chapters.length} 章" : ""}',
                  style: const TextStyle(
                      color: Color(0xFF8C9DA2), fontSize: 13),
                ),
                const SizedBox(height: 14),
                if (preview.hasProgress)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: const Color(0xFF00C08B),
                    checkColor: const Color(0xFF141D1F),
                    value: withProgress,
                    onChanged: (v) => setD(() => withProgress = v ?? false),
                    title: const Text('同时导入背诵进度',
                        style:
                            TextStyle(color: Color(0xFFF0F4F5), fontSize: 14)),
                    subtitle: const Text('默认不勾选，只导入卡片内容',
                        style: TextStyle(
                            color: Color(0xFF54666C), fontSize: 11.5)),
                  )
                else
                  const Text('该文件不含背诵进度',
                      style:
                          TextStyle(color: Color(0xFF54666C), fontSize: 12)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消',
                    style: TextStyle(color: Color(0xFF8C9DA2))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定',
                    style: TextStyle(
                        color: Color(0xFF00C08B),
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
      if (ok != true) return;

      await TransferService.saveImportedBook(preview.book);
      if (withProgress && preview.progress != null) {
        widget.store.importProgress(preview.progress!);
      }
      await refresh();
      _toast('已导入《${preview.book.title}》');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  // ---------------------------------------------------------------
  // 长按 → 底部抽屉（导出）
  // ---------------------------------------------------------------
  Future<void> _showBookSheet(Book book) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B2629),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.menu_book,
                      color: Color(0xFF00C08B), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(book.title,
                        style: const TextStyle(
                            color: Color(0xFFF0F4F5),
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              leading:
                  const Icon(Icons.ios_share, color: Color(0xFF00C08B)),
              title: const Text('导出',
                  style: TextStyle(color: Color(0xFFF0F4F5))),
              subtitle: const Text('导出到 Documents/Flashcard/export',
                  style:
                      TextStyle(color: Color(0xFF54666C), fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _export(book);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _export(Book book) async {
    bool withProgress = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1B2629),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18)),
          title: const Text('导出卡片',
              style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('《${book.title}》',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: const Color(0xFF00C08B),
                checkColor: const Color(0xFF141D1F),
                value: withProgress,
                onChanged: (v) => setD(() => withProgress = v ?? true),
                title: const Text('包含背诵进度',
                    style:
                        TextStyle(color: Color(0xFFF0F4F5), fontSize: 14)),
                subtitle: const Text('默认导出进度数据，取消则只导卡片',
                    style: TextStyle(
                        color: Color(0xFF54666C), fontSize: 11.5)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(color: Color(0xFF8C9DA2))),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导出',
                  style: TextStyle(
                      color: Color(0xFF00C08B),
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final res = await TransferService.exportBook(book, widget.store,
        withProgress: withProgress);
    _toast(res.message);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF1B2629),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 打开搜索（跨所有单词书搜单词 / 释义）
  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          repo: widget.repo,
          templates: widget.templates,
          store: widget.store,
          settings: widget.settings,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        // 「单词」页左上角给一个搜索入口（Card 页不放）
        leading: widget.kind == LibraryKind.word
            ? IconButton(
                icon: const Icon(Icons.search, color: Color(0xFF8C9DA2)),
                tooltip: '搜索单词',
                onPressed: _openSearch,
              )
            : null,
        title: Text(_title,
            style: const TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined,
                color: Color(0xFF8C9DA2)),
            tooltip: '导入卡片',
            onPressed: _import,
          ),
        ],
      ),
      body: books == null
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00C08B)))
          : _list(books),
    );
  }

  Widget _list(List<Book> books) {
    final showNotebook = widget.kind == LibraryKind.word;
    if (books.isEmpty && !showNotebook) return _empty();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: books.length + (showNotebook ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, i) {
        if (showNotebook && i == 0) return _notebookTile();
        return _bookTile(books[i - (showNotebook ? 1 : 0)]);
      },
    );
  }

  /// 生词本入口（只挂在「单词」页，首页不再放）
  Widget _notebookTile() {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _toast('生词本还在建设中 ⭐'),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 62,
              decoration: BoxDecoration(
                color: const Color(0x1FFFCF5C),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.star_border,
                  color: Color(0xFFFFCF5C), size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('生词本',
                      style: TextStyle(
                          color: Color(0xFFF0F4F5),
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 3),
                  Text('收藏的单词 · 跨书汇总（开发中）',
                      style:
                          TextStyle(color: Color(0xFF54666C), fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF00C08B)),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    final hint = widget.kind == LibraryKind.word
        ? '还没有单词书\n点右上角导入'
        : '还没有 Card 卡组\n需要一个 engine: srs_basic 的模板';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, color: Color(0xFF54666C), size: 48),
          const SizedBox(height: 12),
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF54666C), fontSize: 13)),
          const SizedBox(height: 16),
          TextButton(
            onPressed: _import,
            child: const Text('导入卡片',
                style: TextStyle(
                    color: Color(0xFF00C08B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _bookTile(Book book) {
    final ids = book.allCardIds;
    final learned = widget.store.countLearned(ids);
    final total = ids.length;
    final progress = total == 0 ? 0.0 : learned / total;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookDetailScreen(
            book: book,
            template: widget.templates[book.templateId],
            store: widget.store,
            settings: widget.settings,
          ),
        ),
      ).then((_) => refresh()),
      onLongPress: () => _showBookSheet(book),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
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
              child: Icon(
                  widget.kind == LibraryKind.word
                      ? Icons.menu_book
                      : Icons.style,
                  color: const Color(0xFF141D1F),
                  size: 24),
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
