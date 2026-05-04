import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  List<Expense> get expenses => List<Expense>.unmodifiable(_expenses);
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

  // ──────────────────────────────────────────────────────────────
  // 初始化：拉取账本列表（含新用户模板注入）
  // ──────────────────────────────────────────────────────────────
  Future<void> fetchLedgers() async {
    final String? uid = _uid;
    if (uid == null) return;

    try {
      final List<Map<String, dynamic>> rows = await _db
          .from('ledger_books')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);

      if (rows.isEmpty) {
        // 新用户：注入演示模板，完成后重新拉取。
        await _trySeedDemoTemplate(uid);
        return;
      }

      _ledgers
        ..clear()
        ..addAll(rows.map(_rowToLedger));

      // 默认选中第一本账本并拉取其流水。
      if (_currentLedger == null ||
          !_ledgers.any((LedgerBook l) => l.id == _currentLedger!.id)) {
        _currentLedger = _ledgers.first;
      }
      notifyListeners();

      await Future.wait(<Future<void>>[
        fetchExpenses(_currentLedger!.id),
        fetchTickets(_currentLedger!.id),
      ]);
    } catch (e) {
      debugPrint('[LedgerProvider] fetchLedgers error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 新用户演示模板注入
  // ──────────────────────────────────────────────────────────────
  Future<void> _trySeedDemoTemplate(String uid) async {
    try {
      // Step 1：插入演示账本（严格遵循 schema，无 members 字段）。
      final List<Map<String, dynamic>> bookRows = await _db
          .from('ledger_books')
          .insert(<String, dynamic>{
            'user_id': uid,
            'title': '示例 · 北京五日带父母游',
            'is_settled': false,
          })
          .select();

      if (bookRows.isEmpty) return;
      final String demoId = bookRows.first['id'] as String;

      // Step 2：插入 3 条演示消费流水。
      await _db.from('ledger_expenses').insert(<Map<String, dynamic>>[
        <String, dynamic>{
          'ledger_id': demoId,
          'title': '接机专车',
          'amount': 120,
          'payer': 'Leo',
          'participants': <String>['我', 'Leo', 'Mia', 'Tom'],
        },
        <String, dynamic>{
          'ledger_id': demoId,
          'title': '海鲜大排档晚餐',
          'amount': 850,
          'payer': '我',
          'participants': <String>['我', 'Leo', 'Mia', 'Tom'],
        },
        <String, dynamic>{
          'ledger_id': demoId,
          'title': '环岛游艇门票',
          'amount': 600,
          'payer': 'Mia',
          'participants': <String>['我', 'Leo', 'Mia', 'Tom'],
        },
      ]);

      // Step 3：插入 2 条演示票务。
      await _db.from('ledger_tickets').insert(<Map<String, dynamic>>[
        <String, dynamic>{
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

      // 完成后重新拉取，让新用户立即看到模板。
      await fetchLedgers();
    } catch (e) {
      debugPrint('[LedgerProvider] _trySeedDemoTemplate error: $e');
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

      _expenses
        ..removeWhere((Expense e) => e.ledgerId == ledgerId)
        ..insertAll(0, rows.map(_rowToExpense));
      notifyListeners();
    } catch (e) {
      debugPrint('[LedgerProvider] fetchExpenses error: $e');
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
    } catch (e) {
      debugPrint('[LedgerProvider] fetchTickets error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // CRUD：消费流水（乐观更新）
  // ──────────────────────────────────────────────────────────────

  Future<void> addExpense(Expense expense) async {
    final String ledgerId = _currentLedger?.id ?? '';
    final Expense normalized = expense.ledgerId.isEmpty
        ? _copyExpenseWithLedger(expense, ledgerId)
        : expense;

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
        'participants': normalized.participants,
      });
    } catch (e) {
      debugPrint('[LedgerProvider] addExpense sync error: $e');
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
    } catch (e) {
      debugPrint('[LedgerProvider] updateExpense sync error: $e');
    }
  }

  Future<void> deleteExpense(String id) async {
    // 1. 乐观删除本地。
    _expenses.removeWhere((Expense e) => e.id == id);
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_expenses').delete().eq('id', id);
    } catch (e) {
      debugPrint('[LedgerProvider] deleteExpense sync error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // CRUD：票务（乐观更新）
  // ──────────────────────────────────────────────────────────────

  Future<void> addTicket(OrderTicket ticket) async {
    final int sortOrder = currentTickets.length;

    // 1. 乐观更新本地。
    _tickets.insert(0, ticket);
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_tickets').insert(<String, dynamic>{
        'id': ticket.id,
        'ledger_id': ticket.ledgerId,
        'type': ticket.type,
        'title': ticket.title,
        'date_str': ticket.dateStr,
        'time_a': ticket.timeA,
        'time_b': ticket.timeB,
        'loc_a': ticket.locationA,
        'loc_b': ticket.locationB,
        'passenger': ticket.passenger,
        'sort_order': sortOrder,
      });
    } catch (e) {
      debugPrint('[LedgerProvider] addTicket sync error: $e');
    }
  }

  Future<void> updateTicket(String id, OrderTicket updated) async {
    final int index = _tickets.indexWhere((OrderTicket t) => t.id == id);
    if (index == -1) return;

    // 1. 乐观更新本地。
    _tickets[index] = updated;
    notifyListeners();

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
    } catch (e) {
      debugPrint('[LedgerProvider] updateTicket sync error: $e');
    }
  }

  Future<void> deleteTicket(String id) async {
    // 1. 乐观删除本地。
    _tickets.removeWhere((OrderTicket t) => t.id == id);
    notifyListeners();

    // 2. 静默同步云端。
    try {
      await _db.from('ledger_tickets').delete().eq('id', id);
    } catch (e) {
      debugPrint('[LedgerProvider] deleteTicket sync error: $e');
    }
  }

  /// 在当前账本可见列表维度上重排，并异步批量更新 sort_order。
  Future<void> reorderTickets(int oldIndex, int newIndex) async {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) return;

    // 提取当前账本票务子列表。
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
    } catch (e) {
      debugPrint('[LedgerProvider] reorderTickets sync error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 账本管理
  // ──────────────────────────────────────────────────────────────

  Future<void> switchLedger(LedgerBook ledger) async {
    _currentLedger = ledger;
    _expenses.removeWhere((Expense e) => e.ledgerId != ledger.id);
    notifyListeners();
    await Future.wait(<Future<void>>[
      fetchExpenses(ledger.id),
      fetchTickets(ledger.id),
    ]);
  }

  Future<void> createNewLedger(String title, List<String> members) async {
    final String? uid = _uid;
    if (uid == null) return;

    // 1. 乐观创建本地占位账本。
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
    _expenses.clear();
    notifyListeners();

    // 2. 静默同步云端，拿到真实 UUID 后更新本地。
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
        final LedgerBook real = _rowToLedger(rows.first);
        final int idx = _ledgers.indexWhere((LedgerBook l) => l.id == tempId);
        if (idx != -1) _ledgers[idx] = real;
        if (_currentLedger?.id == tempId) _currentLedger = real;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[LedgerProvider] createNewLedger sync error: $e');
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
    } catch (e) {
      debugPrint('[LedgerProvider] deleteLedger sync error: $e');
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
      _expenses.fold<double>(0, (double s, Expense e) => s + e.amount);

  /// 指定账本的消费总额（用于账本选择列表展示）。
  double totalSpentByLedger(String ledgerId) {
    return _expenses
        .where((Expense e) => e.ledgerId == ledgerId)
        .fold<double>(0, (double s, Expense e) => s + e.amount);
  }

  double get myBalance {
    double balance = 0;
    for (final Expense exp in _expenses) {
      if (exp.payer == currentUserDisplayName) balance += exp.amount;
      if (exp.participants.contains(currentUserDisplayName)) {
        balance -= exp.amount / exp.participants.length;
      }
    }
    return balance;
  }

  List<TransferAction> get settlementActions =>
      ExpenseCalculator.calculateSettlement(_expenses);

  // ──────────────────────────────────────────────────────────────
  // 行映射辅助方法
  // ──────────────────────────────────────────────────────────────

  LedgerBook _rowToLedger(Map<String, dynamic> r) => LedgerBook(
        id: r['id'] as String,
        title: r['title'] as String,
        members: const <String>['我', 'Leo', 'Mia', 'Tom'], // 本地默认，schema 无此列
        createdAt: DateTime.parse(r['created_at'] as String),
        isSettled: (r['is_settled'] as bool?) ?? false,
      );

  Expense _rowToExpense(Map<String, dynamic> r) => Expense(
        id: r['id'] as String,
        ledgerId: r['ledger_id'] as String,
        title: r['title'] as String,
        amount: (r['amount'] as num).toDouble(),
        payer: r['payer'] as String,
        participants: List<String>.from(r['participants'] as List<dynamic>),
        date: DateTime.parse(r['created_at'] as String),
        iconStr: '',
      );

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
