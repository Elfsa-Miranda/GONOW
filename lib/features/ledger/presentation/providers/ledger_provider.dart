import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../domain/expense_model.dart';
import '../../domain/ledger_model.dart' show LedgerBook, OrderTicket;

/// 旅行账本状态：Supabase 云端持久化 + 乐观更新。
///
/// 修复清单：
///  BUG-1  catch 全部改为 catch(e,st) 打印完整 stacktrace
///  BUG-2  participants 统一 jsonEncode 写入，jsonDecode 读取
///  BUG-3  加入 _isSeeding 锁，防止并发重复注入模板
///  BUG-4  seed 完成后直接本地构建，不依赖二次网络查询时序
///  BUG-5/6 写入数据库的 id 统一用 UUID v4（告别毫秒时间戳）
///  BUG-10 expenses/totalSpent/myBalance/settlement 均按当前账本过滤
///  BUG-11 switchLedger 移除反向的 removeWhere 逻辑
class LedgerProvider extends ChangeNotifier {
  // ─── 私有状态 ───────────────────────────────────────────────
  final List<Expense> _expenses = <Expense>[];
  final List<OrderTicket> _tickets = <OrderTicket>[];
  final List<LedgerBook> _ledgers = <LedgerBook>[];
  LedgerBook? _currentLedger;

  /// BUG-3 FIX：防止并发重复触发模板注入。
  bool _isSeeding = false;

  static const Uuid _uuid = Uuid();

  // ─── 公开 Getters ───────────────────────────────────────────

  /// BUG-10 FIX：只返回当前账本的流水，不混入其他账本数据。
  List<Expense> get expenses {
    final String? lid = _currentLedger?.id;
    if (lid == null) return const <Expense>[];
    return List<Expense>.unmodifiable(
      _expenses.where((Expense e) => e.ledgerId == lid),
    );
  }

  List<LedgerBook> get ledgers => List<LedgerBook>.unmodifiable(_ledgers);
  LedgerBook? get currentLedger => _currentLedger;

