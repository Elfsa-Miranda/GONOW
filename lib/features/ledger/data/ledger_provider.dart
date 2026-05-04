import 'package:flutter/foundation.dart';

import '../domain/ledger_model.dart';
import '../utils/expense_calculator.dart';

/// 旅行账本状态（当前为内存种子数据，后续可接 Supabase）。
class LedgerProvider extends ChangeNotifier {
  LedgerBook? _currentLedger;
  List<LedgerBook> _ledgers = <LedgerBook>[];
  final Map<String, List<Expense>> _expensesByLedgerId =
      <String, List<Expense>>{};
  List<Expense> _expenses = <Expense>[];

  /// 当前用户在 AA 卡片中的显示名（净结余按此名统计）。
  String currentUserDisplayName = '我';

  LedgerBook? get currentLedger => _currentLedger;
  List<LedgerBook> get ledgers => List<LedgerBook>.unmodifiable(_ledgers);
  List<Expense> get currentExpenses => List<Expense>.unmodifiable(_expenses);

  List<TransferAction> get settlementActions =>
      ExpenseCalculator.calculateSettlement(_expenses);

  double get totalSpent =>
      _expenses.fold<double>(0, (double sum, Expense e) => sum + e.amount);

  /// 当前用户净余额（正应收、负应付）。
  double get myNetBalance {
    final Map<String, double> m =
        ExpenseCalculator.computeNetBalances(_expenses);
    return m[currentUserDisplayName] ?? 0;
  }

  /// 当前账本下去重后的参与人数。
  int get participantCount {
    final Set<String> names = <String>{};
    for (final Expense e in _expenses) {
      names.addAll(e.participants);
    }
    return names.length;
  }

  LedgerProvider() {
    _seedDemoData();
  }

  void _seedDemoData() {
    final LedgerBook beijing = LedgerBook(
      id: 'ledger_beijing_5d',
      title: '北京五日带父母游',
      createdAt: DateTime(2025, 9, 1),
    );
    final LedgerBook weizhou = LedgerBook(
      id: 'ledger_weizhou',
      title: '十一涠洲岛闺蜜行',
      createdAt: DateTime(2025, 8, 15),
      isSettled: true,
    );
    _ledgers = <LedgerBook>[beijing, weizhou];
    _currentLedger = beijing;

    final DateTime now = DateTime.now();
    _expensesByLedgerId[beijing.id] = <Expense>[
      Expense(
        id: 'exp_1',
        ledgerId: beijing.id,
        title: '接机专车',
        amount: 120,
        payer: 'Leo',
        participants: <String>['Leo', '我', 'Mia', 'Tom'],
        date: now.subtract(const Duration(hours: 2)),
      ),
      Expense(
        id: 'exp_2',
        ledgerId: beijing.id,
        title: '海鲜大排档晚餐',
        amount: 850,
        payer: '我',
        participants: <String>['Leo', '我', 'Mia', 'Tom'],
        date: now.subtract(const Duration(days: 1, hours: 5)),
      ),
      Expense(
        id: 'exp_3',
        ledgerId: beijing.id,
        title: '环岛游艇门票',
        amount: 600,
        payer: 'Mia',
        participants: <String>['Leo', '我', 'Mia', 'Tom'],
        date: now.subtract(const Duration(days: 1, hours: 14)),
      ),
    ];
    _expensesByLedgerId[weizhou.id] = <Expense>[
      Expense(
        id: 'exp_w1',
        ledgerId: weizhou.id,
        title: '船票',
        amount: 400,
        payer: 'Mia',
        participants: <String>['Mia', '我'],
        date: DateTime(2025, 8, 10),
      ),
    ];
    _expenses = List<Expense>.from(_expensesByLedgerId[beijing.id]!);
  }

  void switchLedger(LedgerBook ledger) {
    _currentLedger = ledger;
    _expenses = List<Expense>.from(
      _expensesByLedgerId[ledger.id] ?? <Expense>[],
    );
    notifyListeners();
  }

  // TODO(Supabase): 按 ledger.id 拉取 / 同步 expenses。
}
