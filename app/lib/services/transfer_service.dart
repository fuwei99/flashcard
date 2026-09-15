/// 导入 / 导出
/// ================================================================
/// 导出：书 + 可选进度 → Documents/Flashcard/export/<book_id>.json
/// 导入：选文件 → 解析 → 交给 UI 弹窗确认（是否带进度）→ 落盘
///
/// 打包格式（.json）：
/// {
///   "format": "flashcard.v1",
///   "exported_at": "...",
///   "book": { ...书本 json... },
///   "progress": { "card_states": {...}, "card_kv": {...} }   // 可选
/// }
///
/// 公共目录不可写时，全部退回 app 私有目录，功能不受影响。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import 'card_store.dart';
import 'data_dir.dart';

class ExportResult {
  final bool ok;
  final String path;
  final String message;
  ExportResult(this.ok, this.path, this.message);
}

/// 导入前的预览：解析出来但还没落盘
class ImportPreview {
  final Book book;
  final Map<String, dynamic>? progress;
  final String sourcePath;

  ImportPreview({
    required this.book,
    this.progress,
    required this.sourcePath,
  });

  bool get hasProgress =>
      progress != null && (progress!['card_states'] is Map) &&
      (progress!['card_states'] as Map).isNotEmpty;
}

class TransferService {
  static const _fmt = 'flashcard.v1';

  // ---------------------------------------------------------------
  // 目录：优先公共目录，不可用则退回 app 私有目录
  // ---------------------------------------------------------------
  static Future<Directory> _publicOrPrivate(String name) async {
    final pub = await DataDir.sub(name);
    if (pub != null) return pub;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 导出目录
  static Future<Directory> exportDir() => _publicOrPrivate('export');

  /// 导入的书存放目录
  static Future<Directory> booksDir() => _publicOrPrivate('books');

  // ---------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------
  static Future<ExportResult> exportBook(
    Book book,
    CardStore store, {
    bool withProgress = true,
  }) async {
    try {
      final dir = await exportDir();

      final payload = <String, dynamic>{
        'format': _fmt,
        'exported_at': DateTime.now().toIso8601String(),
        'book': book.toJson(),
      };
      if (withProgress) {
        final ids = book.allCards.map((c) => c.id).toList();
        payload['progress'] = store.exportProgress(ids);
      }

      final file = File('${dir.path}/${book.bookId}.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      return ExportResult(true, file.path, '已导出到 ${file.path}');
    } catch (e) {
      return ExportResult(false, '', '导出失败：$e');
    }
  }

  // ---------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------
  /// 选文件并解析（不落盘，先给用户确认）
  static Future<ImportPreview?> pickAndParse() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return null;

    final f = res.files.first;
    final raw = f.bytes != null
        ? utf8.decode(f.bytes!)
        : await File(f.path!).readAsString();
    final map = json.decode(raw) as Map<String, dynamic>;

    // 兼容两种：带 wrapper 的 {format, book, progress} 或纯 book json
    Map<String, dynamic> bookJson;
    Map<String, dynamic>? progress;
    if (map['format'] == _fmt && map['book'] is Map) {
      bookJson = Map<String, dynamic>.from(map['book'] as Map);
      progress = map['progress'] is Map
          ? Map<String, dynamic>.from(map['progress'] as Map)
          : null;
    } else if (map['book'] is Map && map['format'] == null) {
      bookJson = Map<String, dynamic>.from(map['book'] as Map);
      progress = map['progress'] is Map
          ? Map<String, dynamic>.from(map['progress'] as Map)
          : null;
    } else {
      bookJson = map; // 纯书本
    }

    final book = Book.fromJson(bookJson);
    return ImportPreview(
      book: book,
      progress: progress,
      sourcePath: f.path ?? f.name,
    );
  }

  /// 把导入的书落盘到 <公共目录>/Flashcard/books/<book_id>.json
  /// —— Agent 可以直接在这里塞一本书进去
  static Future<void> saveImportedBook(Book book) async {
    final booksDir = await _publicOrPrivate('books');
    final file = File('${booksDir.path}/${book.bookId}.json');
    await file.writeAsString(json.encode(book.toJson()));
  }

  /// 删除一本导入的书
  static Future<void> deleteImportedBook(String bookId) async {
    final booksDir = await _publicOrPrivate('books');
    final file = File('${booksDir.path}/$bookId.json');
    if (await file.exists()) await file.delete();
  }
}
