/// 双向 RPC 桥（Web ↔ 壳）
/// ================================================================
/// 阶段 0：把「字符串拼 JS 单向推」升级成「请求/响应 + 事件推送」。
///
///   Web → 壳（请求/响应）
///     卡牌脚本：await Flashcard.call('card.due', { limit: 20 })
///     → JS post {type:"rpc", id, method, params}
///     → 壳查表执行 handler
///     → ctrl.runJavaScript("Flashcard.__resolve('<json>')")
///     → JS 的 Promise resolve
///
///   壳 → Web（事件）
///     壳：bridge.emit('lifecycle.pause', {})
///     → ctrl.runJavaScript("Flashcard.__emit(\"lifecycle.pause\", '<json>')")
///
/// 这一层只负责「管道」；具体有哪些方法由 register 决定。
library;

import 'dart:async';

import 'template_engine.dart';

/// RPC 方法处理器：收 params，返回可 JSON 序列化的结果
typedef RpcHandler = Future<dynamic> Function(Map<String, dynamic> params);

class BridgeRpc {
  final Map<String, RpcHandler> _handlers = {};

  /// 注册 / 覆盖一个方法。方法名建议 `域.动作`（如 `card.get`）。
  void register(String method, RpcHandler handler) {
    _handlers[method] = handler;
  }

  void registerAll(Map<String, RpcHandler> handlers) {
    _handlers.addAll(handlers);
  }

  bool has(String method) => _handlers.containsKey(method);

  /// 已注册的方法名（排序，便于日志 / 自检）
  List<String> get methods => _handlers.keys.toList()..sort();

  /// 处理一条来自 Web 的请求，返回要喂给 runJavaScript 的回执脚本。
  ///
  /// 任何异常都被兜住并回 `ok:false` —— 绝不让一条坏请求把桥打断。
  Future<String> dispatch(
      int id, String method, Map<String, dynamic> params) async {
    final h = _handlers[method];
    if (h == null) {
      return resolveScript(id, false, {'error': 'unknown method: $method'});
    }
    try {
      final result = await h(params);
      return resolveScript(id, true, result);
    } catch (e) {
      return resolveScript(id, false, {'error': e.toString()});
    }
  }

  /// 回执脚本：JSON 先编码再按 JS 单引号字符串转义（复用 jsonForJs）。
  static String resolveScript(int id, bool ok, dynamic result) {
    final payload = TemplateEngine.jsonForJs(
        <String, dynamic>{'id': id, 'ok': ok, 'result': result});
    return 'window.Flashcard&&window.Flashcard.__resolve&&'
        "window.Flashcard.__resolve('$payload');";
  }

  /// 事件脚本：事件名走 JSON 编码（双引号字面量，合法 JS），
  /// 数据走单引号包裹的 JSON 文本，JS 侧 JSON.parse。
  static String emitScript(String event, dynamic data) {
    final evt = TemplateEngine.jsonForJs(event);
    final payload =
        TemplateEngine.jsonForJs(data ?? const <String, dynamic>{});
    return 'window.Flashcard&&window.Flashcard.__emit&&'
        "window.Flashcard.__emit($evt,'$payload');";
  }
}
