/// 我的：设置 + 数据
library;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/card_store.dart';
import '../services/data_dir.dart';
import '../services/study_settings.dart';
import '../services/tts_diagnostics.dart';
import '../services/update_service.dart';
import 'debug_log_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'tts_settings_screen.dart';

class MeScreen extends StatefulWidget {
  final CardStore store;
  final StudySettings settings;

  /// 重新读公共目录里的模板（改完 CSS 点一下即可生效）
  final Future<void> Function()? onReloadTemplates;

  const MeScreen({
    super.key,
    required this.store,
    required this.settings,
    this.onReloadTemplates,
  });

  @override
  State<MeScreen> createState() => MeScreenState();
}

class MeScreenState extends State<MeScreen> {
  String _version = '';
  String _build = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  /// 读真实版本号（以前这里是写死的 'v1.0.0'，所以永远不更新）
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _build = info.buildNumber;
      });
    } catch (_) {}
  }

  /// 点版本号：跟 GitHub 最新 release 比一比
  Future<void> _checkUpdate() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('正在检查更新…'),
      duration: Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
    ));
    final remote = await UpdateService.latestVersion();
    if (!mounted) return;

    String title;
    String body;
    if (remote == null) {
      title = '检查失败';
      body = '拿不到远端版本信息。\n要么没网，要么 GitHub API 限流了，过会儿再试。';
    } else if (_version.isEmpty) {
      title = '本机版本未知';
      body = '远端最新：v$remote';
    } else if (UpdateService.isNewer(remote, _version)) {
      title = '有新版本';
      body = '本机 v$_version（+$_build）\n远端 v$remote\n\n去 GitHub Release 拉新的 APK。';
    } else {
      title = '已是最新版';
      body = '本机 v$_version（+$_build）\n远端 v$remote';
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title:
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 16)),
        content:
            Text(body, style: const TextStyle(color: Color(0xFFB7C4C8), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好', style: TextStyle(color: Color(0xFF00C08B))),
          ),
        ],
      ),
    );
  }

  Future<void> refresh() async {
    if (mounted) setState(() {});
  }

  /// TTS 自检：跑一遍引擎信息 + 试念，写 logs/tts/，弹窗给结果
  Future<void> _runTtsCheck() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('正在测 TTS…'),
      duration: Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
    ));
    final report = await TtsDiagnostics.run();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title: const Text('TTS 自检',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SelectableText(report,
            style: const TextStyle(color: Color(0xFFB7C4C8), fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好', style: TextStyle(color: Color(0xFF00C08B))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        title: const Text('我的',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0x0BFFFFFF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Row(
              children: [
                const Icon(Icons.local_fire_department,
                    color: Color(0xFFFF8A3D), size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('连续 ${s.currentStreak} 天打卡',
                          style: const TextStyle(
                              color: Color(0xFFF0F4F5),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                          '今日 ${s.todayTotal} 张 · 最长 ${s.bestStreak} 天 · 累计 ${s.totalStudyDays} 天',
                          style: const TextStyle(
                              color: Color(0xFF54666C), fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel('设置'),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.insights,
            label: '学习统计',
            value: '连续 ${s.currentStreak} 天',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatsScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.notifications_none,
            label: '背诵提醒',
            value: s.reminderEnabled ? '每天 ${s.reminderTimeLabel}' : '未开启',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.tune,
            label: '每日背诵量',
            value: '单词 ${s.wordDailyLimit} · 卡牌 ${s.cardDailyLimit}',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.record_voice_over_outlined,
            label: 'TTS 自检',
            value: '发音不对点这里',
            onTap: _runTtsCheck,
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.bug_report_outlined,
            label: '调试日志',
            value: widget.settings.ttsLogEnabled ? 'TTS 开' : 'TTS 关',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      DebugLogScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 20),
          _sectionLabel('模板'),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.dashboard_customize_outlined,
            label: '重载模板',
            value: '改完 CSS 点这里',
            onTap: () async {
              await widget.onReloadTemplates?.call();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('模板已重新读取'),
                backgroundColor: Color(0xFF1B2629),
                behavior: SnackBarBehavior.floating,
              ));
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.folder_open,
            label: '模板目录',
            value: '公共目录',
            onTap: () {
              showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF1B2629),
                  title: const Text('模板目录',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                  content: SelectableText(
                      '${DataDir.publicPath}/templates',
                      style: const TextStyle(
                          color: Color(0xFFB7C4C8), fontSize: 12)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('好',
                          style: TextStyle(color: Color(0xFF00C08B))),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          _sectionLabel('关于'),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.info_outline,
            label: 'flashcard',
            value: _version.isEmpty ? '读取中…' : 'v$_version',
            onTap: _checkUpdate,
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(
          color: Color(0xFF8C9DA2),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: .5));

  Widget _entry({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00C08B), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Color(0xFFF0F4F5), fontSize: 15)),
            ),
            Text(value,
                style: const TextStyle(
                    color: Color(0xFF54666C), fontSize: 13)),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Color(0xFF54666C)),
          ],
        ),
      ),
    );
  }
}
