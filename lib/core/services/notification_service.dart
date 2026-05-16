import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../features/ledger/domain/ledger_model.dart' show OrderTicket;

/// 全局通知服务单例。
/// 初始化：在 main() 中调用 [NotificationService.instance.init()]。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  // ─── 通知渠道常量 ────────────────────────────────────────────
  static const String _channelId = 'gonow_travel';
  static const String _channelName = '旅行提醒';
  static const String _channelDesc = '航班、高铁、酒店出行提醒';

  // ─── 初始化 ──────────────────────────────────────────────────
  Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    // 中国时区
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // ✅ 关键：显式创建通知渠道，Android 8.0+ 没有渠道通知会被系统静默丢弃
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,       // 'gonow_travel'
            _channelName,     // '旅行提醒'
            description: _channelDesc,
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );

    _initialized = true;
    debugPrint('[NotificationService] 初始化完成，渠道已创建');
  }

  // ─── 请求权限 ────────────────────────────────────────────────
  Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final bool? granted = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      
      // ✅ 先请求通知权限
      final bool? notifGranted =
          await androidPlugin?.requestNotificationsPermission();
      debugPrint('[NotificationService] 通知权限: $notifGranted');

      // ✅ 关键：精确闹钟权限，华为/小米等设备 zonedSchedule 必须有这个才能触发
      await androidPlugin?.requestExactAlarmsPermission();
      debugPrint('[NotificationService] 精确闹钟权限已请求');

      return notifGranted ?? false;
    }
    return false;
  }

  // ─── 发送即时通知（添加票务时立即推送）─────────────────────────
  Future<void> sendTicketAddedNotification(OrderTicket ticket) async {
    if (!_initialized) return;

    final _TicketNotifContent content = _buildContent(ticket, isReminder: false);

    final BigTextStyleInformation bigText = BigTextStyleInformation(
      content.expandedBody,
      contentTitle: content.title,
      summaryText: 'GoNow 旅行助手',
    );

    await _plugin.show(
      _notifIdForTicket(ticket.id, suffix: 0),
      content.title,
      content.collapsedBody,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: bigText,
          ticker: content.collapsedBody,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
    debugPrint('[NotificationService] 即时通知已发送: ${ticket.title}');
  }

  // ─── 定时提醒（出发前 N 小时）────────────────────────────────
  /// [hoursAhead] 默认 6 小时前提醒；酒店默认当天早上 8 点。
  Future<void> scheduleTicketReminder(
    OrderTicket ticket, {
    int hoursAhead = 6,
  }) async {
    if (!_initialized) return;

    final DateTime? departureTime = _parseDepartureTime(ticket);
    if (departureTime == null) {
      debugPrint('[NotificationService] 无法解析出发时间，跳过定时提醒: ${ticket.title}');
      return;
    }

    final DateTime now = DateTime.now();

    DateTime reminderTime;
    if (ticket.type == 'hotel') {
      reminderTime = DateTime(
        departureTime.year,
        departureTime.month,
        departureTime.day,
        8, 0,
      );
    } else {
      reminderTime = departureTime.subtract(Duration(hours: hoursAhead));
    }

    // ✅ 过期不丢弃，改为 5 秒后触发（临近航班也能收到提醒）
    if (reminderTime.isBefore(now)) {
      debugPrint('[NotificationService] 提醒时间已过期，改为 5 秒后触发: ${ticket.title}');
      reminderTime = now.add(const Duration(seconds: 5));
    }

    final tz.TZDateTime scheduledDate =
        tz.TZDateTime.from(reminderTime, tz.local);

    // 计算距出发剩余分钟数（用于动态文案）
    final int minutesLeft = departureTime.difference(now).inMinutes;
    final _TicketNotifContent content = _buildContent(
      ticket,
      isReminder: true,
      hoursAhead: hoursAhead,
      minutesLeft: minutesLeft,
    );

    final BigTextStyleInformation bigText = BigTextStyleInformation(
      content.expandedBody,
      contentTitle: content.title,
      summaryText: 'GoNow 旅行助手',
    );

    await _plugin.zonedSchedule(
      _notifIdForTicket(ticket.id, suffix: 1),
      content.title,
      content.collapsedBody,
      scheduledDate,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.max,   // 定时提醒用最高级，触发横幅弹出
          priority: Priority.high,
          styleInformation: bigText,
          ticker: content.collapsedBody,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
    debugPrint(
      '[NotificationService] 定时提醒已安排: ${ticket.title} @ $reminderTime',
    );
  }

  // ─── 取消指定票务的所有通知 ──────────────────────────────────
  Future<void> cancelTicketNotifications(String ticketId) async {
    if (!_initialized) return;
    await _plugin.cancel(_notifIdForTicket(ticketId, suffix: 0));
    await _plugin.cancel(_notifIdForTicket(ticketId, suffix: 1));
    debugPrint('[NotificationService] 通知已取消: $ticketId');
  }

  // ─── 内部辅助 ────────────────────────────────────────────────

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('[NotificationService] 通知被点击: ${response.payload}');
    // 可在此处导航到对应页面（通过 payload 传递 ticketId）
  }

  /// 根据 ticketId 哈希生成稳定的整型通知 ID。
  /// suffix=0 即时通知，suffix=1 定时提醒。
  int _notifIdForTicket(String ticketId, {required int suffix}) {
    final int hash = ticketId.hashCode.abs() % 100000;
    return hash * 10 + suffix;
  }

  // ─── 通知内容数据类 ──────────────────────────────────────────
  _TicketNotifContent _buildContent(
    OrderTicket ticket, {
    required bool isReminder,
    int hoursAhead = 6,
    int minutesLeft = 0,
  }) {
    switch (ticket.type) {
      case 'flight':
        return _flightContent(ticket, isReminder: isReminder, hoursAhead: hoursAhead, minutesLeft: minutesLeft);
      case 'train':
        return _trainContent(ticket, isReminder: isReminder, hoursAhead: hoursAhead, minutesLeft: minutesLeft);
      case 'hotel':
        return _hotelContent(ticket, isReminder: isReminder);
      default:
        return _TicketNotifContent(
          title: '📋 行程已添加',
          collapsedBody: ticket.title,
          expandedBody: ticket.title,
        );
    }
  }

  // ─── 航班 ────────────────────────────────────────────────────
  _TicketNotifContent _flightContent(
    OrderTicket ticket, {
    required bool isReminder,
    int hoursAhead = 6,
    int minutesLeft = 0,
  }) {
    if (!isReminder) {
      // 即时通知：刚添加
      return _TicketNotifContent(
        title: '✈️ 航班已添加',
        collapsedBody: '${ticket.locationA} ➔ ${ticket.locationB} | ${ticket.timeA} 起飞',
        expandedBody:
            '✈️  ${ticket.locationA}  ➔  ${ticket.locationB}\n'
            '🕒 起飞时间：${ticket.dateStr}  ${ticket.timeA}\n'
            '🛬 落地时间：${ticket.timeB}\n'
            '👤 乘机人：${ticket.passenger}\n'
            '💡 航班信息已记录，出发前 6 小时将再次提醒您。',
      );
    }

    // 定时提醒：出发前
    final String urgency = minutesLeft <= 60
        ? '⚠️ 请立即前往安检口，切勿延误！'
        : '🧳 建议现在出发前往机场，提前办理值机。';

    return _TicketNotifContent(
      title: '🛫 行程提醒：您的航班即将起飞！',
      collapsedBody: '${ticket.locationA} ➔ ${ticket.locationB} | ${ticket.timeA} 起飞，距起飞还有约 $hoursAhead 小时',
      expandedBody:
          '✈️  ${ticket.locationA}  ➔  ${ticket.locationB}\n'
          '🕒 起飞时间：${ticket.dateStr}  ${ticket.timeA}\n'
          '🛬 落地时间：${ticket.timeB}\n'
          '👤 乘机人：${ticket.passenger}\n'
          '$urgency',
    );
  }

  // ─── 高铁 ────────────────────────────────────────────────────
  _TicketNotifContent _trainContent(
    OrderTicket ticket, {
    required bool isReminder,
    int hoursAhead = 6,
    int minutesLeft = 0,
  }) {
    if (!isReminder) {
      return _TicketNotifContent(
        title: '🚄 高铁已添加',
        collapsedBody: '${ticket.locationA} ➔ ${ticket.locationB} | ${ticket.timeA} 发车',
        expandedBody:
            '🚄  ${ticket.locationA}  ➔  ${ticket.locationB}\n'
            '🕒 发车时间：${ticket.dateStr}  ${ticket.timeA}\n'
            '🏁 到站时间：${ticket.timeB}\n'
            '👤 乘车人：${ticket.passenger}\n'
            '💡 车票信息已记录，发车前 6 小时将再次提醒您。',
      );
    }

    final String urgency = minutesLeft <= 30
        ? '⚠️ 请立即前往候车厅，高铁不等人！'
        : '🧳 建议现在动身前往火车站，提前取票进站。';

    return _TicketNotifContent(
      title: '🚄 行程提醒：您的高铁即将发车！',
      collapsedBody: '${ticket.locationA} ➔ ${ticket.locationB} | ${ticket.timeA} 发车，距发车还有约 $hoursAhead 小时',
      expandedBody:
          '🚄  ${ticket.locationA}  ➔  ${ticket.locationB}\n'
          '🕒 发车时间：${ticket.dateStr}  ${ticket.timeA}\n'
          '🏁 到站时间：${ticket.timeB}\n'
          '👤 乘车人：${ticket.passenger}\n'
          '$urgency',
    );
  }

  // ─── 酒店 ────────────────────────────────────────────────────
  _TicketNotifContent _hotelContent(
    OrderTicket ticket, {
    required bool isReminder,
  }) {
    if (!isReminder) {
      return _TicketNotifContent(
        title: '🏨 酒店已添加',
        collapsedBody: '${ticket.title} | ${ticket.dateStr} ${ticket.timeA} 入住',
        expandedBody:
            '🏨 ${ticket.title}\n'
            '🛏️ 房型：${ticket.locationA}\n'
            '📍 地址：${ticket.locationB.isEmpty ? "暂无" : ticket.locationB}\n'
            '📅 入住：${ticket.dateStr}  ${ticket.timeA}\n'
            '👤 入住人：${ticket.passenger}\n'
            '💡 酒店信息已记录，入住当天早上 8:00 将提醒您。',
      );
    }

    return _TicketNotifContent(
      title: '🏨 入住提醒：今日可办理入住',
      collapsedBody: '${ticket.title} | 今日 ${ticket.timeA} 起可入住',
      expandedBody:
          '🏨 ${ticket.title}\n'
          '🛏️ 房型：${ticket.locationA}\n'
          '📍 地址：${ticket.locationB.isEmpty ? "暂无" : ticket.locationB}\n'
          '🔑 入住时间：今日 ${ticket.timeA} 起\n'
          '👤 入住人：${ticket.passenger}\n'
          '💡 抵店后请出示预订二维码，祝您入住愉快！',
    );
  }

  /// 解析 OrderTicket 中的出发/入住日期时间。
  /// dateStr 示例："10月1日 · 去程" 或 "10月1日" 或 "10.01"
  /// timeA 示例："10:30"
  DateTime? _parseDepartureTime(OrderTicket ticket) {
    try {
      final int year = DateTime.now().year;

      // 解析 timeA: "HH:mm"
      final RegExp timeReg = RegExp(r'(\d{1,2}):(\d{2})');
      final RegExpMatch? timeMatch = timeReg.firstMatch(ticket.timeA);
      if (timeMatch == null) return null;
      final int hour = int.parse(timeMatch.group(1)!);
      final int minute = int.parse(timeMatch.group(2)!);

      // 解析 dateStr 中的月日
      // 支持 "10月1日" / "10.01" / "2024-10-01"
      final RegExp mdReg1 = RegExp(r'(\d{1,2})月(\d{1,2})日');
      final RegExp mdReg2 = RegExp(r'(\d{1,2})[.\-/](\d{1,2})');
      final RegExp mdReg3 = RegExp(r'(\d{4})-(\d{2})-(\d{2})');

      int month = 0, day = 0;

      final RegExpMatch? m1 = mdReg1.firstMatch(ticket.dateStr);
      final RegExpMatch? m3 = mdReg3.firstMatch(ticket.dateStr);
      final RegExpMatch? m2 = mdReg2.firstMatch(ticket.dateStr);

      if (m3 != null) {
        month = int.parse(m3.group(2)!);
        day = int.parse(m3.group(3)!);
      } else if (m1 != null) {
        month = int.parse(m1.group(1)!);
        day = int.parse(m1.group(2)!);
      } else if (m2 != null) {
        month = int.parse(m2.group(1)!);
        day = int.parse(m2.group(2)!);
      } else {
        return null;
      }

      return DateTime(year, month, day, hour, minute);
    } catch (_) {
      return null;
    }
  }
}

// ─── 通知内容数据类 ──────────────────────────────────────────
class _TicketNotifContent {
  const _TicketNotifContent({
    required this.title,
    required this.collapsedBody,
    required this.expandedBody,
  });
  final String title;
  final String collapsedBody;   // 收起状态（一行）
  final String expandedBody;    // 展开状态（多行详情）
}
