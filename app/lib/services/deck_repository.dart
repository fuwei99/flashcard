/// 书本 / 模板 仓库层
/// ================================================================
/// **模板**（HTML/CSS/JS/manifest）优先从公共目录读：
///   <Documents>/Flashcard/templates/<template_id>/
/// 内置只带一个旗舰模板（`bubei_react_v1`），启动时按文件同步过去：
/// 缺的补、壳铺的旧版升、用户改过的留着（详见 [seedPublicTemplates]）。
/// 之后想怎么美化 CSS / 改 HTML / 改 JS，直接改文件 → 「我的」页点
/// 「重载模板」即可生效，不用重新编译 APK。
///
/// **书本**有两种落盘格式：
///   1. 分片（新，v0.7.0）：
///        books/<book_id>/index.json     书元信息 + 章节目录（标题/卡片数/卡片 id/语篇）
///        books/<book_id>/ch_0001.json   第 1 章，只有卡片
///      —— 启动只读 index.json，首页算「今天到期/新词」一张卡都不用载入；
///         真开背才按章读盘；Agent 改第 3 章就只动 ch_0003.json。
///   2. 单文件（旧）：books/<book_id>.json
///      —— 读到之后自动拆成分片目录，原文件改名 .json.bak 留底。
///
/// 来源目录：
///   1. <Documents>/Flashcard/books/   （公共目录，Agent 可直接丢书）
///   2. <appdoc>/books/                （老数据，兼容读）
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/deck.dart';
import 'data_dir.dart';

class DeckRepository {
  static const _assetBooks = <String>[
    'assets/decks/kaoyan_core.json',
  ];

  /// 内置模板：**只有旗舰模板一个**。
  ///
  /// 播种（[seedPublicTemplates]）和兜底（[loadAllTemplates]）都只认这份清单。
  /// 以前这里挂的是 bubei_dark —— 那是早期骨架模板，自己不会算干扰项、
  /// 数据契约也停在 v3，铺出去等于给用户塞个残废壳。换成 react_v1。
  static const _templateDirs = <String>[
    'assets/templates/bubei_react_v1',
  ];

  /// 一个模板包固定这几个文件
  static const _templateFiles = <String>[
    'manifest.json',
    'template.html',
    'style.css',
    'script.js',
    'workflow.js',
  ];

  /// 播种标记：铺内置模板时写在目录里的 `.builtin`。
  ///
  /// 内容是一份 JSON：`{"id": 模板 id, "sha": {文件名: 铺下去时的 sha256}}`。
  /// 靠它区分两件事 ——
  ///   * 目录里没有这个文件   → 用户自己建的模板，整个跳过，一根手指都不碰
  ///   * 有标记               → 壳铺的。拿记录里的 sha 跟当前文件比：
  ///                            对得上 = 用户没动过，可以安全覆盖成新版；
  ///                            对不上 = 用户改过，保留用户的。
  ///
  /// 没有它，`目录非空就跳过` 那条规则会让模板改动**永远推不到已安装的用户**，
  /// 只能靠卸载重装 —— 对一个「壳只发牌、模板随便热更」的项目来说等于自废武功。
  static const _seedMark = '.builtin';

  /// 公共目录里的模板根目录
  static String get templatesPath => '${DataDir.publicPath}/templates';

  /// 公共目录里的书本根目录
  static String get booksPath => '${DataDir.publicPath}/books';

  // ===============================================================
  // 模板
  // ===============================================================

  static String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

