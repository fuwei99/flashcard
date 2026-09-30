/// 卡片内容源：给 WebView 双向 RPC 提供「按 id 找卡 / 列书」的能力。
/// ================================================================
/// 壳的 RPC 层（card.get / card.due / card.new）手里只有 [CardStore] 的
/// 「状态」（FSRS / KV），拿不到「内容」（字段、释义、例句）。
/// 卡内容散在 书 / 章分片 里，由 [DeckRepository] 管。这一层把两者缝起来，
/// 并尽量**不**把整本书读进内存：
///   - 判到期 / 新卡只用 Chapter.ids（来自 index.json），不读章节文件；
///   - 真要某张卡，才读它所在的那一章（Chapter 自身缓存，读一次）。
///
/// 书列表读一次后缓存；外部改了书（热重载 / 导入）调 [BookCardSource.invalidate]。
library;

import '../models/book.dart';
import '../models/deck.dart';
import 'deck_repository.dart';

/// RPC 层要的「卡片查询」接口。抽出来是为了能 mock、也能换实现
/// （比如以后接 SQLite，只换这个实现，桥一行不用动）。
abstract class CardSource {
  /// 全部书（内置 + 导入）
  Future<List<Book>> books();

  /// 按 id 找一张卡；找不到返回 null
  Future<FlashCard?> cardById(String id);

  /// 整本书的「干扰项池」：只要 id / word / senses。
  ///
  /// 出选项只需要这三样。以前模板拿 `fs.list` + `fs.read` 把整本书
  /// list + read + JSON.parse 一遍 —— 考研真题那本 4.1MB / 36 个分片，
  /// 那坨活全跑在 WebView 主线程上。现在壳读一次、缓存住，只回最小结构。
  Future<List<Map<String, dynamic>>> pool(String bookId);
}

/// 基于 [DeckRepository] 的实现：书读盘 + 章节懒加载。
class BookCardSource implements CardSource {
  final DeckRepository _repo;
  List<Book>? _books;
  final Map<String, FlashCard> _cache = {};

  BookCardSource([DeckRepository? repo]) : _repo = repo ?? DeckRepository();

  @override
  Future<List<Book>> books() async => _books ??= await _repo.loadAllBooks();

  /// 清缓存（外部改了书 / 导入新书后调）
  void invalidate() {
    _books = null;
    _cache.clear();
  }

  @override
  Future<FlashCard?> cardById(String id) async {
    if (id.isEmpty) return null;
    final hit = _cache[id];
    if (hit != null) return hit;

    for (final b in await books()) {
      final found = _findInBook(b, id);
      if (found != null) {
        _cache[id] = found;
        return found;
      }
    }
    return null;
  }

  /// 精简池：{id, word, senses:[{pos, cn:[...]}]}。
  /// 章节读盘交给 Chapter 自己的缓存，同一本书整个会话只读一次。
  @override
  Future<List<Map<String, dynamic>>> pool(String bookId) async {
    final out = <Map<String, dynamic>>[];
    for (final b in await books()) {
      if (b.bookId != bookId) continue;
      final seen = <String>{};
      void add(FlashCard c) {
        if (!seen.add(c.id)) return;
        final senses = <Map<String, dynamic>>[];
        for (final s in c.senses) {
          if (s.isEmpty) continue;
          senses.add({'pos': s.pos, 'cn': <String>[s.cn]});
        }
        // 没有中文释义的卡放进去也出不了选项，只会渲染成空行 —— 直接不进池。
        if (senses.isEmpty) return;
        out.add({'id': c.id, 'word': c.word, 'senses': senses});
      }

      if (b.hasChapters) {
        for (final ch in b.chapters) {
          for (final c in ch.cards) {
            add(c);
          }
        }
      } else {
        for (final c in b.looseCards) {
          add(c);
        }
      }
      break;
    }
    return out;
  }

  /// 在书里找一张卡。分片章先看 ids（**不触发读盘**），命中才 cards（只读这一章）。
  static FlashCard? _findInBook(Book b, String id) {
    if (b.hasChapters) {
      for (final ch in b.chapters) {
        if (!ch.ids.contains(id)) continue;
        for (final c in ch.cards) {
          if (c.id == id) return c;
        }
      }
      return null;
    }
    for (final c in b.looseCards) {
      if (c.id == id) return c;
    }
    return null;
  }
}