  List<OrderTicket> get currentTickets {
    final String? lid = _currentLedger?.id;
    if (lid == null) return const <OrderTicket>[];
    return List<OrderTicket>.unmodifiable(
      _tickets.where((OrderTicket t) => t.ledgerId == lid),
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

  // ──────────────────────────────────────────────────────────────
  // 初始化：拉取账本列表（含新用户模板注入）
  // ──────────────────────────────────────────────────────────────
  Future<void> fetchLedgers() async {
    final String? uid = _uid;
    if (uid == null) {
      debugPrint('[LedgerProvider] fetchLedgers: 用户未登录，跳过');
      return;
    }

    try {
      final List<Map<String, dynamic>> rows = await _db
          .from('ledger_books')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);

      if (rows.isEmpty) {
        // BUG-3 FIX：检查锁，防止并发重复注入。
        if (_isSeeding) {
          debugPrint('[LedgerProvider] 模板注入正在进行中，跳过重复触发');
          return;
        }
        debugPrint('[LedgerProvider] 新用户，开始注入演示模板...');
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
  // BUG-3 FIX: _isSeeding 锁
  // BUG-4 FIX: 写入成功后直接本地构建，不依赖二次网络拉取时序
  // ──────────────────────────────────────────────────────────────
  Future<void> _trySeedDemoTemplate(String uid) async {
    _isSeeding = true;
    try {
      // Step 1：插入演示账本。
      final List<Map<String, dynamic>> bookRows = await _db
          .from('ledger_books')
          .insert(<String, dynamic>{
            'user_id': uid,
            'title': '示例 · 北京五日带父母游',
            'is_settled': false,
          })
          .select();

      if (bookRows.isEmpty) {
        debugPrint('[LedgerProvider] seed Step1: insert ledger_books 返回空，中止');
        return;
      }
      final String demoId = bookRows.first['id'] as String;
      debugPrint('[LedgerProvider] seed Step1 OK, demoId=$demoId');

      // Step 2：插入 3 条演示消费流水。
      // BUG-2 FIX: participants 使用 jsonEncode 确保兼容所有 SDK 版本的 JSONB 写入。
      // BUG-5 FIX: id 统一使用 UUID v4。
      final List<String> defaultMembers = <String>['我', 'Leo', 'Mia', 'Tom'];
      final String participantsJson = jsonEncode(defaultMembers);
      final String expId1 = _uuid.v4();
      final String expId2 = _uuid.v4();
      final String expId3 = _uuid.v4();

      await _db.from('ledger_expenses').insert(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': expId1,
          'ledger_id': demoId,
          'title': '接机专车',
          'amount': 120,
          'payer': 'Leo',
          'participants': participantsJson,
        },
        <String, dynamic>{
          'id': expId2,
          'ledger_id': demoId,
          'title': '海鲜大排档晚餐',
          'amount': 850,
          'payer': '我',
          'participants': participantsJson,
        },
        <String, dynamic>{
          'id': expId3,
          'ledger_id': demoId,
          'title': '环岛游艇门票',
          'amount': 600,
          'payer': 'Mia',
          'participants': participantsJson,
        },
      ]);
      debugPrint('[LedgerProvider] seed Step2 OK');

      // Step 3：插入 2 条演示票务。
      final String tkId1 = _uuid.v4();
      final String tkId2 = _uuid.v4();

      await _db.from('ledger_tickets').insert(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': tkId1,
          'ledger_id': demoId,
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
          'id': tkId2,
          'ledger_id': demoId,
          'type': 'hotel',
          'title': '亚特兰蒂斯酒店',
          'date_str': '10月1日',
          'time_a': '14:00',
          'time_b': '',
          'loc_a': '海景大床房 · 含双早 · 2 晚 · 1 间',
          'loc_b': '海南省三亚市海棠湾亚特兰蒂斯度假区',
          'passenger': 'Leo',
          'sort_order': 1,
        },
      ]);
      debugPrint('[LedgerProvider] seed Step3 OK');

      // Step 4：BUG-4 FIX：直接本地构建，UI 即刻响应，不等二次网络。
      final DateTime now = DateTime.now();
      final LedgerBook demoBook = LedgerBook(
        id: demoId,
        title: '示例 · 北京五日带父母游',
        members: defaultMembers,
        createdAt: now,
        isSettled: false,
      );
      final List<Expense> demoExpenses = <Expense>[
        Expense(
          id: expId1,
          ledgerId: demoId,
          title: '接机专车',
          amount: 120,
          payer: 'Leo',
          participants: defaultMembers,
          date: now,
          iconStr: 'taxi',
        ),
        Expense(
          id: expId2,
          ledgerId: demoId,
          title: '海鲜大排档晚餐',
          amount: 850,
          payer: '我',
          participants: defaultMembers,
          date: now,
          iconStr: 'meal',
        ),
        Expense(
          id: expId3,
          ledgerId: demoId,
          title: '环岛游艇门票',
          amount: 600,
          payer: 'Mia',
          participants: defaultMembers,
          date: now,
          iconStr: 'ticket',
        ),
      ];
      final List<OrderTicket> demoTickets = <OrderTicket>[
        OrderTicket(
          id: tkId1,
          ledgerId: demoId,
          type: 'flight',
          title: 'CA1356',
          dateStr: '10月1日 · 去程',
          timeA: '10:30',
          timeB: '13:55',
          locationA: '北京 PEK',
          locationB: '三亚 SYX',
          passenger: 'Leo',
        ),
        OrderTicket(
          id: tkId2,
          ledgerId: demoId,
          type: 'hotel',
          title: '亚特兰蒂斯酒店',
          dateStr: '10月1日',
          timeA: '14:00',
          timeB: '',
          locationA: '海景大床房 · 含双早 · 2 晚 · 1 间',
          locationB: '海南省三亚市海棠湾亚特兰蒂斯度假区',
          passenger: 'Leo',
        ),
      ];

      _ledgers
        ..clear()
        ..add(demoBook);
      _currentLedger = demoBook;
      _expenses.addAll(demoExpenses);
      _tickets.addAll(demoTickets);
      notifyListeners();
      debugPrint('[LedgerProvider] 演示模板注入完成，UI 已更新');
    } catch (e, st) {
      // BUG-1 FIX：打印完整 stacktrace，便于定位 RLS/类型不匹配等真实原因。
      debugPrint('[LedgerProvider] _trySeedDemoTemplate error: $e\n$st');
    } finally {
      _isSeeding = false;
    }
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

  Future<void> addExpense(Expense expense) async {
    final String ledgerId = _currentLedger?.id ?? '';
    // BUG-5 FIX：Screen 传来的 id 是毫秒时间戳字符串，不是合法 UUID。
    // PostgreSQL UUID 列会抛 "invalid input syntax for type uuid"，被 catch 吞掉。
    final String safeId = _isValidUuid(expense.id) ? expense.id : _uuid.v4();
    final Expense normalized = Expense(
      id: safeId,
      ledgerId: expense.ledgerId.isEmpty ? ledgerId : expense.ledgerId,
      title: expense.title,
      amount: expense.amount,
      payer: expense.payer,
      participants: expense.participants,
      date: expense.date,
      iconStr: expense.iconStr,
    );

    // 1. 乐观更新本地。
    _expenses.insert(0, normalized);
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_expenses').insert(<String, dynamic>{
        'id': normalized.id,
        'ledger_id': normalized.ledgerId,
        'title': normalized.title,
        'amount': normalized.amount,
        'payer': normalized.payer,
        // BUG-2 FIX：jsonEncode 确保 JSONB 列收到合法 JSON 数组。
        'participants': jsonEncode(normalized.participants),
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

    _expenses[index] = normalized;
    notifyListeners();

    try {
      await _db.from('ledger_expenses').update(<String, dynamic>{
        'title': normalized.title,
        'amount': normalized.amount,
        'payer': normalized.payer,
        'participants': jsonEncode(normalized.participants),
      }).eq('id', id);
    } catch (e, st) {
      debugPrint('[LedgerProvider] updateExpense sync error: $e\n$st');
    }
  }

  Future<void> deleteExpense(String id) async {
    _expenses.removeWhere((Expense e) => e.id == id);
    notifyListeners();

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
    // BUG-6 FIX：同 BUG-5，id 统一换为 UUID v4。
    final String safeId = _isValidUuid(ticket.id) ? ticket.id : _uuid.v4();
    final OrderTicket normalized = OrderTicket(
      id: safeId,
      ledgerId: ticket.ledgerId,
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

    _tickets[index] = updated;
    notifyListeners();

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
    _tickets.removeWhere((OrderTicket t) => t.id == id);
    notifyListeners();

    try {
      await _db.from('ledger_tickets').delete().eq('id', id);
    } catch (e, st) {
      debugPrint('[LedgerProvider] deleteTicket sync error: $e\n$st');
    }
  }

  Future<void> reorderTickets(int oldIndex, int newIndex) async {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) return;

    final List<OrderTicket> ledgerTickets = _tickets
        .where((OrderTicket t) => t.ledgerId == ledgerId)
        .toList();

    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= ledgerTickets.length) return;
    if (newIndex < 0 || newIndex > ledgerTickets.length) return;

    final OrderTicket moved = ledgerTickets.removeAt(oldIndex);
    ledgerTickets.insert(newIndex, moved);

    int firstIdx = _tickets.indexWhere((OrderTicket t) => t.ledgerId == ledgerId);
    if (firstIdx == -1) firstIdx = _tickets.length;
    _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);
    _tickets.insertAll(firstIdx.clamp(0, _tickets.length), ledgerTickets);
    notifyListeners();

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
    // BUG-11 FIX：移除原来的 removeWhere 反向逻辑，保留其他账本缓存。
    notifyListeners();
    await Future.wait(<Future<void>>[
      fetchExpenses(ledger.id),
      fetchTickets(ledger.id),
    ]);
  }

  Future<void> createNewLedger(String title, List<String> members) async {
    final String? uid = _uid;
    if (uid == null) return;

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
    _ledgers.removeWhere((LedgerBook l) => l.id == ledgerId);
    _expenses.removeWhere((Expense e) => e.ledgerId == ledgerId);
    _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);

    if (_currentLedger?.id == ledgerId) {
      _currentLedger = _ledgers.isNotEmpty ? _ledgers.first : null;
    }
    notifyListeners();

    try {
      await _db.from('ledger_books').delete().eq('id', ledgerId);
    } catch (e, st) {
      debugPrint('[LedgerProvider] deleteLedger sync error: $e\n$st');
    }
  }

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
  // 计算属性（均按当前账本过滤）
  // ──────────────────────────────────────────────────────────────

  double get totalSpent {
    final String? lid = _currentLedger?.id;
    if (lid == null) return 0;
    return _expenses
        .where((Expense e) => e.ledgerId == lid)
        .fold<double>(0, (double s, Expense e) => s + e.amount);
  }

  double totalSpentByLedger(String ledgerId) {
    return _expenses
        .where((Expense e) => e.ledgerId == ledgerId)
        .fold<double>(0, (double s, Expense e) => s + e.amount);
  }

  double get myBalance {
    final String? lid = _currentLedger?.id;
    if (lid == null) return 0;
    double balance = 0;
    for (final Expense exp
        in _expenses.where((Expense e) => e.ledgerId == lid)) {
      if (exp.payer == currentUserDisplayName) balance += exp.amount;
      if (exp.participants.contains(currentUserDisplayName)) {
        balance -= exp.amount / exp.participants.length;
      }
    }
    return balance;
  }

  List<TransferAction> get settlementActions {
    final String? lid = _currentLedger?.id;
    if (lid == null) return <TransferAction>[];
    return ExpenseCalculator.calculateSettlement(
      _expenses.where((Expense e) => e.ledgerId == lid).toList(),
    );
  }

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
    // BUG-2 FIX：兼容数据库中 participants 为 List 或 JSON 字符串两种格式。
    final dynamic raw = r['participants'];
    final List<String> participants;
    if (raw is List) {
      participants = raw.map((dynamic e) => e.toString()).toList();
    } else if (raw is String) {
      participants = (jsonDecode(raw) as List<dynamic>)
          .map((dynamic e) => e.toString())
          .toList();
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

  /// 判断字符串是否为合法 UUID v4 格式。
  static bool _isValidUuid(String s) {
    return RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(s);
  }
}