  /// 首次运行 / 每次启动：把内置模板同步到公共目录。
  ///
  /// 逐文件同步，而不是「目录存在就整个跳过」：
  ///   * 缺的          → 补
  ///   * 和 asset 一样 → 不写（省 IO）
  ///   * 用户改过      → 留着（sha 对不上标记里记录的）
  ///   * 壳铺的旧版    → 覆盖成新版（sha 对得上，说明用户没动过）
  ///
  /// 返回写入/更新的文件数；公共目录不可用返回 -1
  Future<int> seedPublicTemplates() async {
    final root = await DataDir.sub('templates');
    if (root == null) return -1;
    var copied = 0;
    for (final assetDir in _templateDirs) {
      final id = assetDir.split('/').last;
      final target = Directory('${root.path}/$id');
      final mark = File('${target.path}/$_seedMark');

      // 目录已存在但没有播种标记 → 用户自己的模板，整个跳过。
      // 空目录例外：那多半是上次铺到一半留下的，直接接手。
      if (await target.exists() && !await mark.exists()) {
        if (!await target.list().isEmpty) continue;
      }

      // 上一次铺下去时的 sha 表（没有就是首次）
      var seeded = <String, String>{};
      try {
        if (await mark.exists()) {
          final j = json.decode(await mark.readAsString());
          if (j is Map && j['sha'] is Map) {
            (j['sha'] as Map).forEach((k, v) {
              seeded[k.toString()] = v.toString();
            });
          }
        }
      } catch (_) {}

      final fresh = <String, String>{};
      for (final name in _templateFiles) {
        try {
          final content = await rootBundle.loadString('$assetDir/$name');
          final hash = _sha(content);
          fresh[name] = hash;

          final f = File('${target.path}/$name');
          if (await f.exists()) {
            final local = await f.readAsString();
            if (local == content) continue;              // 已经是这版，不写
            // 有差异：只有「上次铺的 + 之后没人动过」才敢覆盖
            final recorded = seeded[name];
            if (recorded == null || _sha(local) != recorded) continue;
          }

          if (!await target.exists()) await target.create(recursive: true);
          await f.writeAsString(content);
          copied++;
        } catch (_) {}
      }

      try {
        if (!await target.exists()) await target.create(recursive: true);
        await mark.writeAsString(json.encode({'id': id, 'sha': fresh}));
      } catch (_) {}
    }
    return copied;
  }

