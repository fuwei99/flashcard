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

enum SessionPhase {
  passage,
  passageCloze,
  learn,
  choice,
  cloze,

  /// 一轮（复习段 / 新学段）走完，等用户选「开始拼写 / 跳过」
  spellPrompt,

  /// 拼写轮进行中 —— 循环跑在模板里，这里只等它回报 spellDone
  spell,

  done,
}

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

  /// 前导「复习单元」个数（StudyPlanner 保证复习段排在新学段前面）。
  /// 复习段走完先问一次拼写；全部单元走完再问一次。
  int _leadingReviewCount = 0;
  bool _reviewSpellDone = false;
  bool _finalSpellDone = false;

  /// 拼写轮结束后：true = 接着开下一个单元；false = 整场结束
  bool _spellReturnsToUnits = false;

  /// 当前拼写轮要考的卡
  List<FlashCard> _spellCards = const [];
  int _spellDoneCount = 0;

  StudySession(
    List<StudyUnit> units, {
    this.passageClozeEnabled = true,
    this.retestModes = const [StudyMode.choice, StudyMode.cloze],
  }) : units = units {
    // 前导的复习单元有几个 —— 复习段和新学段的分界线
    var n = 0;
    for (final u in units) {
      if (!u.isReview) break;
      n++;
    }
    _leadingReviewCount = n;

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
      case SessionPhase.spellPrompt:
      case SessionPhase.spell:
        return null; // 拼写轮没有「当前卡片」—— 整轮由模板自己跑
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
      case SessionPhase.spellPrompt:
      case SessionPhase.spell:
        return _spellCards.length;
      default:
        return _roundTotal;
    }
  }

  int get doneInRound {
    switch (phase) {
      case SessionPhase.passage:
      case SessionPhase.passageCloze:
        return 0;
      case SessionPhase.spellPrompt:
      case SessionPhase.spell:
        return _spellDoneCount;
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

    // 复习段 → 新学段 的分界：先把「复习这一轮」的拼写过掉
    if (!_reviewSpellDone &&
        _leadingReviewCount > 0 &&
        _unitIdx == _leadingReviewCount &&
        _unitIdx < units.length) {
      _reviewSpellDone = true;
      final cards = _cardsBetween(0, _leadingReviewCount);
      if (cards.isNotEmpty) {
        _spellCards = cards;
        _spellReturnsToUnits = true;
        _spellDoneCount = 0;
        phase = SessionPhase.spellPrompt;
        return;
      }
    }

    if (_unitIdx >= units.length) {
      // 全部单元走完 → 最后一场拼写（新学段；只有复习段时就是复习那轮）
      if (!_finalSpellDone) {
        _finalSpellDone = true;
        final from = _reviewSpellDone ? _leadingReviewCount : 0;
        final cards = _cardsBetween(from, units.length);
        if (cards.isNotEmpty) {
          _spellCards = cards;
          _spellReturnsToUnits = false;
          _spellDoneCount = 0;
          phase = SessionPhase.spellPrompt;
          return;
        }
      }
      phase = SessionPhase.done;
      return;
    }

    _startUnit();
  }

  /// 把 [from, to) 号单元的卡片合成一轮拼写清单（去重，保序）
  List<FlashCard> _cardsBetween(int from, int to) {
    final out = <FlashCard>[];
    final seen = <String>{};
    for (var i = from; i < to && i < units.length; i++) {
      for (final c in units[i].cards) {
        if (seen.add(c.id)) out.add(c);
      }
    }
    return out;
  }

  // ---------- 拼写轮 ----------
  //
  // 只负责「什么时候问」和「问完往哪走」。真正一轮拼写的循环
  // （逐格输入 / 跳过 / 提示 / 忘记了 / 三次机会 / 放回队尾）跑在模板里，
  // 跑完回报 spellDone。
  //
  // **不写 FSRS**：拼写是加练，不该动 due / stability / difficulty。

  /// 当前拼写轮要考的卡（spellPrompt / spell 阶段有效）
  List<FlashCard> get spellCards => List.unmodifiable(_spellCards);

  /// 用户在弹窗里点了「开始拼写」
  void beginSpell() {
    if (phase != SessionPhase.spellPrompt) return;
    _spellDoneCount = 0;
    phase = SessionPhase.spell;
  }

  /// 拼写轮结束（全部拼过 / 用户点「结束拼写」）
  void endSpell() {
    if (phase != SessionPhase.spellPrompt && phase != SessionPhase.spell) {
      return;
    }
    _spellCards = const [];
    _spellDoneCount = 0;
    if (_spellReturnsToUnits) {
      _spellReturnsToUnits = false;
      _startUnit();
    } else {
      phase = SessionPhase.done;
    }
  }

  /// 模板回报拼写进度（原生顶栏显示用）
  void setSpellProgress(int done) {
    _spellDoneCount = done < 0 ? 0 : done;
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

  /// 这张卡**实际**要考的考法。
  /// 缺字段就把对应考法摘掉 —— 否则这张卡会因为「永远过不了那一关」
  /// 被永久卡在重测池里，出现空题干 / 无选项的死页面。
  ///   cloze  —— 要有例句（没例句挖不出空）
  ///   choice —— 要有词义（没词义出不了选项）
  List<StudyMode> _modesFor(FlashCard c) {
    return retestModes.where((m) {
      switch (m) {
        case StudyMode.cloze:
          return c.hasSentence;
        case StudyMode.choice:
          return c.senses.isNotEmpty;
        default:
          return true;
      }
    }).toList();
  }

  bool _allPassed(FlashCard c) {
    final modes = _modesFor(c);
    if (modes.isEmpty) return true;
    final passed = _passedModes[c.id] ?? const <String>{};
    return modes.every((m) => passed.contains(m.key));
  }

  /// 学习轮：提交一次自评
  void submitLearn(Rating r) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    final card = step.card;
    if (card == null) return;
    // 没有任何可用考法（既没词义也没例句）→ 直接毕业，
    // 别丢进重测池空转（否则 _startMode 找不到任何待考卡会死循环）。
    if (r == Rating.good || _modesFor(card).isEmpty) {
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
      if (_allPassed(card)) {
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
    // 兜底：池里若只剩「没有任何可用考法」的卡，直接让它们毕业，
    // 避免 while 循环空转（理论上 submitLearn 已挡，这里再保一道）。
    final stuck =
        _retestPool.where((c) => _modesFor(c).isEmpty).toList();
    for (final c in stuck) {
      _retestPool.remove(c);
      graduated.add(c.id);
    }

    while (_modeIdx < retestModes.length) {
      final m = retestModes[_modeIdx];
      final pending = _retestPool
          .where((c) => !graduated.contains(c.id))
          // 这张卡压根考不了这个考法（缺例句 / 缺词义）→ 不算待考
          .where((c) => _modesFor(c).contains(m))
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
