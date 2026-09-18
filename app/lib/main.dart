/// flashcard · 入口
/// 书架 -> 书 -> 章 -> 页 -> 背诵
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models/deck.dart';
import 'screens/main_scaffold.dart';
import 'services/card_store.dart';
import 'services/crash_log.dart';
import 'services/data_dir.dart';
import 'services/deck_repository.dart';
import 'services/plugin.dart';
import 'services/hot_reload.dart';
import 'services/reminder_service.dart';
import 'services/status_writer.dart';
import 'services/study_settings.dart';

void main() {
  // 全局错误钩子必须在 runApp 之前装 —— 启动阶段是最容易炸的一段，
  // 装晚了这段的异常一条都留不下。
  //
  // runZonedGuarded 兜 zone 内逃逸的异常；框架层和引擎层各自还有
  // FlutterError.onError / PlatformDispatcher.onError（见 CrashLog.install）。
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      CrashLog.install();
      // 解析崩溃日志的兜底目录（公共目录没授权时用它）
      unawaited(CrashLog.init());
      runApp(const FlashcardApp());
    },
    (Object e, StackTrace s) => CrashLog.record('zone', e, s),
  );
}

class FlashcardApp extends StatelessWidget {
  const FlashcardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flashcard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141D1F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00C08B),
          surface: Color(0xFF141D1F),
        ),
      ),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final _repo = DeckRepository();
  final _store = CardStore();
  final _settings = StudySettings();

  Map<String, CardTemplate>? _templates;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _store.init();
      await _settings.init();
      // 插件系统：扫内置 + 用户插件，读上次选中的 TTS/LLM 插件
      await PluginManager.I.load();
      await ReminderService.init();
      await _applyReminder();
      // 首次运行：把内置模板铺到公共目录，之后改 CSS/HTML/JS 直接改文件
      await _repo.seedPublicTemplates();
      // 说明文档也铺到公共目录（版本感知，用户改过的不覆盖）
      await _repo.seedReadme();
      final templates = await _repo.loadAllTemplates();

      // status.json：给外部监工（AI）读的只读快照。之后背卡 / 进后台会刷新。
      StatusWriter.I.init(
        settings: _settings,
        store: _store,
        loadBooks: _repo.loadAllBooks,
      );
      // 诊断段：上一次运行崩没崩、有没有该清的旧模板残留。
      // 读的是 logs/crash/last_crash.json（上一轮写的），所以放在 write 之前。
      StatusWriter.I.crashLast = CrashLog.readLastCrash();
      StatusWriter.I.crashCount = CrashLog.recent.length;
      try {
        StatusWriter.I.staleTemplates = await _repo.staleBuiltinTemplates();
      } catch (_) {}
      // 公共目录变更指纹基线：首帧建立，之后回前台才比较
      await HotReload.resync();

      if (!mounted) return;
      setState(() => _templates = templates);
      // 进 APP 就申请「全部文件访问权」，放到首帧之后避免 build 冲突
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        _askPermission();
        await StatusWriter.I.write();
      });
    } catch (e, st) {
      CrashLog.record('boot', e, st);
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// 启动时按设置恢复「每日提醒」排程
  Future<void> _applyReminder() async {
    try {
      if (_settings.reminderEnabled) {
        await ReminderService.scheduleDaily(
            _settings.reminderHour, _settings.reminderMinute);
      } else {
        await ReminderService.cancel();
      }
    } catch (_) {}
  }

  /// 重新读模板：改完 CSS/HTML/JS 不用重装，点一下即可生效
  Future<void> _reloadTemplates() async {
    final templates = await _repo.loadAllTemplates();
    if (!mounted) return;
    setState(() => _templates = templates);
  }

  Future<void> _askPermission() async {
    if (!Platform.isAndroid) return;
    try {
      if (await Permission.manageExternalStorage.isGranted) return;
      final st = await Permission.manageExternalStorage.request();
      if (!st.isGranted) {
        // 老系统回退到普通存储权限
        await Permission.storage.request();
      }
    } catch (_) {}
    await _rebindAfterPermission();
  }

  /// 授权弹窗走完后重新探测一次公共目录。
  ///
  /// 首次安装时 _boot 里那次探测必然失败（此时还没权限），以前失败结果会被
  /// 永久缓存 —— 用户点了「允许」也要重启 App 才生效。这里补一次。
  Future<void> _rebindAfterPermission() async {
    try {
      if (DataDir.available) return;
      if (await DataDir.recheck() == null) return;
      await _store.rebind();
      await _settings.rebind();
      // 公共目录刚可用：模板 / 说明文档 / 热重载基线在 _boot 时没铺成，补上
      await _repo.seedPublicTemplates();
      await _repo.seedReadme();
      await HotReload.resync();
      StatusWriter.I.writeThrottled();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('初始化失败',
                    style: TextStyle(color: Color(0xFFFF5C5C), fontSize: 16)),
                const SizedBox(height: 8),
                Text('$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Color(0xFFB7C4C8), fontSize: 12)),
                const SizedBox(height: 16),
                const Text('堆栈已落盘：Documents/Flashcard/logs/crash/',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Color(0xFF54666C), fontSize: 11)),
              ],
            ),
          ),
        ),
      );
    }
    if (_templates == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00C08B)),
        ),
      );
    }
    return MainScaffold(
      repo: _repo,
      templates: _templates!,
      store: _store,
      settings: _settings,
      onReloadTemplates: _reloadTemplates,
    );
  }
}
