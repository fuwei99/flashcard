/// 会话状态机（轮内状态）
/// ================================================================
/// 只管「这一轮」的事：队列、阶段、轮次、通过与否。
/// 绝不碰持久层 —— 卡片的长期调度（FSRS）由屏幕在「毕业」时写。
///
/// 流程（2026-09 语篇版）：
///   passage 轮（章首语篇通读，辅助记忆）        [仅当本章带 passage]
///     点「进入单词背诵」-> passageCloze（若开启）或直接 learn
///   passageCloze 轮（语篇选词，整篇配对，过关才走）  [可被设置关闭]
///   learn 轮（逐卡 read 自评）
///     记得        -> 直接毕业
///     模糊 / 忘记  -> 进重测池
///   重测轮（循环，直到池内每张卡把「启用的考法」全过）
///     考法顺序固定：choice（语义选项）-> cloze（短句选词），
///     关闭的考法直接跳过。每个考法各一次把池里没过的卡考完；
///     一轮走完还有没过 -> round++，回第一个启用的考法。
///     一张卡启用的考法全过 -> **立即毕业**并滚出重测池。
///   done
///
/// 两阶段分开的原因（老规矩）：不让同一张卡的 choice / cloze 挨着考 ——
/// 先让所有卡过完 choice，再让所有卡过 cloze，避免上一题刚见过答案。
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
/// 语篇两轮没有具体卡片，card 为 null。
class StudyStep {
  final FlashCard? card;
  final StudyMode mode;
  final int round;
  const StudyStep(this.card, this.mode, this.round);
}

class StudySession {
  final List<StudyStep> _queue = [];
  final List<FlashCard> _retestPool = [];

  /// 已毕业的卡 id（本轮内）
  final Set<String> graduated = {};

  /// 重测阶段里每张卡的考法通过记录：cardId -> {mode keys}
  final Map<String, Set<String>> _passedModes = {};

  /// 本轮「挣扎程度」：0 = 一次过，1 = 费了点劲，2 = 硬骨头。
  final Map<String, int> _effort = {};

  /// 这张卡答错的次数
  final Map<String, int> _wrongCount = {};

  /// 本章语篇（可空 —— 老卡组没写就跳过语篇两阶段）
  final Passage? passage;

  /// 语篇选词是否开启（设置项）
  final bool passageClozeEnabled;

  /// 启用的重测考法，按顺序（语义选项在前、短句选词在后）
  final List<StudyMode> retestModes;

  SessionPhase phase = SessionPhase.learn;
  int round = 1;
  int _roundTotal = 0;
  int _modeIdx = 0;

  StudySession(
    List<FlashCard> cards, {
    this.passage,
    this.passageClozeEnabled = true,
    this.retestModes = const [StudyMode.choice, StudyMode.cloze],
  }) {
    _queue.addAll(cards.map((c) => StudyStep(c, StudyMode.read, 1)));
    _roundTotal = _queue.length;

    if (passage != null && passage!.hasContent) {
      phase = SessionPhase.passage;
    } else if (cards.isEmpty) {
      phase = SessionPhase.done;
    } else {
      phase = SessionPhase.learn;
    }
  }

  bool get hasPassage => passage != null && passage!.hasContent;

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
      phase = SessionPhase.done;
    } else {
      phase = SessionPhase.learn;
      _roundTotal = _queue.length;
    }
  }

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
        phase = SessionPhase.done;
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
  /// 全部考法都走完：池空 -> done；还有卡没过 -> round++ 重来。
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

    // 本轮所有考法都走完
    if (_retestPool.isEmpty) {
      phase = SessionPhase.done;
    } else {
      round++;
      _modeIdx = 0;
      _startMode();
    }
  }
}
