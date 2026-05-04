class Expense {
  const Expense({
    required this.id,
    this.ledgerId = '',
    required this.title,
    required this.amount,
    required this.payer,
    required this.participants,
    required this.date,
    this.iconStr = 'taxi',
  });

  final String id;
  final String ledgerId;
  final String title;
  final double amount;
  final String payer;
  final List<String> participants;
  final DateTime date;
  final String iconStr;
}

class TransferAction {
  const TransferAction({
    required this.from,
    required this.to,
    required this.amount,
  });

  final String from;
  final String to;
  final double amount;
}

class ExpenseCalculator {
  // 核心结算算法：金融级防精度丢失化简算法
  static List<TransferAction> calculateSettlement(List<Expense> expenses) {
    // 将所有金额转为“分”计算，避免浮点误差。
    final Map<String, int> balancesCents = <String, int>{};

    for (final Expense exp in expenses) {
      final int totalCents = (exp.amount * 100).round();
      if (exp.participants.isEmpty) continue;

      balancesCents[exp.payer] = (balancesCents[exp.payer] ?? 0) + totalCents;

      final int splitCents = (totalCents / exp.participants.length).round();
      for (final String person in exp.participants) {
        balancesCents[person] = (balancesCents[person] ?? 0) - splitCents;
      }
    }

    // 填平 1-2 分舍入误差，保证总和归零。
    final int sum = balancesCents.values.fold<int>(0, (int a, int b) => a + b);
    if (sum != 0 && balancesCents.isNotEmpty) {
      final String firstKey = balancesCents.keys.first;
      balancesCents[firstKey] = balancesCents[firstKey]! - sum;
    }

    final List<MapEntry<String, int>> debtors = balancesCents.entries
        .where((MapEntry<String, int> e) => e.value < 0)
        .toList();
    final List<MapEntry<String, int>> creditors = balancesCents.entries
        .where((MapEntry<String, int> e) => e.value > 0)
        .toList();

    debtors.sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          a.value.compareTo(b.value),
    );
    creditors.sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value),
    );

    final List<TransferAction> actions = <TransferAction>[];
    int i = 0;
    int j = 0;

    while (i < debtors.length && j < creditors.length) {
      final int debt = -debtors[i].value;
      final int credit = creditors[j].value;

      if (debt == 0) {
        i++;
        continue;
      }
      if (credit == 0) {
        j++;
        continue;
      }

      final int settled = debt < credit ? debt : credit;

      // 防同名“自转账”幽灵单。
      if (settled > 0 && debtors[i].key != creditors[j].key) {
        actions.add(
          TransferAction(
            from: debtors[i].key,
            to: creditors[j].key,
            amount: settled / 100.0,
          ),
        );
      }

      debtors[i] = MapEntry<String, int>(
        debtors[i].key,
        debtors[i].value + settled,
      );
      creditors[j] = MapEntry<String, int>(
        creditors[j].key,
        creditors[j].value - settled,
      );
    }
    return actions;
  }
}
