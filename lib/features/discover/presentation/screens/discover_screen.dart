import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gonow/core/providers/travel_provider.dart';
import 'package:gonow/core/utils/travel_image_helper.dart';
import 'package:gonow/features/discover/presentation/screens/blind_box_screen.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:provider/provider.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final List<String> _searchHints = <String>[
    '下个月看海，人少一点',
    '带父母去北京玩五天',
    '去新疆看雪需要准备什么',
    '周末去哪能吃地道火锅',
    '预算3000元，适合情侣去哪',
    '江浙沪 2 天自驾游',
    '曼谷+普吉岛 7天避坑',
    '独自旅行，治安好的古镇',
    '带 5 岁小孩去哪度假',
    '川西自驾需要防高反吗',
  ];
  int _currentHintIndex = 0;
  Timer? _hintTimer;
  bool _isLocked = false;

  int _selectedFilterIndex = 0;
  static const List<String> _filterTabs = <String>[
    '全部',
    '计划中',
    '进行中',
    '已完成',
  ];

  @override
  void initState() {
    super.initState();
    _currentHintIndex = math.Random().nextInt(_searchHints.length);
    _startTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final TravelProvider provider = Provider.of<TravelProvider>(
        context,
        listen: false,
      );
      provider.refreshBlindBox();
      provider.fetchInternationalCountries();
      provider.refreshVisaData();
    });
  }

  void _startTimer() {
    _hintTimer?.cancel();
    _hintTimer = Timer.periodic(const Duration(seconds: 15), (Timer timer) {
      if (mounted && !_isLocked) {
        setState(() {
          _currentHintIndex = (_currentHintIndex + 1) % _searchHints.length;
        });
      }
    });
  }

  void _handleSearchTap() {
    if (!_isLocked) {
      setState(() => _isLocked = true);
      _hintTimer?.cancel();
    }
    final String lockedHint = _searchHints[_currentHintIndex];
    final MainNavProvider navProvider = Provider.of<MainNavProvider>(
      context,
      listen: false,
    );
    navProvider.triggerAiPlanning(lockedHint, source: '发现页搜索', autoSend: false);
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    final TravelProvider provider = Provider.of<TravelProvider>(
      context,
      listen: false,
    );
    await provider.refreshBlindBox(force: true);
    await provider.fetchInternationalCountries(force: true);
    await provider.refreshVisaData(force: true);
  }

  static const List<_CultureTip> _cultureTips = <_CultureTip>[
    _CultureTip(
      country: '🇸🇬 新加坡',
      category: '法律禁令',
      content: '严禁售卖和咀嚼口香糖，违者将面临高达 1000 新元的罚款！',
      tone: _CultureTone.warning,
    ),
    _CultureTip(
      country: '🇹🇭 泰国',
      category: '文化禁忌',
      content: '切勿摸当地人的头部（包括小孩），头部在泰国文化中被视为神圣不可侵犯。',
      tone: _CultureTone.custom,
    ),
    _CultureTip(
      country: '🇪🇸 西班牙',
      category: '特殊作息',
      content: '著名的 Siesta（午休）文化，下午 2 点到 5 点很多商店和餐厅会歇业。',
      tone: _CultureTone.note,
    ),
    _CultureTip(
      country: '🇯🇵 日本',
      category: '交通礼仪',
      content: '电车上请勿大声接打电话，建议手机保持静音（マナーモード）。',
      tone: _CultureTone.note,
    ),
    _CultureTip(
      country: '🇮🇳 印度',
      category: '饮食习惯',
      content: '传统上视左手为不洁，递东西或抓取食物请优先使用右手。',
      tone: _CultureTone.custom,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: CustomScrollView(
          slivers: <Widget>[
            _buildHeaderSliver(context),
            _buildQuickActionsSliver(context),
            SliverToBoxAdapter(
              child: Consumer<ItineraryProvider>(
                builder:
                    (BuildContext context, ItineraryProvider p, Widget? _) {
                  return _buildItineraryHeader(p);
                },
              ),
            ),
            Consumer<ItineraryProvider>(
              builder:
                  (BuildContext context, ItineraryProvider provider, Widget? _) {
                final List<ItineraryModel> allItineraries =
                    provider.myItineraries;
                final List<ItineraryModel> filteredList =
                    allItineraries.where((ItineraryModel itinerary) {
                  if (_selectedFilterIndex == 0) {
                    return true;
                  }
                  final Map<String, dynamic> statusInfo =
                      _getItineraryStatusInfo(itinerary);
                  return statusInfo['index'] == _selectedFilterIndex;
                }).toList();

                if (filteredList.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Column(
                          children: <Widget>[
                            Icon(
                              Icons.flight_takeoff_rounded,
                              size: 48,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '空空如也，快去定制新行程吧',
                              style: TextStyle(color: Colors.grey.shade400),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      final ItineraryModel itinerary = filteredList[index];
                      final Map<String, dynamic> statusInfo =
                          _getItineraryStatusInfo(itinerary);
                      final Map<String, dynamic> planData =
                          itinerary.planData;
                      String startDateStr =
                          planData['start_date']?.toString().split('T')[0] ?? '';
                      String endDateStr =
                          planData['end_date']?.toString().split('T')[0] ?? '';
                      int daysCount =
                          (planData['days'] as List<dynamic>?)?.length ?? 1;
                      if (startDateStr.isEmpty) {
                        startDateStr =
                            itinerary.startDate.toIso8601String().split('T')[0];
                      }
                      if (endDateStr.isEmpty) {
                        endDateStr =
                            itinerary.endDate.toIso8601String().split('T')[0];
                      }
                      if (startDateStr.isNotEmpty && endDateStr.isNotEmpty) {
                        try {
                          final DateTime sDate = DateTime.parse(startDateStr);
                          final DateTime eDate = DateTime.parse(endDateStr);
                          daysCount = eDate.difference(sDate).inDays + 1;
                          if (daysCount < 1) {
                            daysCount = 1;
                          }
                        } catch (_) {}
                      }
                      String displayDates =
                          startDateStr.isNotEmpty ? startDateStr : '日期未定';
                      if (endDateStr.isNotEmpty && startDateStr != endDateStr) {
                        displayDates += ' 至 $endDateStr';
                      }
                      displayDates += ' ($daysCount天)';
                      final List<String> realTags =
                          planData['tags'] != null && planData['tags'] is List
                          ? List<String>.from(planData['tags'] as List<dynamic>)
                          : <String>['AI 定制', '专属'];
                      final String budgetStr =
                          planData['estimated_budget_per_person']?.toString() ??
                              '';
                      final String actualCostStr =
                          planData['actual_cost']?.toString() ?? '';
                      String displayBudget = '';
                      if (actualCostStr.isNotEmpty) {
                        displayBudget = '预 ¥$budgetStr | 实 ¥$actualCostStr';
                      } else {
                        displayBudget =
                            budgetStr.isNotEmpty ? '¥$budgetStr' : '预算核算中';
                      }

                      // 使用 TravelImageHelper 获取默认图片
                      final String displayImage =
                          (itinerary.coverImageUrl != null &&
                              itinerary.coverImageUrl!.isNotEmpty)
                          ? itinerary.coverImageUrl!
                          : TravelImageHelper.getImageUrlForDestination(
                              itinerary.destinationCity.isNotEmpty
                                  ? itinerary.destinationCity
                                  : itinerary.title,
                            );

                      return _buildItineraryCard(
                        title: itinerary.title,
                        location: itinerary.destinationCity,
                        dates: displayDates,
                        status: statusInfo['status'] as String,
                        statusColor: statusInfo['color'] as Color,
                        imageUrl: displayImage,
                        tags: realTags,
                        budget: displayBudget,
                        onEnterTap: () {
                          provider.setActiveItinerary(itinerary);
                          Provider.of<MainNavProvider>(
                            context,
                            listen: false,
                          ).setTab(1);
                        },
                        onDeleteTap: () async {
                          final bool? ok = await showDialog<bool>(
                            context: context,
                            builder: (BuildContext ctx) {
                              return AlertDialog(
                                title: const Text('删除行程'),
                                content: const Text('确定删除该行程？此操作不可撤销。'),
                                actions: <Widget>[
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, false),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              );
                            },
                          );
                          if (ok == true && context.mounted) {
                            await provider.deleteItinerary(itinerary.id);
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('行程已删除')),
                            );
                          }
                        },
                        onEditTap: () {
                          _showEditItinerarySheet(context, itinerary);
                        },
                        onCoverTap: () async {
                          try {
                            await provider.uploadCustomCover(itinerary.id);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('封面更新成功')),
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('上传失败: $e')),
                            );
                          }
                        },
                      );
                    },
                    childCount: filteredList.length,
                  ),
                );
              },
            ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderSliver(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '去哪儿寻找灵感？',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '输入你想去的地方，剩下的交给我',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              _SearchBox(
                hint: _searchHints[_currentHintIndex],
                hintIndex: _currentHintIndex,
                onTap: _handleSearchTap,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickActionsSliver(BuildContext context) {
    final List<_QuickActionData> actions = <_QuickActionData>[
      _QuickActionData(
        label: '周末盲盒',
        icon: Icons.card_giftcard_outlined,
        tone: _QuickTone.purple,
        onTap: () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const BlindBoxScreen(isInternational: false),
            ),
          );
        },
      ),
      _QuickActionData(
        label: '免签直飞',
        icon: Icons.flight_takeoff_outlined,
        tone: _QuickTone.blue,
        onTap: _showVisaBottomSheet,
      ),
      _QuickActionData(
        label: '入乡随俗',
        icon: Icons.menu_book_outlined,
        tone: _QuickTone.teal,
        onTap: _showCultureBottomSheet,
      ),
      _QuickActionData(
        label: '国际盲盒',
        icon: Icons.public,
        tone: _QuickTone.orange,
        onTap: () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const BlindBoxScreen(isInternational: true),
            ),
          );
        },
      ),
    ];

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
        child: Row(
          children: actions
              .map(
                (_QuickActionData action) =>
                    Expanded(child: _QuickActionCard(data: action)),
              )
              .toList(growable: false),
        ),
      ),
    );
  }

  int _countForFilter(ItineraryProvider p, int filterIndex) {
    final List<ItineraryModel> all = p.myItineraries;
    if (filterIndex == 0) {
      return all.length;
    }
    return all.where((ItineraryModel it) {
      final Map<String, dynamic> info = _getItineraryStatusInfo(it);
      return info['index'] == filterIndex;
    }).length;
  }

  Map<String, dynamic> _getItineraryStatusInfo(ItineraryModel itinerary) {
    final DateTime start = DateTime(
      itinerary.startDate.year,
      itinerary.startDate.month,
      itinerary.startDate.day,
    );
    final DateTime end = DateTime(
      itinerary.endDate.year,
      itinerary.endDate.month,
      itinerary.endDate.day,
    );
    final DateTime now = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    if (now.isBefore(start)) {
      return <String, dynamic>{
        'status': '计划中',
        'color': Colors.blue.shade500,
        'index': 1,
      };
    }
    if (now.isAfter(end)) {
      return <String, dynamic>{
        'status': '已完成',
        'color': Colors.grey.shade500,
        'index': 3,
      };
    }
    return <String, dynamic>{
      'status': '进行中',
      'color': Colors.green.shade500,
      'index': 2,
    };
  }

  String _destinationLine(ItineraryModel itinerary) {
    final Map<String, dynamic> plan = itinerary.planData;
    final Object? d =
        plan['destination_city'] ??
        plan['destinationCity'] ??
        plan['destination'] ??
        plan['destination_name'];
    if (d != null && d.toString().trim().isNotEmpty) {
      return d.toString().trim();
    }
    return itinerary.title;
  }

  String _resolveDisplayCover(ItineraryModel itinerary) {
    final String cloudCover = (itinerary.coverImageUrl ?? '').trim();
    if (cloudCover.isNotEmpty) {
      return cloudCover;
    }
    final Map<String, dynamic> planData = itinerary.planData;
    final Object? cover = planData['coverImageUrl'] ?? planData['cover_image_url'];
    if (cover != null && cover.toString().trim().isNotEmpty) {
      return cover.toString().trim();
    }
    final List<dynamic>? days = planData['days'] as List<dynamic>?;
    if (days != null && days.isNotEmpty && days.first is Map) {
      final Map<String, dynamic> day0 =
          Map<String, dynamic>.from(days.first as Map);
      final List<dynamic>? acts = day0['activities'] as List<dynamic>?;
      if (acts != null && acts.isNotEmpty && acts.first is Map) {
        final Map<String, dynamic> a0 =
            Map<String, dynamic>.from(acts.first as Map);
        final Object? u = a0['imageUrl'] ?? a0['image_url'];
        if (u != null && u.toString().trim().isNotEmpty) {
          return u.toString().trim();
        }
      }
    }
    return TravelImageHelper.getImageUrlForDestination(itinerary.title);
  }

  Widget _buildItineraryHeader(ItineraryProvider itineraryProvider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '我的旅行行程',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Colors.grey.shade900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List<Widget>.generate(_filterTabs.length, (int index) {
                final bool isActive = _selectedFilterIndex == index;
                return GestureDetector(
                  onTap: () => setState(() => _selectedFilterIndex = index),
                  child: _buildFilterTab(
                    '${_filterTabs[index]} (${_countForFilter(itineraryProvider, index)})',
                    isActive: isActive,
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTab(String text, {required bool isActive}) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF111827) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        boxShadow: isActive
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : <BoxShadow>[],
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
          color: isActive ? Colors.white : Colors.grey.shade500,
        ),
      ),
    );
  }

  Widget _buildItineraryCard({
    required String title,
    required String location,
    required String dates,
    required String status,
    required Color statusColor,
    required String imageUrl,
    required List<String> tags,
    required String budget,
    VoidCallback? onEnterTap,
    VoidCallback? onDeleteTap,
    VoidCallback? onEditTap,
    VoidCallback? onCoverTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24, left: 20, right: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 180,
            child: GestureDetector(
              onTap: onCoverTap,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (BuildContext context, String url) =>
                          Container(color: Colors.grey.shade100),
                      errorWidget:
                          (
                            BuildContext context,
                            String url,
                            Object error,
                          ) => Container(
                            color: Colors.grey.shade200,
                            child: const Icon(
                              Icons.broken_image,
                              color: Colors.grey,
                            ),
                          ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 60,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: <Color>[
                            Colors.black.withValues(alpha: 0.1),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 16,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(color: Colors.black12, blurRadius: 4),
                        ],
                      ),
                      child: Text(
                        status,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.location_on,
                      size: 14,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      location,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.calendar_month,
                      size: 14,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      dates,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 标签与预算
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(
                          children: tags
                              .map(
                                (String t) => Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.grey.shade100,
                                    ),
                                  ),
                                  child: Text(
                                    t,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        budget,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(height: 1, color: Color(0xFFF3F4F6)),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: ElevatedButton(
                        onPressed: onEnterTap,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo.shade600,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          '进入行程',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: onEditTap,
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          border: Border.all(color: Colors.grey.shade200),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: onDeleteTap,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          border: Border.all(color: Colors.red.shade100),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Colors.red.shade400,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showVisaBottomSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return const _VisaBottomSheet();
      },
    );
  }

  // 弹出修改行程信息的底窗
  void _showEditItinerarySheet(BuildContext context, ItineraryModel itinerary) {
    final Map<String, dynamic> planData = itinerary.planData;
    final TextEditingController titleCtrl = TextEditingController(text: itinerary.title);
    final TextEditingController destCtrl = TextEditingController(text: itinerary.destinationCity);
    final TextEditingController budgetCtrl = TextEditingController(
      text: planData['estimated_budget_per_person']?.toString() ?? '',
    );
    final TextEditingController actualCostCtrl = TextEditingController(
      text: planData['actual_cost']?.toString() ?? '',
    );
    List<String> existingTags = <String>[];
    if (planData['tags'] != null && planData['tags'] is List) {
      existingTags = List<String>.from(planData['tags'] as List<dynamic>);
    } else if (planData['tags'] == null) {
      existingTags = <String>['AI 定制', '专属'];
    }
    final TextEditingController tagsCtrl = TextEditingController(
      text: existingTags.join(', '),
    );
    String selectedStartDateStr =
        planData['start_date']?.toString().split('T')[0] ?? '';
    String selectedEndDateStr =
        planData['end_date']?.toString().split('T')[0] ?? '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (
            BuildContext context,
            void Function(void Function()) setModalState,
          ) {
            return AnimatedPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '修改行程信息',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _buildEditLabel('行程标题'),
                            _buildEditField(titleCtrl, '如：北京五日带父母舒心游'),
                            _buildEditLabel('目的地'),
                            _buildEditField(destCtrl, '如：北京'),
                            Row(
                              children: <Widget>[
                                Expanded(child: _buildEditLabel('预估预算')),
                                const SizedBox(width: 12),
                                Expanded(child: _buildEditLabel('实际花费 (选填)')),
                              ],
                            ),
                            Row(
                              children: <Widget>[
                                Expanded(child: _buildEditField(budgetCtrl, '如：3500')),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _buildEditField(actualCostCtrl, '如：3200'),
                                ),
                              ],
                            ),
                            _buildEditLabel('自定义标签 (用逗号隔开)'),
                            _buildEditField(tagsCtrl, '如：带父母, 慢节奏'),
                            Row(
                              children: <Widget>[
                                Expanded(child: _buildEditLabel('出发日期')),
                                const SizedBox(width: 12),
                                Expanded(child: _buildEditLabel('结束日期')),
                              ],
                            ),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: _buildDatePicker(
                                    context,
                                    selectedStartDateStr,
                                    (String date) {
                                      setModalState(() => selectedStartDateStr = date);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _buildDatePicker(
                                    context,
                                    selectedEndDateStr,
                                    (String date) {
                                      setModalState(() => selectedEndDateStr = date);
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () async {
                          if (titleCtrl.text.trim().isEmpty ||
                              destCtrl.text.trim().isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('标题和目的地不能为空')),
                            );
                            return;
                          }
                          final List<String> newTags = tagsCtrl.text
                              .split(RegExp(r'[,，]'))
                              .map((String e) => e.trim())
                              .where((String e) => e.isNotEmpty)
                              .toList();

                          await Provider.of<ItineraryProvider>(
                            context,
                            listen: false,
                          ).updateItineraryBasicInfo(
                            id: itinerary.id,
                            newTitle: titleCtrl.text.trim(),
                            newDestination: destCtrl.text.trim(),
                            newStartDate: selectedStartDateStr,
                            newEndDate: selectedEndDateStr,
                            newBudget: budgetCtrl.text.trim(),
                            newActualCost: actualCostCtrl.text.trim(),
                            newTags: newTags.isEmpty
                                ? <String>['专属定制']
                                : newTags,
                          );

                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('✅ 行程信息已更新')),
                            );
                          }
                        },
                        child: const Text(
                          '保存修改',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
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

  Widget _buildEditLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.indigo,
      ),
    ),
  );

  Widget _buildEditField(TextEditingController controller, String hint) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.black38),
        filled: true,
        fillColor: Colors.grey.shade50,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.indigo.shade300),
        ),
      ),
    ),
  );

  Widget _buildDatePicker(
    BuildContext context,
    String currentValue,
    Function(String) onPicked,
  ) {
    return GestureDetector(
      onTap: () async {
        FocusScope.of(context).unfocus();
        DateTime initialDate = DateTime.now();
        if (currentValue.isNotEmpty) {
          try {
            initialDate = DateTime.parse(currentValue);
          } catch (_) {}
        }
        final DateTime? picked = await showDatePicker(
          context: context,
          initialDate: initialDate,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1000)),
          builder: (BuildContext context, Widget? child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.light(primary: Colors.indigo),
            ),
            child: child!,
          ),
        );
        if (picked != null) {
          onPicked(picked.toIso8601String().split('T')[0]);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              currentValue.isEmpty ? '未设置' : currentValue,
              style: TextStyle(
                fontSize: 13,
                color: currentValue.isEmpty ? Colors.black38 : Colors.black87,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Icon(Icons.calendar_month, color: Colors.indigo, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _showCultureBottomSheet() async {
    final TravelProvider provider = Provider.of<TravelProvider>(
      context,
      listen: false,
    );
    if (provider.culturalCustoms.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('档案馆正在同步全球数据，请稍后再试...')));
      await provider.fetchCulturalCustoms();
      if (provider.culturalCustoms.isEmpty || !mounted) {
        return;
      }
    }

    final List<Map<String, dynamic>> allCustoms = provider.culturalCustoms;
    final List<Map<String, dynamic>> normalizedCustoms = allCustoms
        .map(_normalizeCultureItem)
        .where((Map<String, dynamic> e) => (e['content'] as String).isNotEmpty)
        .toList(growable: false);
    if (normalizedCustoms.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('风俗数据字段暂未匹配，请检查 Supabase 列名')),
      );
      return;
    }
    final List<Map<String, dynamic>> shuffledCustoms =
        List<Map<String, dynamic>>.from(normalizedCustoms)..shuffle();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        int visibleCount = math.min(32, shuffledCustoms.length);
        bool isAppending = false;
        return StatefulBuilder(
          builder:
              (
                BuildContext context,
                void Function(void Function()) setSheetState,
              ) {
                Future<void> appendMore() async {
                  if (isAppending || visibleCount >= shuffledCustoms.length) {
                    return;
                  }
                  setSheetState(() => isAppending = true);
                  await Future<void>.delayed(const Duration(milliseconds: 180));
                  if (!context.mounted) return;
                  setSheetState(() {
                    visibleCount = math.min(
                      visibleCount + 28,
                      shuffledCustoms.length,
                    );
                    isAppending = false;
                  });
                }

                return Container(
                  height: MediaQuery.of(context).size.height * 0.85,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF5F7FA),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(28),
                            topRight: Radius.circular(28),
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withOpacity(0.02),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  const Text(
                                    '世界风俗避坑局 🛡️',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    '每次打开都能解锁全新冷知识',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.black45,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: <Widget>[
                                      _buildLegendBadge(
                                        Colors.red.shade400,
                                        '法律红线',
                                      ),
                                      const SizedBox(width: 14),
                                      _buildLegendBadge(
                                        Colors.orange.shade400,
                                        '文化禁忌',
                                      ),
                                      const SizedBox(width: 14),
                                      _buildLegendBadge(
                                        Colors.blue.shade400,
                                        '当地冷知识',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.black54,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (ScrollNotification notification) {
                            if (notification.metrics.pixels >=
                                notification.metrics.maxScrollExtent - 220) {
                              appendMore();
                            }
                            return false;
                          },
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            itemCount: visibleCount + (isAppending ? 2 : 0),
                            itemBuilder: (BuildContext context, int index) {
                              if (index >= visibleCount) {
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  height: 88,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                );
                              }
                              final Map<String, dynamic> item =
                                  shuffledCustoms[index];
                              Color warningColor;
                              switch ((item['warning_level'] ?? '')
                                  .toString()) {
                                case 'danger':
                                  warningColor = Colors.red.shade400;
                                  break;
                                case 'warning':
                                  warningColor = Colors.orange.shade400;
                                  break;
                                default:
                                  warningColor = Colors.blue.shade400;
                              }
                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: <BoxShadow>[
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.03),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: <Widget>[
                                      ColoredBox(
                                        color: warningColor,
                                        child: const SizedBox(width: 6),
                                      ),
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              Row(
                                                children: <Widget>[
                                                  Text(
                                                    (item['flag_emoji'] ?? '🌍')
                                                        .toString(),
                                                    style: const TextStyle(
                                                      fontSize: 18,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      (item['country'] ?? '未知')
                                                          .toString(),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: Colors.black87,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: warningColor
                                                          .withOpacity(0.1),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      (item['category'] ?? '')
                                                          .toString(),
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: warningColor,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 10),
                                              Text(
                                                (item['content'] ?? '')
                                                    .toString(),
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.black87,
                                                  height: 1.5,
                                                  letterSpacing: 0.2,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
        );
      },
    );
  }

  Widget _buildLegendBadge(Color color, String text) {
    return Row(
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            border: Border.all(color: color, width: 2),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _normalizeCultureItem(Map<String, dynamic> raw) {
    final String warningLevel =
        (raw['warning_level'] ?? raw['level'] ?? raw['risk_level'] ?? '')
            .toString();
    final String country =
        (raw['country'] ?? raw['name'] ?? raw['nation'] ?? '未知').toString();
    final String flag = (raw['flag_emoji'] ?? raw['flag'] ?? '🌍').toString();
    final String category = (raw['category'] ?? raw['type'] ?? raw['tag'] ?? '')
        .toString();
    final String content =
        (raw['content'] ??
                raw['description'] ??
                raw['tip'] ??
                raw['note'] ??
                '')
            .toString();
    return <String, dynamic>{
      'warning_level': warningLevel,
      'country': country,
      'flag_emoji': flag,
      'category': category,
      'content': content,
    };
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.hint,
    required this.hintIndex,
    required this.onTap,
  });

  final String hint;
  final int hintIndex;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colorScheme.shadow.withOpacity(0.08),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.search_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0.0, 0.2),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                  child: Text(
                    hint,
                    key: ValueKey<int>(hintIndex),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[colorScheme.primary, colorScheme.tertiary],
                  ),
                  shape: BoxShape.circle,
                ),
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: colorScheme.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({required this.data});

  final _QuickActionData data;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color baseColor = switch (data.tone) {
      _QuickTone.purple => Colors.purple.withOpacity(0.08),
      _QuickTone.blue => Colors.blue.withOpacity(0.08),
      _QuickTone.teal => Colors.teal.withOpacity(0.08),
      _QuickTone.orange => Colors.orange.withOpacity(0.08),
    };
    final Color iconColor = switch (data.tone) {
      _QuickTone.purple => Colors.purple,
      _QuickTone.blue => Colors.blue,
      _QuickTone.teal => Colors.teal,
      _QuickTone.orange => Colors.orange,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: data.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: baseColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(data.icon, color: iconColor, size: 28),
              ),
              const SizedBox(height: 6),
              Text(
                data.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.grey.shade700,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisaBottomSheet extends StatelessWidget {
  const _VisaBottomSheet();

  @override
  Widget build(BuildContext context) {
    final TravelProvider provider = context.watch<TravelProvider>();
    final Map<String, List<Map<String, dynamic>>> grouped =
        provider.visaFreeData;
    final Size size = MediaQuery.of(context).size;
    return Container(
      height: size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: DefaultTabController(
        length: grouped.keys.isEmpty ? 1 : grouped.keys.length,
        child: Column(
          children: <Widget>[
            Container(
              height: 190,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                image: DecorationImage(
                  image: const NetworkImage(
                    'https://images.unsplash.com/photo-1526772662000-3f88f10405ff?auto=format&fit=crop&q=80&w=1200',
                  ),
                  fit: BoxFit.cover,
                  colorFilter: ColorFilter.mode(
                    Colors.black.withOpacity(0.52),
                    BlendMode.darken,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 26, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Spacer(),
                    const Text(
                      '中国护照免签 / 落地签目的地',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '随时买机票，拿上护照说走就走',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: _buildBody(provider, grouped)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    TravelProvider provider,
    Map<String, List<Map<String, dynamic>>> grouped,
  ) {
    if (provider.isVisaLoading && grouped.isEmpty) {
      return const _VisaSkeletonGrid();
    }

    if (provider.visaError != null || grouped.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.public, color: Colors.grey.shade500, size: 42),
            const SizedBox(height: 10),
            Text('暂时无法加载免签数据', style: TextStyle(color: Colors.grey.shade400)),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () {
                provider.refreshVisaData(force: true);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    final List<String> continents = grouped.keys.toList(growable: false);
    return Column(
      children: <Widget>[
        TabBar(
          isScrollable: true,
          tabs: continents
              .map((String e) => Tab(text: e))
              .toList(growable: false),
        ),
        Expanded(
          child: TabBarView(
            children: continents
                .map(
                  (String c) => _VisaGrid(
                    countries: grouped[c] ?? <Map<String, dynamic>>[],
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ],
    );
  }
}

class _VisaSkeletonGrid extends StatefulWidget {
  const _VisaSkeletonGrid();

  @override
  State<_VisaSkeletonGrid> createState() => _VisaSkeletonGridState();
}

class _VisaSkeletonGridState extends State<_VisaSkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        final double t = _controller.value;
        final Color base =
            Color.lerp(Colors.grey.shade800, Colors.grey.shade700, t) ??
            Colors.grey.shade800;
        final Color highlight =
            Color.lerp(Colors.grey.shade700, Colors.grey.shade600, t) ??
            Colors.grey.shade700;
        return GridView.builder(
          padding: const EdgeInsets.all(14),
          itemCount: 6,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
          ),
          itemBuilder: (BuildContext context, int index) {
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[base, highlight, base],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _VisaGrid extends StatelessWidget {
  const _VisaGrid({required this.countries});

  final List<Map<String, dynamic>> countries;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      padding: const EdgeInsets.all(14),
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.95,
      children: countries
          .map((Map<String, dynamic> c) => _VisaCard(country: c))
          .toList(growable: false),
    );
  }
}

class _VisaCard extends StatelessWidget {
  const _VisaCard({required this.country});

  final Map<String, dynamic> country;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CachedNetworkImage(
            imageUrl: _normalizeImageUrl(country['image_url'] ?? ''),
            fit: BoxFit.cover,
            httpHeaders: const <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            },
            errorWidget: (context, url, error) => Container(
              color: Colors.blueGrey.shade800,
              child: const Center(
                child: Icon(Icons.public, color: Colors.white30, size: 40),
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: <Color>[Colors.black87, Colors.transparent],
              ),
            ),
          ),
          Positioned(
            left: 10,
            bottom: 10,
            child: Text(
              '${country['flag_emoji'] ?? ''} ${country['name'] ?? ''}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _normalizeVisaTypeLabel(country['visa_type']?.toString() ?? ''),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _normalizeImageUrl(String raw) {
  final RegExp pattern = RegExp(r'\((https?:\/\/[^)]+)\)');
  final RegExpMatch? match = pattern.firstMatch(raw);
  if (match != null) {
    return match.group(1) ?? raw;
  }
  return raw;
}

String _normalizeVisaTypeLabel(String raw) {
  if (raw.contains('落地')) {
    return '落地签';
  }
  if (raw.contains('免签')) {
    return '免签';
  }
  return raw;
}

class _CultureBottomSheet extends StatelessWidget {
  const _CultureBottomSheet({
    required this.tips,
    required this.buildLegendBadge,
  });

  final List<_CultureTip> tips;
  final Widget Function(Color color, String text) buildLegendBadge;

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    return Container(
      height: size.height * 0.82,
      decoration: BoxDecoration(
        color: const Color(0xFFE9F0EC),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: <BoxShadow>[
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 30),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '世界风俗避坑局 🛡️',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '每次打开都能解锁全新冷知识',
                    style: TextStyle(fontSize: 12, color: Colors.black45),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      buildLegendBadge(Colors.red.shade400, '法律红线'),
                      const SizedBox(width: 14),
                      buildLegendBadge(Colors.orange.shade400, '文化禁忌'),
                      const SizedBox(width: 14),
                      buildLegendBadge(Colors.blue.shade400, '当地冷知识'),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: tips.length,
                itemBuilder: (BuildContext context, int index) {
                  final _CultureTip tip = tips[index];
                  final Color accent = switch (tip.tone) {
                    _CultureTone.warning => Colors.red,
                    _CultureTone.custom => Colors.orange,
                    _CultureTone.note => Colors.purple,
                  };
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 4,
                          height: 92,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(16),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  tip.country,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '【${tip.category}】${tip.content}',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _QuickTone { purple, blue, teal, orange }

class _QuickActionData {
  const _QuickActionData({
    required this.label,
    required this.icon,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final _QuickTone tone;
  final Future<void> Function() onTap;
}

enum _CultureTone { warning, custom, note }

class _CultureTip {
  const _CultureTip({
    required this.country,
    required this.category,
    required this.content,
    required this.tone,
  });

  final String country;
  final String category;
  final String content;
  final _CultureTone tone;
}
