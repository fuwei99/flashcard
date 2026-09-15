/// 书本 / 模板 仓库层
/// ================================================================
/// 书本来源有三处：
///   1. 内置 asset（assets/decks/*.json，只读）
///   2. 公共目录 <Documents>/Flashcard/books/*.json（Agent 可直接放书）
///   3. app 私有目录 <appdoc>/books/*.json（老数据，兼容读）
/// 按 bookId 去重。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'data_dir.dart';

class DeckRepository {
  static const _assetBooks = <String>[
    'assets/decks/kaoyan_core.json',
  ];

  static const _templateDirs = <String>[
    'assets/templates/bubei_dark',
    'assets/templates/mixup_dark',
  ];

  /// 读一本书（asset）
  Future<Book> loadBookAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return Book.fromJson(json.decode(raw) as Map<String, dynamic>);
  }

  /// 读一个模板包（asset）
  Future<CardTemplate> loadTemplateAsset(String dir) async {
    final manifest = json.decode(
      await rootBundle.loadString('$dir/manifest.json'),
    ) as Map<String, dynamic>;

    Future<String> maybe(String name) async {
      try {
        return await rootBundle.loadString('$dir/$name');
      } catch (_) {
        return '';
      }
    }

    return CardTemplate(
      manifest: manifest,
      html: await maybe('template.html'),
      css: await maybe('style.css'),
      js: await maybe('script.js'),
    );
  }

  /// 用户导入 / 手动放入的书所在目录（公共目录优先）
  Future<List<Directory>> _booksDirs() async {
    final dirs = <Directory>[];
    final pub = await DataDir.sub('books', create: false);
    if (pub != null) dirs.add(pub);
    try {
      final base = await getApplicationDocumentsDirectory();
      dirs.add(Directory('${base.path}/books'));
    } catch (_) {}
    return dirs;
  }

  /// 用户导入的书
  Future<List<Book>> loadImportedBooks() async {
    final out = <Book>[];
    final seen = <String>{};
    for (final dir in await _booksDirs()) {
      try {
        if (!await dir.exists()) continue;
        await for (final e in dir.list()) {
          if (e is! File || !e.path.endsWith('.json')) continue;
          try {
            final raw = await e.readAsString();
            final b = Book.fromJson(json.decode(raw) as Map<String, dynamic>);
            if (seen.add(b.bookId)) out.add(b);
          } catch (_) {}
        }
      } catch (_) {}
    }
    return out;
  }

  /// 书架上的所有书 = 内置 + 导入
  Future<List<Book>> loadAllBooks() async {
    final out = <Book>[];
    for (final p in _assetBooks) {
      try {
        out.add(await loadBookAsset(p));
      } catch (_) {}
    }
    out.addAll(await loadImportedBooks());
    return out;
  }

  /// 所有可用模板
  Future<Map<String, CardTemplate>> loadAllTemplates() async {
    final out = <String, CardTemplate>{};
    for (final d in _templateDirs) {
      try {
        final t = await loadTemplateAsset(d);
        out[t.id] = t;
      } catch (_) {}
    }
    return out;
  }
}
