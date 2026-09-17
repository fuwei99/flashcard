/// 会话计划：把编排好的 StudyUnit 序列化成 workflow.js 能自己跑的数据。
/// ================================================================
/// 阶段 4：切牌流程搬进卡牌包（workflow.js），壳退成原子能力。
/// 壳用 StudyPlanner 排好「今天给谁」，把这份计划交给 workflow.js，
/// 之后「下一张挂什么、什么时候重测、什么时候毕业」全由 JS 决定。
///
/// 计划里**不带卡片完整字段**（几百 KB 会炸 WebView）——只带流程决策要的：
///   id / word / 可用考法(modes)
/// 渲染要的字段，壳在收到 web.mount 时按 id 自己取。
library;

import '../models/book.dart';
import '../models/deck.dart';
import '../models/study_session.dart';

class SessionPlan {
  /// 构建计划。
  /// [passageJson] 由 WebViewBridge 提供（语篇解析成模板友好结构）。
  static Map<String, dynamic> build({
    required List<StudyUnit> units,
    required bool passageCloze,
    required List<String> retestModes,
    required Map<String, dynamic> Function(
            Passage p, List<FlashCard> cards, Set<String>? blank)
        passageJson,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final u in units) {
      final cards = <Map<String, dynamic>>[];
      for (final c in u.cards) {
        cards.add({
          'id': c.id,
          'word': c.word,
          'modes': modesFor(c, retestModes),
        });
      }
      out.add({
        'title': u.title,
        'isReview': u.isReview,
        'readFirst': u.readFirst,
        'hasPassage': u.hasPassage,
        'blankLemmas': u.blankLemmas?.toList() ?? <String>[],
        'passage': u.hasPassage
            ? passageJson(u.passage!, u.passageLookup, u.blankLemmas)
            : null,
        'cards': cards,
      });
    }
    // 模式直给：壳是唯一真相源，模板别再自己从 units[].isReview 猜。
    // 聚合逻辑只此一处，混合批次不会再「壳判 review、模板判 learn」。
    final anyReview = units.any((u) => u.isReview);
    final anyNew = units.any((u) => !u.isReview);
    return {
      'mode': (anyReview && !anyNew) ? 'review' : 'learn',
      'passageCloze': passageCloze,
      'retestModes': retestModes,
      'units': out,
    };
  }

  /// 这张卡实际可考的考法（缺字段就摘掉，避免卡死在重测池里空转）
  static List<String> modesFor(FlashCard c, List<String> retestModes) {
    return [
      for (final m in retestModes)
        if (m == 'cloze'
            ? c.hasSentence
            : m == 'choice'
                ? c.senses.isNotEmpty
                : true)
          m,
    ];
  }
}
