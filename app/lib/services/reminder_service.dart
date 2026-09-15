/// 每日背诵提醒（本地通知）
/// ================================================================
/// 用 flutter_local_notifications 排一条「每天固定时刻」的本地通知。
/// 不用精确闹钟（inexactAllowWhileIdle），免去 SCHEDULE_EXACT_ALARM 权限折腾，
/// 偏差几分钟对「该背单词了」完全够用。
///
/// 时间换算：用 DateTime.now() 的本地墙钟算出目标时刻，再 toUtc() 转成
/// TZDateTime.utc 交给插件。这样不依赖时区数据库/设备时区名；
/// 中国等无夏令时的时区完全精确，有夏令时的地区换季会偏 1 小时（可接受）。
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

class ReminderService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const int _dailyId = 1001;
  static const String _channelId = 'fc_daily_reminder';
  static const String _channelName = '背诵提醒';

  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    try {
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: darwin),
      );
      _inited = true;
    } catch (_) {
      // 初始化失败不应阻断 App 启动
    }
  }

  /// 申请通知权限（Android 13+ 需要）；返回是否拿到
  static Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      final ok = await android.requestNotificationsPermission();
      return ok ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 排「每天 hour:minute」的提醒；重复调用会覆盖旧的
  static Future<void> scheduleDaily(int hour, int minute) async {
    await init();
    await cancel();
    try {
      final now = DateTime.now();
      var target =
          DateTime(now.year, now.month, now.day, hour, minute);
      if (!target.isAfter(now)) {
        target = target.add(const Duration(days: 1));
      }
      final u = target.toUtc();
      final when =
          tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute);

      await _plugin.zonedSchedule(
        _dailyId,
        '该背单词啦 📚',
        '今天的背诵任务还没完成，来记几个词吧～',
        when,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '每天固定时间提醒你背单词',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // 排程失败（无权限/系统限制）不阻断
    }
  }

  static Future<void> cancel() async {
    try {
      await _plugin.cancel(_dailyId);
    } catch (_) {}
  }
}
