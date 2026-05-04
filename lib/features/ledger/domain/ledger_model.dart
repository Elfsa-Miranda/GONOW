// 旅行账本领域模型：LedgerBook、Expense、TransferAction。

/// 顶层账本：对应一次旅行归档。
class LedgerBook {
  const LedgerBook({
    required this.id,
    required this.title,
    required this.members,
    required this.createdAt,
    this.isSettled = false,
  });

  final String id;
  final String title;
  final List<String> members;
  final DateTime createdAt;
  final bool isSettled;
}

/// AA 单笔流水：垫付人 + 参与平摊成员（须包含垫付人）。
class Expense {
  const Expense({
    required this.id,
    required this.ledgerId,
    required this.title,
    required this.amount,
    required this.payer,
    required this.participants,
    required this.date,
  });

  final String id;
  final String ledgerId;
  final String title;
  final double amount;
  /// 垫付人显示名（与 [participants] 中某项一致）。
  final String payer;
  final List<String> participants;
  final DateTime date;
}

/// 贪心化简后的单笔转账建议。
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
