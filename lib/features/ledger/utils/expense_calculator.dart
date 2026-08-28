import '../domain/ledger_model.dart';

/// AA 净额聚合 + 最少笔数转账的贪心债务匹配。
class ExpenseCalculator {
  static const double _eps = 1e-6;

  /// 每人净余额：正为净应收，负为净应付。
  static Map<String, double> computeNetBalances(List<Expense> expenses) {
    final Map<String, double> balances = <String, double>{};
    for (final Expense exp in expenses) {
      if (exp.participants.isEmpty) {
        continue;
      }
      balances[exp.payer] = (balances[exp.payer] ?? 0) + exp.amount;
      final double splitAmount = exp.amount / exp.participants.length;
      for (final String person in exp.participants) {
        balances[person] = (balances[person] ?? 0) - splitAmount;
      }
    }
    return balances;
  }

  /// Minimum-transaction-style 贪心：大额债权优先冲抵大额债务。
  static List<TransferAction> calculateSettlement(List<Expense> expenses) {
    final Map<String, double> balances = computeNetBalances(expenses);

    final List<MapEntry<String, double>> debtors = balances.entries
        .where((MapEntry<String, double> e) => e.value < -_eps)
        .map(
          (MapEntry<String, double> e) =>
              MapEntry<String, double>(e.key, e.value),
        )
        .toList();
    final List<MapEntry<String, double>> creditors = balances.entries
        .where((MapEntry<String, double> e) => e.value > _eps)
        .map(
          (MapEntry<String, double> e) =>
              MapEntry<String, double>(e.key, e.value),
        )
        .toList();

    debtors.sort(
      (MapEntry<String, double> a, MapEntry<String, double> b) =>
          a.value.compareTo(b.value),
    );
    creditors.sort(
      (MapEntry<String, double> a, MapEntry<String, double> b) =>
          b.value.compareTo(a.value),
    );

    final List<TransferAction> actions = <TransferAction>[];
    int i = 0;
    int j = 0;

    while (i < debtors.length && j < creditors.length) {
      final double debt = -debtors[i].value;
      final double credit = creditors[j].value;
      final double settled = debt < credit ? debt : credit;

      if (settled > _eps) {
        actions.add(
          TransferAction(
            from: debtors[i].key,
            to: creditors[j].key,
            amount: settled,
          ),
        );
      }

      debtors[i] = MapEntry<String, double>(
        debtors[i].key,
        debtors[i].value + settled,
      );
      creditors[j] = MapEntry<String, double>(
        creditors[j].key,
        creditors[j].value - settled,
      );

      if (debtors[i].value.abs() < _eps) {
        i++;
      }
      if (creditors[j].value < _eps) {
        j++;
      }
    }
    return actions;
  }
}