  /// 壳铺过、但已经不在内置清单里的模板目录（旧版本残留，比如 bubei_dark）。
  ///
  /// **只报告，不删** —— 删用户 Documents 下的东西得用户点头。
  /// 结果进 status.json 的 diagnostics.stale_templates，想清就自己用
  /// 文件管理器删掉那个目录（App 里没有模板删除入口）。
  Future<List<String>> staleBuiltinTemplates() async {
    final out = <String>[];
    final root = await DataDir.sub('templates', create: false);
    if (root == null) return out;
    final builtin = _templateDirs.map((d) => d.split('/').last).toSet();
    try {
      if (!await root.exists()) return out;
      for (final e in await root.list().toList()) {
        if (e is! Directory) continue;
        final segs = e.uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (segs.isEmpty) continue;
        final id = segs.last;
        if (builtin.contains(id)) continue;
        if (await File('${e.path}/$_seedMark').exists()) out.add(id);
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  // ===============================================================
  // 说明文档（给 Agent / 用户看）
  // ===============================================================

  /// 内置说明文档在 assets 里的目录（真源在仓库 text/readme/，CI 同步过来）
  static const _readmeAssetDir = 'assets/readme';

  /// 文档自带的版本号：头部 front-matter 里的 `doc_version: N`
  static int _docVersionOf(String text) {
    final m = RegExp(r'^doc_version:\s*(\d+)', multiLine: true).firstMatch(text);
    if (m == null) return 0;
    return int.tryParse(m.group(1)!) ?? 0;
  }

  /// 列出 assets/readme/ 下所有 .md。
  /// 走 AssetManifest 动态枚举 —— **新增文档不用改任何代码**。
  Future<List<String>> _readmeAssets() async {
    try {
      final m = await AssetManifest.loadFromAssetBundle(rootBundle);
      final keys = m
          .listAssets()
          .where((k) => k.startsWith('$_readmeAssetDir/') && k.endsWith('.md'))
          .toList()
        ..sort();
      if (keys.isNotEmpty) return keys;
    } catch (_) {}
    return const ['$_readmeAssetDir/如何管理单词.md'];
  }

  /// 把内置说明文档铺到公共目录（直接铺在 Flashcard/ 下），让 Agent 能直接读。
  ///
  /// **版本感知**：文档头部有 `doc_version: N`
  ///   - 公共目录没有            → 写入
  ///   - 公共目录版本更旧        → 覆盖（schema 更新能推下去）
  ///   - 公共目录版本相同或更新  → 不动（用户自己改过、批注过的保留）
  ///
  /// 返回写入的文件数；公共目录不可用返回 -1。
  Future<int> seedReadme() async {
    final root = await DataDir.root();
    if (root == null) return -1;
    var written = 0;
    for (final asset in await _readmeAssets()) {
      final name = asset.split('/').last;
      if (name.isEmpty) continue;
      try {
        final bundled = await rootBundle.loadString(asset);
        final f = File('${root.path}/$name');
        if (await f.exists()) {
          final local = await f.readAsString();
          if (_docVersionOf(local) >= _docVersionOf(bundled)) continue;
        }
        await f.writeAsString(bundled);
        written++;
      } catch (_) {}
    }
    return written;
  }

  /// 从一个目录读模板包（文件名以 manifest 里的 files 为准）
  Future<CardTemplate?> _loadTemplateFromDir(Directory dir) async {
    try {
      final mf = File('${dir.path}/manifest.json');
      if (!await mf.exists()) return null;
      final manifest =
          json.decode(await mf.readAsString()) as Map<String, dynamic>;
      final files = manifest['files'] is Map
          ? Map<String, dynamic>.from(manifest['files'] as Map)
          : const <String, dynamic>{};

      Future<String> read(String key, String fallback) async {
        final name = (files[key] ?? fallback).toString();
        final f = File('${dir.path}/$name');
        if (!await f.exists()) return '';
        return await f.readAsString();
      }

      return CardTemplate(
        manifest: manifest,
        html: await read('template', 'template.html'),
        css: await read('style', 'style.css'),
        js: await read('script', 'script.js'),
        workflow: await read('workflow', 'workflow.js'),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读一个内置模板包（asset）
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
      workflow: await maybe('workflow.js'),
    );
  }

  /// 所有可用模板：公共目录优先，内置补缺
  Future<Map<String, CardTemplate>> loadAllTemplates() async {
    final out = <String, CardTemplate>{};

    // 1) 公共目录（可随时改，改了重载即可）
    final pub = await DataDir.sub('templates', create: false);
    if (pub != null) {
      try {
        if (await pub.exists()) {
          final ents = await pub.list().toList()
            ..sort((a, b) => a.path.compareTo(b.path));
          for (final e in ents) {
            if (e is! Directory) continue;
            final t = await _loadTemplateFromDir(e);
            if (t != null) out[t.id] = t;
          }
        }
      } catch (_) {}
    }

    // 2) 内置模板补缺（公共目录里删掉了某个模板还能兜住）
    for (final d in _templateDirs) {
      try {
        final t = await loadTemplateAsset(d);
        out.putIfAbsent(t.id, () => t);
      } catch (_) {}
    }

    return out;
  }

  // ===============================================================
  // 书本
  // ===============================================================

  /// 读一本书（内置 asset，老格式）
  Future<Book> loadBookAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return Book.fromJson(json.decode(raw) as Map<String, dynamic>);
  }

  /// 用户书的来源目录（公共目录优先）
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

  /// 公共/私有 books 目录（写入用；优先公共）
  Future<Directory> writableBooksDir() async {
    final pub = await DataDir.sub('books');
    if (pub != null) return pub;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/books');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 用户导入 / 手动放入的书
  Future<List<Book>> loadImportedBooks() async {
    final out = <Book>[];
    final seen = <String>{};
    for (final dir in await _booksDirs()) {
      try {
        if (!await dir.exists()) continue;
        // 先把目录项收完再处理：_shardLegacy 会在遍历中建目录 / 改名，
        // 边遍历边改目录会让 stream 漏项。
        final entries = await dir.list().toList();
        for (final e in entries) {
          try {
            if (e is Directory) {
              // 分片格式
              final idx = File('${e.path}/index.json');
              if (!await idx.exists()) continue;
              final raw = await idx.readAsString();
              final b = Book.fromIndex(
                  json.decode(raw) as Map<String, dynamic>, e.path);
              if (seen.add(b.bookId)) out.add(b);
            } else if (e is File && e.path.endsWith('.json')) {
              // 老的单文件格式 → 读 + 自动拆片
              final raw = await e.readAsString();
              final b = Book.fromJson(json.decode(raw) as Map<String, dynamic>);
              if (!seen.add(b.bookId)) continue;
              out.add(b);
              await _shardLegacy(b, dir.path, e);
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return out;
  }

  /// 把老的「单文件带章节」书拆成分片目录，原文件改名 .json.bak 留底。
  /// 没有章节的书保持单文件（通常很小，不值得拆）。
  Future<bool> _shardLegacy(Book b, String parent, File from) async {
    if (!b.hasChapters) return false;
    final dir = Directory('$parent/${b.bookId}');
    try {
      if (await dir.exists()) return false;
      await dir.create(recursive: true);

      var i = 0;
      for (final c in b.chapters) {
        i++;
        final name = 'ch_${i.toString().padLeft(4, '0')}.json';
        await File('${dir.path}/$name').writeAsString(
          const JsonEncoder.withIndent('  ').convert(c.toJson()),
        );
      }

      await File('${dir.path}/index.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(b.toIndexJson()),
      );

      try {
        await from.rename('${from.path}.bak');
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把一本书写成分片目录（有章节）/ 单文件（无章节）
  Future<void> saveImportedBook(Book book) async {
    final booksDir = await writableBooksDir();

    if (!book.hasChapters) {
      final file = File('${booksDir.path}/${book.bookId}.json');
      await file.writeAsString(json.encode(book.toJson()));
      // 这本书之前可能是分片目录 / .bak 备份，单文件写完后要清干净，
      // 否则下次读盘先撞上旧目录里的 index.json，读到过期内容。
      final oldDir = Directory('${booksDir.path}/${book.bookId}');
      if (await oldDir.exists()) await oldDir.delete(recursive: true);
      final oldBak = File('${booksDir.path}/${book.bookId}.json.bak');
      if (await oldBak.exists()) await oldBak.delete();
      return;
    }

    final dir = Directory('${booksDir.path}/${book.bookId}');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    var i = 0;
    for (final c in book.chapters) {
      i++;
      final name = 'ch_${i.toString().padLeft(4, '0')}.json';
      await File('${dir.path}/$name').writeAsString(
        const JsonEncoder.withIndent('  ').convert(c.toJson()),
      );
    }

    await File('${dir.path}/index.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(book.toIndexJson()),
    );

    // 顺手清掉可能存在的同名单文件
    final old = File('${booksDir.path}/${book.bookId}.json');
    if (await old.exists()) await old.delete();
  }

  /// 删除一本导入的书（分片目录 / 单文件都删）
  Future<void> deleteImportedBook(String bookId) async {
    final booksDir = await writableBooksDir();
    final dir = Directory('${booksDir.path}/$bookId');
    if (await dir.exists()) await dir.delete(recursive: true);
    for (final suffix in ['', '.bak']) {
      final f = File('${booksDir.path}/$bookId.json$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  /// 公共 books 目录里是否已有内容
  Future<bool> _hasPublicBooks() async {
    final pub = await DataDir.sub('books', create: false);
    if (pub == null) return false;
    try {
      if (!await pub.exists()) return false;
      return !(await pub.list().isEmpty);
    } catch (_) {
      return false;
    }
  }

  /// 书架上的所有书 = 内置 + 导入。
  /// 公共 books 目录里只要已经有内容，就认为书是用户自己在管，不再导入内置词书。
  /// 同一次加载的在途 Future。
  ///
  /// 回前台 / 切 Tab / 热重载会在很短时间内触发好几次 loadAllBooks，
  /// 每次都是「扫一遍 books/ 目录 + 读所有 index.json」。
  /// 这里把并发的调用合并成一次：大家共享同一个 Future（也共享同一批
  /// Book 实例 —— 顺带保证各处拿到的是同一批 FlashCard 对象）。
  /// **只合并在途的，不缓存结果**：热重载靠重读文件发现改动，缓存会骗人。
  Future<List<Book>>? _loadingBooks;

  Future<List<Book>> loadAllBooks() async {
    final inflight = _loadingBooks;
    if (inflight != null) return inflight;
    final f = _loadAllBooksOnce();
    _loadingBooks = f;
    try {
      return await f;
    } finally {
      _loadingBooks = null;
    }
  }

  Future<List<Book>> _loadAllBooksOnce() async {
    final out = <Book>[];
    if (!await _hasPublicBooks()) {
      for (final p in _assetBooks) {
        try {
          out.add(await loadBookAsset(p));
        } catch (_) {}
      }
    }
    out.addAll(await loadImportedBooks());
    return out;
  }
}
