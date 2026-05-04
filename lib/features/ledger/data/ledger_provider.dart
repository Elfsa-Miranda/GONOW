import 'package:flutter/foundation.dart';

import '../domain/expense_model.dart';
import '../domain/ledger_model.dart' show LedgerBook, OrderTicket;

/// 旅行账本状态：真实流水 + AA 贪心结算。
class LedgerProvider extends ChangeNotifier {
  final List<Expense> _expenses = <Expense>[];
  List<Expense> get expenses => List<Expense>.unmodifiable(_expenses);
  final Map<String, List<Expense>> _expensesByLedgerId =
      <String, List<Expense>>{};

  final List<OrderTicket> _tickets = <OrderTicket>[];

  List<OrderTicket> get currentTickets {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) {
      return List<OrderTicket>.unmodifiable(<OrderTicket>[]);
    }
    return List<OrderTicket>.unmodifiable(
      _tickets.where((OrderTicket t) => t.ledgerId == ledgerId),
    );
  }

  // 兼容旧 UI 字段命名。
  String currentUserDisplayName = '我';
  List<Expense> get currentExpenses => expenses;
  List<String> get currentMembers => _currentLedger?.members ?? <String>['我'];
  int get participantCount => currentMembers.length;

  // 兼容旧顶部账本选择 UI（当前先保留单账本）。
  final List<LedgerBook> _ledgers = <LedgerBook>[
    LedgerBook(
      id: 'ledger_default',
      title: '北京五日带父母游',
      members: <String>['我', 'Leo', 'Mia', 'Tom'],
      createdAt: DateTime(2025, 9, 1),
    ),
  ];
  LedgerBook? _currentLedger;
  List<LedgerBook> get ledgers => List<LedgerBook>.unmodifiable(_ledgers);
  LedgerBook? get currentLedger => _currentLedger;

  LedgerProvider() {
    _currentLedger = _ledgers.first;
    final DateTime now = DateTime.now();
    _expenses.addAll(<Expense>[
      Expense(
        id: 'exp_1',
        ledgerId: _currentLedger!.id,
        title: '接机专车',
        amount: 120,
        payer: 'Leo',
        participants: List<String>.from(_currentLedger!.members),
        date: now.subtract(const Duration(hours: 2)),
        iconStr: 'taxi',
      ),
      Expense(
        id: 'exp_2',
        ledgerId: _currentLedger!.id,
        title: '海鲜大排档晚餐',
        amount: 850,
        payer: '我',
        participants: List<String>.from(_currentLedger!.members),
        date: now.subtract(const Duration(days: 1, hours: 5)),
        iconStr: 'meal',
      ),
      Expense(
        id: 'exp_3',
        ledgerId: _currentLedger!.id,
        title: '环岛游艇门票',
        amount: 600,
        payer: 'Mia',
        participants: List<String>.from(_currentLedger!.members),
        date: now.subtract(const Duration(days: 1, hours: 14)),
        iconStr: 'ticket',
      ),
    ]);
    _expensesByLedgerId[_currentLedger!.id] = List<Expense>.from(_expenses);

    _tickets.addAll(<OrderTicket>[
      OrderTicket(
        id: 'tk_flight_demo',
        ledgerId: _currentLedger!.id,
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
        id: 'tk_hotel_demo',
        ledgerId: _currentLedger!.id,
        type: 'hotel',
        title: '亚特兰蒂斯酒店',
        dateStr: '10月1日',
        timeA: '14:00',
        timeB: '',
        locationA: '海景大床房 · 含双早 · 2 晚 · 1 间',
        locationB: '海南省三亚市海棠湾亚特兰蒂斯度假区',
        passenger: 'Leo',
      ),
    ]);
  }

  void addTicket(OrderTicket ticket) {
    _tickets.insert(0, ticket);
    notifyListeners();
  }

  void updateTicket(String id, OrderTicket updated) {
    final int index = _tickets.indexWhere((OrderTicket t) => t.id == id);
    if (index != -1) {
      _tickets[index] = updated;
      notifyListeners();
    }
  }

  void deleteTicket(String id) {
    _tickets.removeWhere((OrderTicket t) => t.id == id);
    notifyListeners();
  }

  /// 在当前账本可见列表维度上重排（与 [currentTickets] 顺序一致）。
  void reorderTickets(int oldIndex, int newIndex) {
    final String? ledgerId = _currentLedger?.id;
    if (ledgerId == null) {
      return;
    }

    int firstIdx = -1;
    for (int i = 0; i < _tickets.length; i++) {
      if (_tickets[i].ledgerId == ledgerId) {
        firstIdx = i;
        break;
      }
    }
    if (firstIdx == -1) {
      return;
    }

    final List<OrderTicket> ledgerTickets = <OrderTicket>[];
    for (final OrderTicket t in _tickets) {
      if (t.ledgerId == ledgerId) {
        ledgerTickets.add(t);
      }
    }

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    if (oldIndex < 0 || oldIndex >= ledgerTickets.length) {
      return;
    }
    if (newIndex < 0 || newIndex > ledgerTickets.length) {
      return;
    }

    final OrderTicket moved = ledgerTickets.removeAt(oldIndex);
    ledgerTickets.insert(newIndex, moved);

    _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);
    final int insertAt = firstIdx.clamp(0, _tickets.length);
    _tickets.insertAll(insertAt, ledgerTickets);
    notifyListeners();
  }

  double get totalSpent =>
      _expenses.fold<double>(0, (double sum, Expense item) => sum + item.amount);

  double totalSpentByLedger(String ledgerId) {
    final List<Expense> list = _expensesByLedgerId[ledgerId] ?? <Expense>[];
    return list.fold<double>(0, (double sum, Expense item) => sum + item.amount);
  }

  double get myBalance {
    double balance = 0;
    for (final Expense exp in _expenses) {
      if (exp.payer == '我') balance += exp.amount;
      if (exp.participants.contains('我')) {
        balance -= (exp.amount / exp.participants.length);
      }
    }
    return balance;
  }

  // 兼容旧字段命名。
  double get myNetBalance => myBalance;

  void addExpense(Expense expense) {
    final String ledgerId = _currentLedger?.id ?? 'default_ledger';
    final Expense normalized = Expense(
      id: expense.id,
      ledgerId: expense.ledgerId.isEmpty ? ledgerId : expense.ledgerId,
      title: expense.title,
      amount: expense.amount,
      payer: expense.payer,
      participants: expense.participants,
      date: expense.date,
      iconStr: expense.iconStr,
    );
    _expenses.insert(0, normalized);
    _expensesByLedgerId[ledgerId] = List<Expense>.from(_expenses);
    notifyListeners();
  }

  // 更新账单
  void updateExpense(String id, Expense updatedExpense) {
    final int index = _expenses.indexWhere((Expense e) => e.id == id);
    if (index != -1) {
      final String ledgerId = _currentLedger?.id ?? 'default_ledger';
      _expenses[index] = Expense(
        id: updatedExpense.id,
        ledgerId: updatedExpense.ledgerId.isEmpty ? ledgerId : updatedExpense.ledgerId,
        title: updatedExpense.title,
        amount: updatedExpense.amount,
        payer: updatedExpense.payer,
        participants: updatedExpense.participants,
        date: updatedExpense.date,
        iconStr: updatedExpense.iconStr,
      );
      _expensesByLedgerId[ledgerId] = List<Expense>.from(_expenses);
      notifyListeners();
    }
  }

  // 删除账单
  void deleteExpense(String id) {
    _expenses.removeWhere((Expense e) => e.id == id);
    final String ledgerId = _currentLedger?.id ?? 'default_ledger';
    _expensesByLedgerId[ledgerId] = List<Expense>.from(_expenses);
    notifyListeners();
  }

  List<TransferAction> get settlementActions =>
      ExpenseCalculator.calculateSettlement(_expenses);

  // 切换账本
  void switchLedger(LedgerBook ledger) {
    _currentLedger = ledger;
    _expenses.clear();
    _expenses.addAll(_expensesByLedgerId[ledger.id] ?? <Expense>[]);
    notifyListeners();
  }

  // 新建空白账本
  void createNewLedger(String title, List<String> members) {
    final LedgerBook newLedger = LedgerBook(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      members: List<String>.from(members),
      createdAt: DateTime.now(),
      isSettled: false,
    );

    _ledgers.insert(0, newLedger);
    _currentLedger = newLedger;
    _expenses.clear();
    _expensesByLedgerId[newLedger.id] = <Expense>[];

    notifyListeners();
  }

  void updateLedgerMembers(String ledgerId, List<String> newMembers) {
    final int index = _ledgers.indexWhere((LedgerBook l) => l.id == ledgerId);
    if (index != -1) {
      final LedgerBook old = _ledgers[index];
      _ledgers[index] = LedgerBook(
        id: old.id,
        title: old.title,
        members: List<String>.from(newMembers),
        createdAt: old.createdAt,
        isSettled: old.isSettled,
      );
      if (_currentLedger?.id == ledgerId) {
        _currentLedger = _ledgers[index];
      }
      notifyListeners();
    }
  }

  void deleteLedger(String ledgerId) {
    _ledgers.removeWhere((LedgerBook l) => l.id == ledgerId);
    _expenses.removeWhere((Expense e) => e.ledgerId == ledgerId);
    _expensesByLedgerId.remove(ledgerId);
    _tickets.removeWhere((OrderTicket t) => t.ledgerId == ledgerId);

    if (_currentLedger?.id == ledgerId) {
      _currentLedger = _ledgers.isNotEmpty ? _ledgers.first : null;
      _expenses.clear();
      if (_currentLedger != null) {
        _expenses.addAll(_expensesByLedgerId[_currentLedger!.id] ?? <Expense>[]);
      }
    }
    notifyListeners();
  }
}
