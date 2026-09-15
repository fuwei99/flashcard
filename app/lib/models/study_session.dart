/// 会话状态机（轮内状态）
/// ================================================================
/// 只管「这一轮」的事：队列、阶段、轮次、通过与否。
/// 绝不碰持久层 —— 卡片的长期调度（FSRS）由屏幕在「毕业」时写。
///
/// 2026-09 起支持「多单元」：一次会话 = 若干 StudyUnit 顺序走完。
/// 单元 = 可选语篇 + 一批卡片，单元内流程：
///   passage（通读，仅 readFirst）-> passageCloze（挖空）-> learn -> 重测轮
///   本单元重测轮走完 -> 下一个单元；全部单元走完 -> done
///
/// 单词复习「跨牌组 + 语篇只挖今天要复习的词」的编排由 StudyPlanner 负责，
/// 这里只负责把编排好的单元依次执行。
library;

import 'book.dart';
import 'deck.dart';
import '../services/scheduler.dart';

enum SessionPhase { passage, passageCloze, learn, choice, cloze, done }

enum StudyMode {
  read('read'),
  passage('passage'),
  passageCloze('passage_cloze'),
  choice('choice'),
  cloze('cloze'),
  spell('spell');

  const StudyMode(this.key);
  final String key;

  static StudyMode fromKey(String k) => StudyMode.values
      .firstWhere((m) => m.key == k, orElse: () => StudyMode.read);
}

/// 队列里的一个步骤：某张卡 + 某个考法 + 第几轮。
/// 语篇两阶段没有具体卡片，card 为 null。
class StudyStep {
  final FlashCard? card;
  final StudyMode mode;
  final int round;
  const StudyStep(this.card, this.mode, this.round);
}

/// 一个学习单元 = 可选语篇 + 一批卡片。
///
/// 新学单元：readFirst = true（先通读），blankLemmas = null（挖全部标记词）
/// 复习单元：readFirst = false（直接填词），blankLemmas = 这批要复习的词，
///           语篇里其余目标词只作普通文本展示，不挖空。
class StudyUnit {
  /// 本单元前面的语篇（可空）
  final Passage? passage;

  /// 本单元的卡片（复习 = 一批到期词；新学 = 本章未学词）
  final List<FlashCard> cards;

  /// 语篇里只挖这些 lemma（小写）。null = 挖全部标记词
  final Set<String>? blankLemmas;

  /// 是否先通读语篇
  final bool readFirst;

  /// 是否复习单元（影响进度/文案）
  final bool isReview;

  /// 语篇释义查表用的卡片（该章全部卡片，通常比 cards 多）；为空时用 cards
  final List<FlashCard>? passageCards;

  /// 单元标题（章名 / 分组名），仅用于展示
  final String title;

  const StudyUnit({
    this.passage,
    required this.cards,
    this.blankLemmas,
    this.readFirst = false,
    this.isReview = false,
    this.passageCards,
    this.title = '',
  });

  /// 语篇释义查表用（未指定就用本单元卡片）
  List<FlashCard> get passageLookup => passageCards ?? cards;

  bool get hasPassage => passage != null && passage!.hasContent;
}

class StudySession {
  /// 编排好的单元列表（顺序执行）
  final List<StudyUnit> units;

  /// 语篇选词是否开启（设置项）
  final bool passageClozeEnabled;

  /// 启用的重测考法，按顺序（语义选项在前、短句选词在后）
  final List<StudyMode> retestModes;

  final List<StudyStep> _queue = [];
  final List<FlashCard> _retestPool = [];

  /// 已毕业的卡 id（整场会话内）
  final Set<String> graduated = {};

  /// 重测阶段里每张卡的考法通过记录：cardId -> {mode keys}
  final Map<String, Set<String>> _passedModes = {};

  /// 本轮「挣扎程度」：0 = 一次过，1 = 费了点劲，2 = 硬骨头。
  final Map<String, int> _effort = {};

  /// 这张卡答错的次数
  final Map<String, int> _wrongCount = {};

  int _unitIdx = 0;
  SessionPhase phase = SessionPhase.done;
  int round = 1;
  int _roundTotal = 0;
  int _modeIdx = 0;

  StudySession(
    List<StudyUnit> units, {
    this.passageClozeEnabled = true,
    this.retestModes = const [StudyMode.choice, StudyMode.cloze],
  }) : units = units {
    if (units.isEmpty) {
      phase = SessionPhase.done;
    } else {
      _startUnit();
    }
  }

  StudyUnit? get currentUnit =>
      (_unitIdx >= 0 && _unitIdx < units.length) ? units[_unitIdx] : null;

  /// 当前单元的语篇（语篇两阶段挂它）
  Passage? get passage => currentUnit?.passage;

  bool get hasPassage => currentUnit?.hasPassage ?? false;

  /// 当前单元序号（0 基）/ 总单元数
  int get unitIndex => _unitIdx;
  int get unitCount => units.length;

  StudyStep? get current {
    switch (phase) {
      case SessionPhase.passage:
        return const StudyStep(null, StudyMode.passage, 0);
      case SessionPhase.passageCloze:
        return const StudyStep(null, StudyMode.passageCloze, 0);
      default:
        return _queue.isEmpty ? null : _queue.first;
    }
  }

