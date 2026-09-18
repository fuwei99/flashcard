/// status.json —— 给外部监工（AI）读的只读状态快照
/// ================================================================
/// 每次「启动 / 背完一张 / 进后台」写一份
///   <公共目录>/Flashcard/status.json
/// 让 Agent 不用连数据库、不用数日志，一眼就知道：
///   · 今天背了多少、达标没、欠多少
///   · 连续打卡 / 累计
///   · 每本书的进度（总数 / 已学 / 待学 / 今日到期 / 标熟）
///
/// 这是**只写不读**的文件：App 从不读它，纯粹是给外部看的输出。
/// 写失败静默 —— 少一份快照不影响学习。
library;

import '../models/book.dart';
import 'card_store.dart';
import 'data_dir.dart';
import 'study_settings.dart';

class StatusWriter {
  StatusWriter._();
  static final StatusWriter I = StatusWriter._();

  static const fileName = 'status.json';

  StudySettings? _settings;
  CardStore? _store;
  Future<List<Book>> Function()? _loadBooks;

  DateTime? _lastWrite;

  /// 诊断段：崩溃记录 + 旧模板残留。由 main 在启动时填一次。
  ///
  /// 放在 status.json 里而不是只写日志文件 —— 这个文件的定位就是
  /// 「给外部监工（AI）读」，崩过没崩过、有没有该清的残留，
  /// 监工一眼就该看到，不用去翻 logs/ 目录。
  Map<String, dynamic>? crashLast;
  int crashCount = 0;
  List<String> staleTemplates = const <String>[];

  void init({
    required StudySettings settings,
    required CardStore store,
    required Future<List<Book>> Function() loadBooks,
  }) {
    _settings = settings;
    _store = store;
    _loadBooks = loadBooks;
  }

  /// 写一份完整快照。返回是否写成功。
  Future<bool> write() async {
    final s = _settings;
    final store = _store;
    if (s == null || store == null) return false;

    List<Book> books = const <Book>[];
    try {
      books = await _loadBooks?.call() ?? const <Book>[];
    } catch (_) {}

    final doc = _compose(s, store, books);
    _lastWrite = DateTime.now();
    if (!DataDir.available) return false;
    return DataDir.writeJsonSync(fileName, doc);
  }

  /// 限流写：每 [min] 最多写一次（背卡过程中频繁调用它）。
  Future<void> writeThrottled(
      {Duration min = const Duration(seconds: 15)}) async {
    final now = DateTime.now();
    final last = _lastWrite;
    if (last != null && now.difference(last) < min) return;
    await write();
  }

  Map<String, dynamic> _compose(
      StudySettings s, CardStore store, List<Book> books) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final today = DateTime(now.year, now.month, now.day);

    final bookDocs = <Map<String, dynamic>>[];
    var tTotal = 0, tLearned = 0, tFresh = 0, tDue = 0, tMastered = 0;

    for (final b in books) {
      // allCardIds 走 index.json 的种子 id，不触发章节读盘（和首页同口径）
      final ids = b.allCardIds;
      var learned = 0, due = 0, known = 0, fresh = 0;
      for (final id in ids) {
        if (store.isKnown(id)) {
          known++;
          continue;
        }
        if (store.isLearned(id)) {
          learned++;
          final st = store.stateOf(id);
          final d = st.due;
          if (!st.isNew && d != null && !d.isAfter(today)) due++;
        } else {
          fresh++;
        }
      }
      tTotal += ids.length;
      tLearned += learned;
      tFresh += fresh;
      tDue += due;
      tMastered += known;

      bookDocs.add({
        'book_id': b.bookId,
        'title': b.title,
        'template': b.templateId,
        'total': ids.length,
        'learned': learned,
        'fresh': fresh,
        'due': due,
        'mastered': known,
      });
    }

    return {
      'format': 'flashcard.status.v1',
      'updated_at': stamp,
      'today': {
        'date': s.todayDate,
        'word_done': s.todayWordDone,
        'card_done': s.todayCardDone,
        'word_limit': s.wordDailyLimit,
        'card_limit': s.cardDailyLimit,
        'review_limit': s.reviewDailyLimit,
        'total_done': s.todayTotal,
      },
      'streak_days': s.currentStreak,
      'best_streak': s.bestStreak,
      'total_study_days': s.totalStudyDays,
      'total_word_done': s.totalWordDone,
      'total_card_done': s.totalCardDone,
      'checked_in_today': s.checkedInToday,
      'word_passed': s.wordPassed,
      'card_passed': s.cardPassed,
      'totals': {
        'books': bookDocs.length,
        'cards': tTotal,
        'learned': tLearned,
        'fresh': tFresh,
        'due': tDue,
        'mastered': tMastered,
      },
      'books': bookDocs,
      if (crashLast != null || crashCount > 0 || staleTemplates.isNotEmpty)
        'diagnostics': {
          'crash_count': crashCount,
          // 上一次运行的崩溃（本次启动时读的 logs/crash/last_crash.json）
          if (crashLast != null) 'last_crash': crashLast,
          // 壳铺过、但已不在内置清单里的模板目录。只报告不删，
          // 留着用户会在「模板」列表里看到一个残废模板。
          if (staleTemplates.isNotEmpty) 'stale_templates': staleTemplates,
        },
    };
  }
}
