import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gonow/core/services/notification_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../domain/expense_model.dart';
import '../domain/ledger_model.dart' show LedgerBook, OrderTicket;

/// 旅行账本状态：Supabase 云端持久化 + 乐观更新。
class LedgerProvider extends ChangeNotifier {
  // ─── 私有状态 ───────────────────────────────────────────────
  final List<Expense> _expenses = <Expense>[];
  final List<OrderTicket> _tickets = <OrderTicket>[];
  final List<LedgerBook> _ledgers = <LedgerBook>[];
  LedgerBook? _currentLedger;

  // ─── 公开 Getters ───────────────────────────────────────────
  List<Expense> get expenses {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) return List<Expense>.unmodifiable(<Expense>[]);
    return List<Expense>.unmodifiable(
      _expenses.where((Expense e) => e.ledgerId == ledgerId),
    );
  }

  List<LedgerBook> get ledgers => List<LedgerBook>.unmodifiable(_ledgers);
  LedgerBook? get currentLedger => _currentLedger;

  List<OrderTicket> get currentTickets {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) return List<OrderTicket>.unmodifiable(<OrderTicket>[]);
    return List<OrderTicket>.unmodifiable(
      _tickets.where((OrderTicket t) => t.ledgerId == ledgerId),
    );
  }

  // 兼容旧 UI 字段。
  String currentUserDisplayName = '我';
  List<Expense> get currentExpenses => expenses;
  List<String> get currentMembers => _currentLedger?.members ?? <String>['我'];
  int get participantCount => currentMembers.length;
  double get myNetBalance => myBalance;

  // ─── Supabase 客户端 ────────────────────────────────────────
  SupabaseClient get _db => Supabase.instance.client;
  String? get _uid => _db.auth.currentUser?.id;
  final Uuid _uuid = const Uuid();

  // ──────────────────────────────────────────────────────────────
  // 初始化：拉取账本列表（含新用户模板注入）
  // ──────────────────────────────────────────────────────────────
  Future<void> fetchLedgers() async {
    final String? uid = _uid;
    if (uid == null) {
      debugPrint('[LedgerProvider] fetchLedgers: uid is null, user not logged in');
      return;
    }

    try {
      final List<Map<String, dynamic>> rows = await _db
          .from('ledger_books')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);

      if (rows.isEmpty) {
        debugPrint('[LedgerProvider] New user detected, seeding demo template...');
        await _trySeedDemoTemplate(uid);
        return;
      }

      _ledgers
        ..clear()
        ..addAll(rows.map(_rowToLedger));

      if (_currentLedger == null ||
          !_ledgers.any((LedgerBook l) => l.id == _currentLedger!.id)) {
        _currentLedger = _ledgers.first;
      }
      notifyListeners();

      await Future.wait(<Future<void>>[
        fetchExpenses(_currentLedger!.id),
        fetchTickets(_currentLedger!.id),
      ]);
    } catch (e, st) {
      debugPrint('[LedgerProvider] fetchLedgers error: $e\n$st');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 新用户演示模板注入
  // ──────────────────────────────────────────────────────────────
  Future<void> _trySeedDemoTemplate(String uid) async {
    String? demoId;

    // Step 1: 创建账本
    try {
      final List<Map<String, dynamic>> bookRows = await _db
          .from('ledger_books')
          .insert(<String, dynamic>{
            'user_id': uid,
            'title': '示例 · 北京五日带父母游',
            'is_settled': false,
          })
          .select();
      if (bookRows.isEmpty) return;
      demoId = bookRows.first['id'] as String;
      debugPrint('✅ 模板：账本创建成功 ID: $demoId');
    } catch (e, st) {
      debugPrint('❌ 模板：账本创建失败: $e\n$st');
      return;
    }

    final String lid = demoId;

    // Step 2: 写入流水
    try {
      await _db.from('ledger_expenses').insert(<Map<String, dynamic>>[
        <String, dynamic>{
          'ledger_id': lid,
          'title': '接机专车',
          'amount': 120.0,
          'payer': 'Leo',
          'participants': <String>['我', 'Leo', 'Mia', 'Tom'],
        },
        <String, dynamic>{
          'ledger_id': lid,
          'title': '海鲜大排档晚餐',
          'amount': 850.0,
          'payer': '我',
          'participants': <String>['我', 'Leo', 'Mia', 'Tom'],
        },
        <String, dynamic>{
          'ledger_id': lid,
          'title': '环岛游艇门票',
          'amount': 600.0,
          'payer': 'Mia',
          'participants': <String>['我', 'Leo', 'Mia', 'Tom'],
        },
      ]);
      debugPrint('✅ 模板：流水创建成功');
    } catch (e, st) {
      debugPrint('❌ 模板：流水写入失败: $e\n$st');
    }

    // Step 3: 写入票务
    try {
      await _db.from('ledger_tickets').insert(<Map<String, dynamic>>[
        <String, dynamic>{
          'ledger_id': lid,
          'type': 'flight',
          'title': 'CA1356',
          'date_str': '10月1日 · 去程',
          'time_a': '10:30',
          'time_b': '13:55',
          'loc_a': '北京 PEK',
          'loc_b': '三亚 SYX',
          'passenger': 'Leo',
          'sort_order': 0,
        },
        <String, dynamic>{
          'ledger_id': lid,
          'type': 'hotel',
          'title': '亚特兰蒂斯酒店',
          'date_str': '10月1日',
          'time_a': '14:00',
          'time_b': '12:00',
          'loc_a': '海景大床房',
          'loc_b': '海南省三亚市海棠湾',
          'passenger': 'Leo',
          'sort_order': 1,
        },
      ]);
      debugPrint('✅ 模板：票务创建成功');
    } catch (e, st) {
      debugPrint('❌ 模板：票务写入失败: $e\n$st');
    }

    await fetchLedgers();
  }

  // ──────────────────────────────────────────────────────────────
  // 拉取当前账本的消费流水
  // ──────────────────────────────────────────────────────────────
  Future<void> fetchExpenses(String ledgerId) async {
    try {
      final List<Map<String, dynamic>> rows = await _db
          .from('ledger_expenses')
          .select()
          .eq('ledger_id', ledgerId)
          .order('created_at', ascending: false);

      _expenses.removeWhere((Expense e) => e.ledgerId == ledgerId);
      _expenses.insertAll(0, rows.map(_rowToExpense));
      notifyListeners();
    } catch (e, st) {
      debugPrint('[LedgerProvider] fetchExpenses error: $e\n$st');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 拉取当前账本的票务
  // ──────────────────────────────────────────────────────────────
  Future<void> fetchTickets(String ledgerId) async {
    try {
      final List<Map<String, dynamic>> rows = await _db
          .from('ledger_tickets')
          .select()
          .eq('ledger_id', ledgerId)
          .order('sort_order', ascending: true);

      _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);
      _tickets.addAll(rows.map(_rowToTicket));
      notifyListeners();
    } catch (e, st) {
      debugPrint('[LedgerProvider] fetchTickets error: $e\n$st');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // CRUD：消费流水（乐观更新）
  // ──────────────────────────────────────────────────────────────

  bool _isValidUuid(String id) {
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(id);
  }

  Future<void> addExpense(Expense expense) async {
    final String ledgerId = _currentLedger?.id ?? '';
    final String validId = _isValidUuid(expense.id) ? expense.id : _uuid.v4();

    final Expense normalized = Expense(
      id: validId,
      ledgerId: expense.ledgerId.isEmpty ? ledgerId : expense.ledgerId,
      title: expense.title,
      amount: expense.amount,
      payer: expense.payer,
      participants: expense.participants,
      date: expense.date,
      iconStr: expense.iconStr,
    );

    _expenses.insert(0, normalized);
    notifyListeners();

    try {
      await _db.from('ledger_expenses').insert(<String, dynamic>{
        'id': normalized.id,
        'ledger_id': normalized.ledgerId,
        'title': normalized.title,
        'amount': normalized.amount,
        'payer': normalized.payer,
        'participants': normalized.participants,
      });
    } catch (e, st) {
      debugPrint('[LedgerProvider] addExpense sync error: $e\n$st');
    }
  }

  Future<void> updateExpense(String id, Expense updatedExpense) async {
    final int index = _expenses.indexWhere((Expense e) => e.id == id);
    if (index == -1) return;

    final String ledgerId = _currentLedger?.id ?? '';
    final Expense normalized = updatedExpense.ledgerId.isEmpty
        ? _copyExpenseWithLedger(updatedExpense, ledgerId)
        : updatedExpense;

    // 1. 乐观更新本地。
    _expenses[index] = normalized;
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_expenses').update(<String, dynamic>{
        'title': normalized.title,
        'amount': normalized.amount,
        'payer': normalized.payer,
        'participants': normalized.participants,
      }).eq('id', id);
    } catch (e, st) {
      debugPrint('[LedgerProvider] updateExpense sync error: $e\n$st');
    }
  }

  Future<void> deleteExpense(String id) async {
    // 1. 乐观删除本地。
    _expenses.removeWhere((Expense e) => e.id == id);
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_expenses').delete().eq('id', id);
    } catch (e, st) {
      debugPrint('[LedgerProvider] deleteExpense sync error: $e\n$st');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // CRUD：票务（乐观更新）
  // ──────────────────────────────────────────────────────────────

  Future<void> addTicket(OrderTicket ticket) async {
    final int sortOrder = currentTickets.length;
    final String validId = _isValidUuid(ticket.id) ? ticket.id : _uuid.v4();
    final String ledgerId = _currentLedger?.id ?? '';

    final OrderTicket normalized = OrderTicket(
      id: validId,
      ledgerId: ticket.ledgerId.isEmpty ? ledgerId : ticket.ledgerId,
      type: ticket.type,
      title: ticket.title,
      dateStr: ticket.dateStr,
      timeA: ticket.timeA,
      timeB: ticket.timeB,
      locationA: ticket.locationA,
      locationB: ticket.locationB,
      passenger: ticket.passenger,
    );

    _tickets.insert(0, normalized);
    notifyListeners();

    // ✅ 只保留定时提醒（添加时不弹即时通知）
    unawaited(NotificationService.instance.scheduleTicketReminder(normalized));

    try {
      await _db.from('ledger_tickets').insert(<String, dynamic>{
        'id': normalized.id,
        'ledger_id': normalized.ledgerId,
        'type': normalized.type,
        'title': normalized.title,
        'date_str': normalized.dateStr,
        'time_a': normalized.timeA,
        'time_b': normalized.timeB,
        'loc_a': normalized.locationA,
        'loc_b': normalized.locationB,
        'passenger': normalized.passenger,
        'sort_order': sortOrder,
      });
    } catch (e, st) {
      debugPrint('[LedgerProvider] addTicket sync error: $e\n$st');
    }
  }

  Future<void> updateTicket(String id, OrderTicket updated) async {
    final int index = _tickets.indexWhere((OrderTicket t) => t.id == id);
    if (index == -1) return;

    // 1. 乐观更新本地。
    _tickets[index] = updated;
    notifyListeners();

    // ✅ 新增：取消旧通知 + 重新安排
    unawaited(NotificationService.instance.cancelTicketNotifications(id));
    unawaited(NotificationService.instance.scheduleTicketReminder(updated));

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_tickets').update(<String, dynamic>{
        'type': updated.type,
        'title': updated.title,
        'date_str': updated.dateStr,
        'time_a': updated.timeA,
        'time_b': updated.timeB,
        'loc_a': updated.locationA,
        'loc_b': updated.locationB,
        'passenger': updated.passenger,
      }).eq('id', id);
    } catch (e, st) {
      debugPrint('[LedgerProvider] updateTicket sync error: $e\n$st');
    }
  }

  Future<void> deleteTicket(String id) async {
    // 1. 乐观删除本地。
    _tickets.removeWhere((OrderTicket t) => t.id == id);
    notifyListeners();

    // ✅ 新增：取消该票务的所有通知
    unawaited(NotificationService.instance.cancelTicketNotifications(id));

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_tickets').delete().eq('id', id);
    } catch (e, st) {
      debugPrint('[LedgerProvider] deleteTicket sync error: $e\n$st');
    }
  }

  /// 在当前账本可见列表维度上重排，并异步批量更新 sort_order。
  Future<void> reorderTickets(int oldIndex, int newIndex) async {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) return;

    final List<OrderTicket> ledgerTickets = _tickets
        .where((OrderTicket t) => t.ledgerId == ledgerId)
        .toList();

    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= ledgerTickets.length) return;
    if (newIndex < 0 || newIndex > ledgerTickets.length) return;

    // 1. 乐观更新本地排序。
    final OrderTicket moved = ledgerTickets.removeAt(oldIndex);
    ledgerTickets.insert(newIndex, moved);

    int firstIdx = _tickets.indexWhere((OrderTicket t) => t.ledgerId == ledgerId);
    if (firstIdx == -1) firstIdx = _tickets.length;
    _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);
    _tickets.insertAll(firstIdx.clamp(0, _tickets.length), ledgerTickets);
    notifyListeners();

    // 2. 静默批量更新 sort_order。
    try {
      for (int i = 0; i < ledgerTickets.length; i++) {
        await _db
            .from('ledger_tickets')
            .update(<String, dynamic>{'sort_order': i})
            .eq('id', ledgerTickets[i].id);
      }
    } catch (e, st) {
      debugPrint('[LedgerProvider] reorderTickets sync error: $e\n$st');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 账本管理
  // ──────────────────────────────────────────────────────────────

  Future<void> switchLedger(LedgerBook ledger) async {
    _currentLedger = ledger;
    // 不清空其他账本缓存，切换指针后拉取目标账本数据即可。
    notifyListeners();
    await Future.wait(<Future<void>>[
      fetchExpenses(ledger.id),
      fetchTickets(ledger.id),
    ]);
  }

  Future<void> createNewLedger(String title, List<String> members) async {
    final String? uid = _uid;
    if (uid == null) return;

    // 1. 乐观创建本地占位账本（临时 ID）。
    final String tempId = 'tmp_${DateTime.now().millisecondsSinceEpoch}';
    final LedgerBook tempLedger = LedgerBook(
      id: tempId,
      title: title,
      members: List<String>.from(members),
      createdAt: DateTime.now(),
      isSettled: false,
    );
    _ledgers.insert(0, tempLedger);
    _currentLedger = tempLedger;
    notifyListeners();

    // 2. 静默同步云端，拿到真实 UUID 后替换本地临时记录。
    try {
      final List<Map<String, dynamic>> rows = await _db
          .from('ledger_books')
          .insert(<String, dynamic>{
            'user_id': uid,
            'title': title,
            'is_settled': false,
          })
          .select();

      if (rows.isNotEmpty) {
        final LedgerBook real = LedgerBook(
          id: rows.first['id'] as String,
          title: title,
          members: List<String>.from(members),
          createdAt: DateTime.parse(rows.first['created_at'] as String),
          isSettled: false,
        );
        final int idx = _ledgers.indexWhere((LedgerBook l) => l.id == tempId);
        if (idx != -1) _ledgers[idx] = real;
        if (_currentLedger?.id == tempId) _currentLedger = real;
        notifyListeners();
      }
    } catch (e, st) {
      debugPrint('[LedgerProvider] createNewLedger sync error: $e\n$st');
    }
  }

  Future<void> deleteLedger(String ledgerId) async {
    // 1. 乐观删除本地。
    _ledgers.removeWhere((LedgerBook l) => l.id == ledgerId);
    _expenses.removeWhere((Expense e) => e.ledgerId == ledgerId);
    _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);

    if (_currentLedger?.id == ledgerId) {
      _currentLedger = _ledgers.isNotEmpty ? _ledgers.first : null;
    }
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_books').delete().eq('id', ledgerId);
    } catch (e, st) {
      debugPrint('[LedgerProvider] deleteLedger sync error: $e\n$st');
    }
  }

  // updateLedgerMembers 保留本地操作（members 字段不落库，schema 无此列）。
  void updateLedgerMembers(String ledgerId, List<String> newMembers) {
    final int index = _ledgers.indexWhere((LedgerBook l) => l.id == ledgerId);
    if (index == -1) return;
    final LedgerBook old = _ledgers[index];
    _ledgers[index] = LedgerBook(
      id: old.id,
      title: old.title,
      members: List<String>.from(newMembers),
      createdAt: old.createdAt,
      isSettled: old.isSettled,
    );
    if (_currentLedger?.id == ledgerId) _currentLedger = _ledgers[index];
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────────
  // 计算属性
  // ──────────────────────────────────────────────────────────────

  double get totalSpent =>
      expenses.fold<double>(0, (double s, Expense e) => s + e.amount);

  /// 指定账本的消费总额（用于账本选择列表展示）。
  double totalSpentByLedger(String ledgerId) {
    return _expenses
        .where((Expense e) => e.ledgerId == ledgerId)
        .fold<double>(0, (double s, Expense e) => s + e.amount);
  }

  double get myBalance {
    double balance = 0;
    for (final Expense exp in expenses) {
      if (exp.payer == currentUserDisplayName) balance += exp.amount;
      if (exp.participants.contains(currentUserDisplayName)) {
        balance -= exp.amount / exp.participants.length;
      }
    }
    return balance;
  }

  List<TransferAction> get settlementActions =>
      ExpenseCalculator.calculateSettlement(expenses);

  // ──────────────────────────────────────────────────────────────
  // 行映射辅助方法
  // ──────────────────────────────────────────────────────────────

  LedgerBook _rowToLedger(Map<String, dynamic> r) => LedgerBook(
        id: r['id'] as String,
        title: r['title'] as String,
        members: const <String>['我', 'Leo', 'Mia', 'Tom'],
        createdAt: DateTime.parse(r['created_at'] as String),
        isSettled: (r['is_settled'] as bool?) ?? false,
      );

  Expense _rowToExpense(Map<String, dynamic> r) {
    // participants 可能是 List 或 JSON 字符串，兼容两种格式。
    final dynamic rawParticipants = r['participants'];
    List<String> participants;
    if (rawParticipants is List) {
      participants = rawParticipants.map((dynamic e) => e.toString()).toList();
    } else if (rawParticipants is String) {
      final dynamic decoded = jsonDecode(rawParticipants);
      participants = (decoded as List<dynamic>).map((dynamic e) => e.toString()).toList();
    } else {
      participants = <String>[];
    }

    return Expense(
      id: r['id'] as String,
      ledgerId: r['ledger_id'] as String,
      title: r['title'] as String,
      amount: (r['amount'] as num).toDouble(),
      payer: r['payer'] as String,
      participants: participants,
      date: DateTime.parse(r['created_at'] as String),
      iconStr: '',
    );
  }

  OrderTicket _rowToTicket(Map<String, dynamic> r) => OrderTicket(
        id: r['id'] as String,
        ledgerId: r['ledger_id'] as String,
        type: r['type'] as String,
        title: r['title'] as String,
        dateStr: (r['date_str'] as String?) ?? '',
        timeA: (r['time_a'] as String?) ?? '',
        timeB: (r['time_b'] as String?) ?? '',
        locationA: (r['loc_a'] as String?) ?? '',
        locationB: (r['loc_b'] as String?) ?? '',
        passenger: (r['passenger'] as String?) ?? '',
      );

  Expense _copyExpenseWithLedger(Expense e, String ledgerId) => Expense(
        id: e.id,
        ledgerId: ledgerId,
        title: e.title,
        amount: e.amount,
        payer: e.payer,
        participants: e.participants,
        date: e.date,
        iconStr: e.iconStr,
      );
}