  bool get finished => phase == SessionPhase.done;
  int get left => _queue.length;
  int get retestPoolSize => _retestPool.length;

  int get roundTotal {
    switch (phase) {
      case SessionPhase.passage:
      case SessionPhase.passageCloze:
        return 1;
      default:
        return _roundTotal;
    }
  }

  int get doneInRound {
    switch (phase) {
      case SessionPhase.passage:
      case SessionPhase.passageCloze:
        return 0;
      default:
        return (_roundTotal - _queue.length).clamp(0, _roundTotal);
    }
  }

  // ---------- 单元切换 ----------

  void _startUnit() {
    _queue.clear();
    _retestPool.clear();
    _passedModes.clear();
    _wrongCount.clear();
    round = 1;
    _modeIdx = 0;

    final u = currentUnit;
    if (u == null) {
      phase = SessionPhase.done;
      return;
    }
    _queue.addAll(u.cards.map((c) => StudyStep(c, StudyMode.read, 1)));
    _roundTotal = _queue.length;

    if (u.hasPassage && u.readFirst) {
      phase = SessionPhase.passage;
    } else if (u.hasPassage && passageClozeEnabled) {
      phase = SessionPhase.passageCloze;
    } else {
      _enterLearn();
    }
  }

  void _nextUnit() {
    _unitIdx++;
    if (_unitIdx >= units.length) {
      phase = SessionPhase.done;
      return;
    }
    _startUnit();
  }

  /// 语篇通读完成 -> 语篇选词（若开启）或直接进入逐卡 learn
  void submitPassage() {
    if (passageClozeEnabled && hasPassage) {
      phase = SessionPhase.passageCloze;
    } else {
      _enterLearn();
    }
  }

  /// 语篇选词提交：整篇配对完成才算过
  void submitPassageCloze(bool ok) {
    if (ok) _enterLearn();
  }

  void _enterLearn() {
    if (_queue.isEmpty) {
      _nextUnit();
    } else {
      phase = SessionPhase.learn;
      _roundTotal = _queue.length;
    }
  }

  // ---------- 逐卡 ----------

  /// 抬高一张卡的挣扎程度（只增不减）
  void _bump(String cardId, int e) {
    if (e > (_effort[cardId] ?? 0)) _effort[cardId] = e;
  }

  /// 这张卡毕业时该写什么 FSRS 评分
  ///   0 一次过   -> good
  ///   1 费了点劲 -> hard
  ///   2 硬骨头   -> again
  Rating ratingFor(String cardId) {
    switch (_effort[cardId] ?? 0) {
      case 0:
        return Rating.good;
      case 1:
        return Rating.hard;
      default:
        return Rating.again;
    }
  }

  bool _allPassed(String id) {
    if (retestModes.isEmpty) return true;
    final passed = _passedModes[id] ?? const <String>{};
    return retestModes.every((m) => passed.contains(m.key));
  }

  /// 学习轮：提交一次自评
  void submitLearn(Rating r) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    final card = step.card;
    if (card == null) return;
    if (r == Rating.good) {
      graduated.add(card.id);
    } else {
      _retestPool.add(card);
      _bump(card.id, r == Rating.again ? 2 : 1);
    }
    _advance();
  }

  /// 重测轮：提交一个考法的对错。
  /// 答错 -> 不记通过，后面轮次继续考，直到「启用的考法」都过。
  /// 答对且该卡启用的考法全过 -> **立即毕业**并滚出重测池。
  void submitRetest(StudyMode mode, bool ok) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    final card = step.card;
    if (card == null) return;
    if (ok) {
      (_passedModes[card.id] ??= <String>{}).add(mode.key);
      if (_allPassed(card.id)) {
        _retestPool.remove(card);
        graduated.add(card.id);
      }
    } else {
      final n = (_wrongCount[card.id] ?? 0) + 1;
      _wrongCount[card.id] = n;
      _bump(card.id, n >= 2 ? 2 : 1);
    }
    _advance();
  }

  void _advance() {
    if (_queue.isNotEmpty) return;

    if (phase == SessionPhase.learn) {
      if (_retestPool.isEmpty || retestModes.isEmpty) {
        _nextUnit();
        return;
      }
      round = 2;
      _modeIdx = 0;
      _startMode();
      return;
    }

    // choice / cloze 走完 -> 下一个考法
    _modeIdx++;
    _startMode();
  }

  /// 从当前 _modeIdx 起，找第一个「还有没过卡」的启用考法，组一轮队列。
  /// 全部考法都走完：池空 -> 下一个单元；还有卡没过 -> round++ 重来。
  void _startMode() {
    while (_modeIdx < retestModes.length) {
      final m = retestModes[_modeIdx];
      final pending = _retestPool
          .where((c) => !graduated.contains(c.id))
          .where((c) =>
              !(_passedModes[c.id] ?? const <String>{}).contains(m.key))
          .toList();
      if (pending.isEmpty) {
        _modeIdx++;
        continue;
      }
      phase = (m == StudyMode.cloze) ? SessionPhase.cloze : SessionPhase.choice;
      _queue
        ..clear()
        ..addAll(pending.map((c) => StudyStep(c, m, round)));
      _roundTotal = _queue.length;
      return;
    }

    if (_retestPool.isEmpty) {
      _nextUnit();
    } else {
      round++;
      _modeIdx = 0;
      _startMode();
    }
  }
}
