/// 书本 / 模板 仓库层
/// ================================================================
/// 书本来源有两处：
///   1. 内置 asset（assets/decks/*.json，只读）
///   2. 用户导入（<appdoc>/books/*.json，可增删）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/deck.dart';

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

  /// 用户导入的书
  Future<List<Book>> loadImportedBooks() async {
    final out = <Book>[];
    try {
      final dir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${dir.path}/books');
      if (!await booksDir.exists()) return out;
      await for (final e in booksDir.list()) {
        if (e is File && e.path.endsWith('.json')) {
          try {
            final raw = await e.readAsString();
            out.add(Book.fromJson(json.decode(raw) as Map<String, dynamic>));
          } catch (_) {}
        }
      }
    } catch (_) {}
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
