import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gonow/features/ledger/data/ledger_provider.dart';
import 'package:gonow/features/ledger/domain/expense_model.dart';
import 'package:gonow/features/ledger/domain/ledger_model.dart' show LedgerBook;
import 'package:provider/provider.dart';

/// 旅行账本：双轨（结伴 AA / 机酒票务）+ 票根凹槽与圆角阴影 UI。
class LedgerScreen extends StatefulWidget {
  const LedgerScreen({super.key});

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  int _currentTab = 0;
  static const Color _bgColor = Color(0xFFF5F7FA);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black87, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Consumer<LedgerProvider>(
          builder: (BuildContext context, LedgerProvider p, _) {
            final LedgerBook? book = p.currentLedger;
            return GestureDetector(
              onTap: () => _showLedgerSelectorSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: (book?.isSettled ?? false)
                            ? Colors.grey
                            : Colors.greenAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        book?.title ?? '旅行账本',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down, size: 14, color: Colors.grey),
                  ],
                ),
              ),
            );
          },
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.filter_alt_outlined, color: Colors.black54),
            onPressed: () {},
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _currentTab = 0),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _currentTab == 0 ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: _currentTab == 0
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 4,
                                  ),
                                ]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '结伴 AA',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                _currentTab == 0 ? FontWeight.bold : FontWeight.w600,
                            color: _currentTab == 0
                                ? Colors.black87
                                : Colors.grey.shade500,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _currentTab = 1),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _currentTab == 1 ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: _currentTab == 1
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 4,
                                  ),
                                ]
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '机酒与票务',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                _currentTab == 1 ? FontWeight.bold : FontWeight.w600,
                            color: _currentTab == 1
                                ? Colors.black87
                                : Colors.grey.shade500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _currentTab == 0
          ? Consumer<LedgerProvider>(
              builder: (BuildContext context, LedgerProvider provider, _) {
                return _buildAASplitView(context, provider);
              },
            )
          : _buildTicketsView(),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_currentTab == 0) {
            _showAddExpenseSheet(context);
          }
        },
        backgroundColor: Colors.black87,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildAASplitView(BuildContext context, LedgerProvider p) {
    final List<Expense> items = p.expenses;
    final double total = p.totalSpent;
    final double myNet = p.myNetBalance;
    final int nPeople = p.participantCount;
    final bool receivable = myNet >= -1e-6;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFFF97316), Color(0xFFEC4899)],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.orange.withValues(alpha: 0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  const Text(
                    '本次旅行总支出',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      if (p.currentLedger == null) {
                        return;
                      }
                      final TextEditingController editMembersController =
                          TextEditingController(
                        text: p.currentMembers.join(', '),
                      );
                      showDialog<void>(
                        context: context,
                        builder: (BuildContext ctx) => AlertDialog(
                          title: const Text(
                            '编辑同行人',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              TextField(
                                controller: editMembersController,
                                autofocus: true,
                                decoration: InputDecoration(
                                  hintText: '用逗号或空格隔开',
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '修改后将应用于后续新增的账单，不影响历史记录',
                                style: TextStyle(fontSize: 10, color: Colors.grey),
                              ),
                            ],
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('取消'),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                              ),
                              onPressed: () {
                                if (editMembersController.text.trim().isEmpty) {
                                  return;
                                }
                                List<String> updatedMembers = editMembersController
                                    .text
                                    .split(RegExp(r'[,，\s]+'))
                                    .map((String e) => e.trim())
                                    .where((String e) => e.isNotEmpty)
                                    .toList();

                                if (!updatedMembers.contains('我')) {
                                  updatedMembers.insert(0, '我');
                                }
                                updatedMembers = updatedMembers.toSet().toList();

                                p.updateLedgerMembers(p.currentLedger!.id, updatedMembers);
                                Navigator.pop(ctx);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('同行人已更新')),
                                  );
                                }
                              },
                              child: const Text(
                                '保存',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.people, color: Colors.white, size: 12),
                          const SizedBox(width: 4),
                          Text(
                            '$nPeople人',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '¥ ${total.toStringAsFixed(2)}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '我的净结余',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: <Widget>[
                          Text(
                            '${myNet >= 0 ? '+' : '-'} ¥${myNet.abs().toStringAsFixed(2)}',
                            style: TextStyle(
                              color: receivable ? Colors.greenAccent : Colors.orange.shade100,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: (receivable ? Colors.greenAccent : Colors.orange.shade100)
                                  .withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              receivable ? '应收' : '应付',
                              style: TextStyle(
                                color: receivable ? Colors.greenAccent : Colors.orange.shade100,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: () => _showSettlementSheet(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.orange.shade600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      '💰 一键结算',
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '账单流水 (${items.length})',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: Colors.grey.shade400,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        ...items.map((Expense exp) {
          return Dismissible(
            key: ValueKey<String>(exp.id),
            direction: DismissDirection.endToStart,
            background: Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.shade400,
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              child: const Icon(Icons.delete_outline, color: Colors.white),
            ),
            confirmDismiss: (DismissDirection direction) async {
              final bool? confirmed = await showDialog<bool>(
                context: context,
                builder: (BuildContext ctx) => AlertDialog(
                  title: const Text(
                    '删除账单',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  content: const Text('确定要删除这笔账单吗？'),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        '删除',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
              return confirmed ?? false;
            },
            onDismissed: (_) {
              p.deleteExpense(exp.id);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已删除该笔账单')),
              );
            },
            child: InkWell(
              onTap: () => _showAddExpenseSheet(context, existingExpense: exp),
              borderRadius: BorderRadius.circular(20),
              child: _buildExpenseTile(exp),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildExpenseTile(Expense e) {
    final (IconData icon, MaterialColor color) = _iconAndColorForTitle(e.title);
    final LedgerProvider p = context.read<LedgerProvider>();
    final String payerLine = _payerLine(e, p.currentUserDisplayName);
    final bool isMe = e.payer == p.currentUserDisplayName;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color.shade500, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  e.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatExpenseDate(e.date)} · 平摊',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '¥${e.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                payerLine,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                  color: isMe ? Colors.indigo : Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  (IconData, MaterialColor) _iconAndColorForTitle(String title) {
    if (title.contains('车') || title.contains('专') || title.contains('机')) {
      return (Icons.local_taxi, Colors.blue);
    }
    if (title.contains('餐') || title.contains('排') || title.contains('饭') || title.contains('鲜')) {
      return (Icons.restaurant, Colors.orange);
    }
    if (title.contains('票') || title.contains('艇') || title.contains('船')) {
      return (Icons.confirmation_num, Colors.purple);
    }
    return (Icons.receipt_long, Colors.teal);
  }

  String _payerLine(Expense e, String me) {
    if (e.payer == me) {
      return '我垫付';
    }
    return '${e.payer} 垫付';
  }

  String _formatExpenseDate(DateTime d) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime day = DateTime(d.year, d.month, d.day);
    final String hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == today) {
      return '今天 $hm';
    }
    if (day == today.subtract(const Duration(days: 1))) {
      return '昨天 $hm';
    }
    return '${d.month}月${d.day}日 $hm';
  }

  void _showAddExpenseSheet(BuildContext context, {Expense? existingExpense}) {
    final LedgerProvider provider = Provider.of<LedgerProvider>(
      context,
      listen: false,
    );
    final TextEditingController amountController = TextEditingController(
      text: existingExpense?.amount.toString() ?? '',
    );
    final TextEditingController titleController = TextEditingController(
      text: existingExpense?.title ?? '',
    );
    String selectedPayer = existingExpense?.payer ?? '我';
    List<String> selectedParticipants = existingExpense != null
        ? List<String>.from(existingExpense.participants)
        : List<String>.from(provider.currentMembers);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '记一笔',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: <Widget>[
                        Expanded(
                          flex: 1,
                          child: TextField(
                            controller: amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              prefixText: '¥ ',
                              hintText: '0.00',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: titleController,
                            decoration: InputDecoration(
                              hintText: '名目 (如: 海鲜大排档)',
                              filled: true,
                              fillColor: Colors.grey.shade50,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '谁垫付的？',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: provider.currentMembers.map((String m) {
                        return ChoiceChip(
                          label: Text(m),
                          selected: selectedPayer == m,
                          onSelected: (bool _) =>
                              setModalState(() => selectedPayer = m),
                          selectedColor: Colors.orange.shade100,
                          labelStyle: TextStyle(
                            color: selectedPayer == m
                                ? Colors.orange.shade800
                                : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '谁参与平摊？',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: provider.currentMembers.map((String m) {
                        return FilterChip(
                          label: Text(m),
                          selected: selectedParticipants.contains(m),
                          onSelected: (bool val) {
                            setModalState(() {
                              if (val) {
                                selectedParticipants.add(m);
                              } else if (selectedParticipants.length > 1) {
                                selectedParticipants.remove(m);
                              }
                            });
                          },
                          selectedColor: Colors.indigo.shade100,
                          checkmarkColor: Colors.indigo.shade700,
                          labelStyle: TextStyle(
                            color: selectedParticipants.contains(m)
                                ? Colors.indigo.shade700
                                : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black87,
                        minimumSize: const Size(double.infinity, 56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () {
                        if (amountController.text.isEmpty ||
                            titleController.text.isEmpty) {
                          return;
                        }
                        final double amount =
                            double.tryParse(amountController.text) ?? 0;
                        if (amount <= 0 || selectedParticipants.isEmpty) return;

                        final Expense newExp = Expense(
                          id: existingExpense?.id ??
                              DateTime.now().millisecondsSinceEpoch.toString(),
                          ledgerId: provider.currentLedger?.id ?? 'default_ledger',
                          title: titleController.text,
                          amount: amount,
                          payer: selectedPayer,
                          participants: selectedParticipants,
                          date: existingExpense?.date ?? DateTime.now(),
                        );

                        if (existingExpense != null) {
                          provider.updateExpense(newExp.id, newExp);
                        } else {
                          provider.addExpense(newExp);
                        }
                        Navigator.pop(context);
                      },
                      child: const Text(
                        '确定',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLedgerItem({
    required String title,
    required String amount,
    required String dateLine,
    required bool isActive,
    required bool isSettled,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  dateLine,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '总支出 ¥$amount',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.indigo.shade500,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isSettled)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '已结算',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
              if (isActive)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.indigo.shade400,
                    size: 22,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _showLedgerSelectorSheet(BuildContext screenContext) {
    final LedgerProvider provider = screenContext.read<LedgerProvider>();
    showModalBottomSheet<void>(
      context: screenContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        final double bottom = MediaQuery.paddingOf(sheetContext).bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: <BoxShadow>[
                BoxShadow(color: Color(0x22000000), blurRadius: 24, offset: Offset(0, -4)),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(height: 10),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.folder_open_rounded, color: Colors.indigo.shade400),
                        const SizedBox(width: 8),
                        const Text(
                          '历史账本',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      itemCount: provider.ledgers.length,
                      separatorBuilder: (BuildContext context, int index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (BuildContext _, int i) {
                        final LedgerBook b = provider.ledgers[i];
                        final bool isCurrent = provider.currentLedger?.id == b.id;
                        final String dateLine =
                            '${b.createdAt.year}-${b.createdAt.month.toString().padLeft(2, '0')}-${b.createdAt.day.toString().padLeft(2, '0')}'
                            '${b.isSettled ? ' · 已归档' : ''}';
                        return Material(
                          color: isCurrent ? Colors.indigo.shade50 : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              provider.switchLedger(b);
                              Navigator.pop(sheetContext);
                            },
                            onLongPress: () async {
                              final bool? confirm = await showDialog<bool>(
                                context: sheetContext,
                                builder: (BuildContext ctx) => AlertDialog(
                                  title: const Text(
                                    '删除旅行账本',
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                  content: Text(
                                    '确定要永久删除《${b.title}》及其所有的流水记录吗？此操作无法恢复。',
                                  ),
                                  actions: <Widget>[
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text(
                                        '彻底删除',
                                        style: TextStyle(
                                          color: Colors.red,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              if (confirm == true) {
                                provider.deleteLedger(b.id);
                                if (screenContext.mounted) {
                                  ScaffoldMessenger.of(screenContext).showSnackBar(
                                    const SnackBar(content: Text('账本已删除')),
                                  );
                                }
                              }
                            },
                            child: _buildLedgerItem(
                              title: b.title,
                              amount: provider.totalSpentByLedger(b.id).toStringAsFixed(2),
                              dateLine: dateLine,
                              isActive: isCurrent,
                              isSettled: b.isSettled,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final TextEditingController nameController =
                            TextEditingController();
                        final TextEditingController membersController =
                            TextEditingController(text: '我, ');
                        showDialog<void>(
                          context: sheetContext,
                          builder: (BuildContext ctx) => AlertDialog(
                            title: const Text(
                              '新建旅行账本',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                TextField(
                                  controller: nameController,
                                  autofocus: true,
                                  decoration: InputDecoration(
                                    hintText: '账本名称 (如：五一川西自驾)',
                                    hintStyle: TextStyle(
                                      color: Colors.grey.shade400,
                                      fontSize: 14,
                                    ),
                                    filled: true,
                                    fillColor: Colors.grey.shade50,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: membersController,
                                  decoration: InputDecoration(
                                    hintText: '出行人 (用逗号或空格隔开)',
                                    hintStyle: TextStyle(
                                      color: Colors.grey.shade400,
                                      fontSize: 14,
                                    ),
                                    filled: true,
                                    fillColor: Colors.grey.shade50,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '提示：多个成员请用逗号或空格隔开，后续记账将自动分摊',
                                  style: TextStyle(fontSize: 10, color: Colors.grey),
                                ),
                              ],
                            ),
                            actions: <Widget>[
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text(
                                  '取消',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                              ElevatedButton(
                                onPressed: () {
                                  final String title =
                                      nameController.text.trim();
                                  if (title.isNotEmpty &&
                                      membersController.text.trim().isNotEmpty) {
                                    List<String> parsedMembers = membersController
                                        .text
                                        .split(RegExp(r'[,，\s]+'))
                                        .map((String e) => e.trim())
                                        .where((String e) => e.isNotEmpty)
                                        .toList();

                                    if (!parsedMembers.contains('我')) {
                                      parsedMembers.insert(0, '我');
                                    }
                                    parsedMembers = parsedMembers.toSet().toList();

                                    provider.createNewLedger(
                                      title,
                                      parsedMembers,
                                    );
                                    Navigator.pop(ctx);
                                    Navigator.pop(sheetContext);
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.indigo,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: const Text(
                                  '创建',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                      icon: const Icon(Icons.add, color: Colors.white),
                      label: const Text(
                        '新建空白账本',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black87,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSettlementSheet(BuildContext context) {
    final LedgerProvider ledger = context.read<LedgerProvider>();
    final List<TransferAction> actions = ledger.settlementActions;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        final double bottom = MediaQuery.paddingOf(sheetContext).bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.88,
            ),
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      Icon(Icons.auto_awesome, color: Colors.indigo.shade600),
                      const SizedBox(width: 8),
                      const Text(
                        '极简结算方案',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '已根据贪心债务化简，将交叉垫付合并为最少笔数转账。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 24),
                  if (actions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '当前账本全员平账，无需转账。',
                        style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                      ),
                    )
                  else
                    ...actions.map((TransferAction action) {
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          border: Border.all(color: Colors.orange.shade100),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                CircleAvatar(
                                  backgroundColor: Colors.grey.shade200,
                                  radius: 16,
                                  child: Text(
                                    _avatarLetter(action.from),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black87,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Icon(
                                    Icons.arrow_forward_rounded,
                                    color: Colors.orange.shade700,
                                    size: 16,
                                  ),
                                ),
                                CircleAvatar(
                                  backgroundColor: Colors.indigo.shade100,
                                  radius: 16,
                                  child: Text(
                                    _avatarLetter(action.to),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.indigo.shade800,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: <Widget>[
                                  Text(
                                    '${action.from} 需支付给 ${action.to}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                  ),
                                  Text(
                                    '¥ ${action.amount.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check, color: Colors.white, size: 18),
                    label: const Text(
                      '确定',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _avatarLetter(String name) {
    if (name.isEmpty) {
      return '?';
    }
    final Iterator<int> it = name.runes.iterator;
    return it.moveNext() ? String.fromCharCode(it.current) : '?';
  }

  Widget _buildTicketsView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Container(
          decoration: BoxDecoration(
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.indigo.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Column(
              children: <Widget>[
                Container(
                  color: Colors.indigo.shade600,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: <Widget>[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const Icon(Icons.flight_takeoff, color: Colors.white, size: 12),
                                const SizedBox(width: 6),
                                Text(
                                  '10月1日 · 去程',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Text(
                            'CA1356',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                '10:30',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                '北京 PEK',
                                style: TextStyle(
                                  color: Colors.indigo.shade100,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Column(
                                children: <Widget>[
                                  Text(
                                    '直飞 3h25m',
                                    style: TextStyle(
                                      color: Colors.indigo.shade200,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Stack(
                                    alignment: Alignment.center,
                                    children: <Widget>[
                                      Container(
                                        height: 1,
                                        width: double.infinity,
                                        color: Colors.indigo.shade300,
                                      ),
                                      Icon(
                                        Icons.flight,
                                        color: Colors.indigo.shade100,
                                        size: 16,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              const Text(
                                '13:55',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                '三亚 SYX',
                                style: TextStyle(
                                  color: Colors.indigo.shade100,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 30,
                  color: Colors.white,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: LayoutBuilder(
                            builder: (BuildContext context, BoxConstraints c) {
                              return CustomPaint(
                                size: Size(c.maxWidth, 2),
                                painter: _TicketDashedLinePainter(
                                  color: Colors.grey.shade300,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      Positioned(
                        left: -15,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 30,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF5F7FA),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Positioned(
                        right: -15,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 30,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF5F7FA),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '乘机人',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade400,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Leo',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            '座位',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade400,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            '42A',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.indigo.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(Icons.qr_code, size: 14, color: Colors.indigo.shade600),
                            const SizedBox(width: 4),
                            Text(
                              '凭证',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.indigo.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.grey.shade100),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CachedNetworkImage(
                  imageUrl:
                      'https://images.unsplash.com/photo-1566073771259-6a8506099945?w=300',
                  width: 100,
                  height: 100,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => Container(
                    width: 100,
                    height: 100,
                    color: Colors.grey.shade200,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            '亚特兰蒂斯酒店',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: Colors.black87,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '已确认',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '海景大床房 · 含双早',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '10月1日 14:00',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                            Text(
                              '2 晚 · 1 间',
                              style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.location_on,
                            size: 14,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 票根中间虚线（Flutter Border 不支持 dashed，用手绘虚线段）。
class _TicketDashedLinePainter extends CustomPainter {
  _TicketDashedLinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double dash = 5;
    const double gap = 4;
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    double x = 0;
    final double y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset((x + dash).clamp(0, size.width), y), p);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _TicketDashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}
