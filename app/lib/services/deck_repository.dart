/// 书本 / 模板 仓库层：从 assets 读取
library;

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

import '../models/book.dart';
import '../models/deck.dart';

class DeckRepository {
  /// 读一本书（卡组文件就是一本书）
  Future<Book> loadBookAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return Book.fromJson(json.decode(raw) as Map<String, dynamic>);
  }

  /// 读一个模板包
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

  /// 书架上的所有书
  Future<List<Book>> loadAllBooks() async {
    const paths = [
      'assets/decks/kaoyan_core.json',
    ];
    final out = <Book>[];
    for (final p in paths) {
      try {
        out.add(await loadBookAsset(p));
      } catch (_) {}
    }
    return out;
  }

  /// 所有可用模板
  Future<Map<String, CardTemplate>> loadAllTemplates() async {
    const dirs = [
      'assets/templates/bubei_dark',
    ];
    final out = <String, CardTemplate>{};
    for (final d in dirs) {
      try {
        final t = await loadTemplateAsset(d);
        out[t.id] = t;
      } catch (_) {}
    }
    return out;
  }
}
