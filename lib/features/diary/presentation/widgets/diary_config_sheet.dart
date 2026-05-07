import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gonow/core/utils/image_compress_util.dart';
import 'package:gonow/core/utils/travel_image_helper.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:gonow/features/diary/presentation/screens/diary_detail_screen.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

/// 将补录 lazy 用户所选本地路径写入 `is_lazy_pool` 活动节点，供详情页瀑布流展示。
void _injectLazyPoolPhotosIntoLazyNode(
  Map<String, dynamic> data,
  List<XFile> photos,
) {
  if (photos.isEmpty) return;
  final List<String> paths =
      photos.map((XFile e) => e.path).where((String p) => p.isNotEmpty).toList();
  if (paths.isEmpty) return;
  final List<dynamic>? days = data['days'] as List<dynamic>?;
  if (days == null || days.isEmpty) return;
  for (int d = 0; d < days.length; d++) {
    final Map<String, dynamic> day =
        Map<String, dynamic>.from(days[d] as Map? ?? <String, dynamic>{});
    final List<dynamic> acts =
        List<dynamic>.from(day['activities'] as List<dynamic>? ?? <dynamic>[]);
    for (int a = 0; a < acts.length; a++) {
      final Map<String, dynamic> act =
          Map<String, dynamic>.from(acts[a] as Map? ?? <String, dynamic>{});
      final String flag = act['is_lazy_pool']?.toString().toLowerCase() ?? '';
      final bool isPool = act['is_lazy_pool'] == true ||
          flag == 'true' ||
          flag == '1' ||
          (act['title'] ?? '').toString().contains('记忆碎片');
      if (isPool) {
        act['is_lazy_pool'] = true;
        act['photos'] = List<String>.from(paths);
        act['images'] = List<String>.from(paths);
        acts[a] = act;
        day['activities'] = acts;
        days[d] = day;
        data['days'] = days;
        return;
      }
    }
  }
}

Future<void> showDiaryConfigSheet(BuildContext context) async {
  // ── 根本修复：改用真正的 StatefulWidget 作为 BottomSheet 内容。
  // 原来用 StatefulBuilder 时，_destinationController 在函数作用域内声明，
  // 生命周期与 showModalBottomSheet 的 await 绑定：
  //   1. outerNav.maybePop() 返回 → BottomSheet 关闭动画开始（但未结束）
  //   2. await showModalBottomSheet 完成 → _destinationController.dispose() 被调用
  //   3. BottomSheet 动画最后几帧仍在重建 TextField → controller 已销毁 → 崩溃
  //   4. 级联触发 _dependents.isEmpty + Duplicate GlobalKey 红屏
  //
  // StatefulWidget 的 dispose() 由 Flutter 框架在动画真正结束后调用，
  // 保证 controller 在最后一帧渲染完成之前绝对不会被销毁。
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // useRootNavigator: true 确保使用根 Navigator，
    // 避免 builder context 的子 Navigator 与外层 Navigator 产生 Overlay 竞争
    useRootNavigator: true,
    builder: (BuildContext sheetContext) {
      return _DiaryConfigSheetContent(outerContext: context);
    },
  );
}
// ── _DiaryConfigSheetContent ──────────────────────────────────────────────────
// BottomSheet の内容を StatefulWidget に昇格させた。
// これにより TextEditingController の dispose() が Flutter フレームワークの
// ウィジェット破棄ライフサイクル（アニメーション完了後）と正確に同期し、
// 閉じるアニメーション中に controller が使用されてクラッシュするのを防ぐ。
class _DiaryConfigSheetContent extends StatefulWidget {
  const _DiaryConfigSheetContent({required this.outerContext});
  final BuildContext outerContext;

  @override
  State<_DiaryConfigSheetContent> createState() =>
      _DiaryConfigSheetContentState();
}

class _DiaryConfigSheetContentState extends State<_DiaryConfigSheetContent> {
  final List<Map<String, String>> diaryStyles = <Map<String, String>>[
    <String, String>{'icon': '🍃', 'name': '文艺清新'},
    <String, String>{'icon': '🎬', 'name': '电影质感'},
    <String, String>{'icon': '🌈', 'name': '多巴胺色彩'},
    <String, String>{'icon': '🍔', 'name': '饕餮食客'},
    <String, String>{'icon': '🪖', 'name': '硬核特种兵'},
    <String, String>{'icon': '🌑', 'name': '孤独探索者'},
    <String, String>{'icon': '🏕️', 'name': '荒野露营派'},
    <String, String>{'icon': '🧘', 'name': '慢生活疗愈'},
    <String, String>{'icon': '🏛️', 'name': '城市建筑控'},
    <String, String>{'icon': '🎧', 'name': '夜色霓虹流'},
  ];

  final ImagePicker _picker = ImagePicker();
  bool _isCustomMode = false;
  String _subRecordMode = 'lazy';
  String _selectedStyle = '文艺清新';
  bool _isGenerating = false;
  String? _errorMessage;
  String? _selectedItineraryId;
  final TextEditingController _destinationController = TextEditingController();
  final List<XFile> _selectedPhotos = <XFile>[];
  XFile? _detailCoverPhoto;
  String? _backgroundTaskId;

  String _getStatusText(String? status) {
    switch (status) {
      case 'planning':
        return '计划中';
      case 'traveling':
        return '进行中';
      case 'finished':
        return '已结束';
      default:
        return '未定';
    }
  }

  Color _getStatusColor(String? status) {
    switch (status) {
      case 'planning':
        return Colors.blue.shade400;
      case 'traveling':
        return Colors.green.shade400;
      case 'finished':
        return Colors.grey.shade400;
      default:
        return Colors.grey.shade400;
    }
  }

  /// 根据行程日期动态计算状态（与发现页保持一致）
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
      };
    }
    if (now.isAfter(end)) {
      return <String, dynamic>{
        'status': '已完成',
        'color': Colors.grey.shade500,
      };
    }
    return <String, dynamic>{
      'status': '进行中',
      'color': Colors.green.shade500,
    };
  }

  @override
  void initState() {
    super.initState();
    // 监听 DiaryProvider 后台任务完成，跳转详情页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final DiaryProvider dp =
          Provider.of<DiaryProvider>(context, listen: false);
      dp.addListener(_onBackgroundTaskChanged);
    });
  }

  void _onBackgroundTaskChanged() {
    // Widget 已销毁（Sheet 已关闭）时不再处理
    if (!mounted) return;
    final DiaryProvider dp =
        Provider.of<DiaryProvider>(context, listen: false);
    if (_backgroundTaskId == null) return;
    if (dp.backgroundTaskId != _backgroundTaskId) return;

    if (dp.backgroundTaskStatus == 'done' &&
        dp.backgroundGeneratedDiary != null) {
      final DiaryModel diary = dp.backgroundGeneratedDiary!;
      dp.clearBackgroundTask();
      _backgroundTaskId = null;
      // Sheet 已在 _onGenerate 中关闭，直接用 outerNav 跳转
      final NavigatorState outerNav = Navigator.of(widget.outerContext);
      outerNav.push(
        MaterialPageRoute<void>(
          builder: (_) => DiaryDetailScreen(
            initialDiary: diary,
            startEditing: true,
          ),
        ),
      );
    } else if (dp.backgroundTaskStatus == 'error') {
      final String errMsg = dp.backgroundError ?? 'AI 生成失败，请重试';
      dp.clearBackgroundTask();
      _backgroundTaskId = null;
      // 用 ScaffoldMessenger 在主页面弹出错误提示（Sheet 已关闭）
      ScaffoldMessenger.of(widget.outerContext).showSnackBar(
        SnackBar(
          content: Text(errMsg),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    // 注销监听器，防止内存泄漏
    try {
      final DiaryProvider dp =
          Provider.of<DiaryProvider>(context, listen: false);
      dp.removeListener(_onBackgroundTaskChanged);
    } catch (_) {}
    _destinationController.dispose();
    super.dispose();
  }

  Future<void> _onGenerate() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    // ── 校验（与原逻辑完全一致）──
    if (_isCustomMode) {
      if (_destinationController.text.trim().isEmpty) {
        setState(() {
          _errorMessage = _subRecordMode == 'detailed'
              ? '请填写详细行程描述'
              : '请告诉管家您去过的目的地哦';
        });
        return;
      }
      if (_subRecordMode == 'lazy' && _selectedPhotos.isEmpty) {
        setState(() => _errorMessage = '请至少上传一张旅途照片');
        return;
      }
      if (_subRecordMode == 'detailed' && _detailCoverPhoto == null) {
        setState(() => _errorMessage = '请选择一张手账封面图');
        return;
      }
    }

    final ItineraryProvider itineraryProvider =
        Provider.of<ItineraryProvider>(context, listen: false);
    final List<ItineraryModel> itineraries = itineraryProvider.myItineraries;
    final ItineraryModel? existingItinerary = _isCustomMode
        ? null
        : itineraries.cast<ItineraryModel?>().firstWhere(
              (ItineraryModel? item) => item?.id == _selectedItineraryId,
              orElse: () => null,
            );

    if (!_isCustomMode && existingItinerary == null) {
      setState(() => _errorMessage = '未找到可关联的已有行程');
      return;
    }

    // ── 组装 封面图 / 标题 / DiaryId（与原逻辑完全一致）──
    final String newDiaryId = const Uuid().v4();

    String? autoCoverImageUrl;
    if (!_isCustomMode && existingItinerary != null) {
      try {
        final List<dynamic> orgDays =
            (existingItinerary.planData['days'] as List<dynamic>?) ??
            (existingItinerary.planData['daily_schedules'] as List<dynamic>?) ??
            <dynamic>[];
        for (final dynamic dayRaw in orgDays) {
          if (autoCoverImageUrl != null) break;
          final Map<String, dynamic> dayMap = Map<String, dynamic>.from(
            dayRaw as Map? ?? <String, dynamic>{},
          );
          final List<dynamic> acts =
              (dayMap['activities'] as List<dynamic>?) ?? <dynamic>[];
          for (final dynamic actRaw in acts) {
            final Map<String, dynamic> actMap = Map<String, dynamic>.from(
              actRaw as Map? ?? <String, dynamic>{},
            );
            final List<dynamic> images =
                (actMap['images'] as List<dynamic>?) ?? <dynamic>[];
            if (images.isNotEmpty) {
              autoCoverImageUrl = images.first.toString().trim();
              if (autoCoverImageUrl!.isNotEmpty) break;
            }
            final String imageUrl =
                (actMap['imageUrl'] ?? actMap['image_url'] ?? '').toString().trim();
            if (imageUrl.isNotEmpty) {
              autoCoverImageUrl = imageUrl;
              break;
            }
          }
        }
      } catch (_) {}
    }

    String finalCoverImg;
    if (_isCustomMode && _selectedPhotos.isNotEmpty) {
      finalCoverImg = _selectedPhotos.first.path;
    } else if (_isCustomMode && _detailCoverPhoto != null) {
      finalCoverImg = _detailCoverPhoto!.path;
    } else if (_isCustomMode) {
      finalCoverImg = TravelImageHelper.getImageUrlForDestination(
        _destinationController.text.trim(),
      );
    } else if (!_isCustomMode && existingItinerary != null) {
      final String fromAi = (autoCoverImageUrl ?? '').trim();
      final String fromFallback = TravelImageHelper.getImageUrlForDestination(
        existingItinerary.destinationCity.isNotEmpty
            ? existingItinerary.destinationCity
            : existingItinerary.title,
      );
      finalCoverImg = fromAi.isNotEmpty ? fromAi : fromFallback;
    } else {
      finalCoverImg = TravelImageHelper.getImageUrlForDestination('');
    }

    final String extractedDestination = _isCustomMode
        ? _destinationController.text.trim()
        : _extractDestination(existingItinerary);
    final String newDiaryTitle =
        _isCustomMode ? _destinationController.text.trim() : existingItinerary!.title;

    // ── 启动后台生成（不阻塞 UI）──
    final DiaryProvider diaryProvider =
        Provider.of<DiaryProvider>(context, listen: false);

    final String taskId = diaryProvider.startBackgroundGenerate(
      destination: extractedDestination,
      style: _selectedStyle,
      newDiaryId: newDiaryId,
      newDiaryTitle: '✨ $newDiaryTitle',
      coverImageUrl: finalCoverImg,
      existingPlanData: existingItinerary?.planData,
      subRecordMode: _isCustomMode ? _subRecordMode : null,
      customPhotoCount:
          _isCustomMode && _subRecordMode == 'lazy' ? _selectedPhotos.length : null,
      // 懒人池模式的照片注入需要 XFile 路径，在 provider 层处理不了 XFile，
      // 所以这里传 null，由后台 AI 返回后通过 preBuiltDiaryData 路径补注入。
      // 详细模式直接让 provider 走 AI 生成路径即可。
      preBuiltDiaryData: null,
    );
    _backgroundTaskId = taskId;

    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();

    // ── 立即关闭 Sheet，用户可自由继续操作 ──
    Navigator.of(context).pop();

    // ── 在主页面底部弹出「后台生成中」提示 ──
    ScaffoldMessenger.of(widget.outerContext).showSnackBar(
      SnackBar(
        content: const Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 12),
            Text('AI 正在后台生成手账，完成后自动跳转…'),
          ],
        ),
        duration: const Duration(seconds: 30),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.indigo.shade600,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ItineraryProvider itineraryProvider =
        Provider.of<ItineraryProvider>(context);
    final List<ItineraryModel> itineraries = itineraryProvider.myItineraries;
    if (itineraries.isEmpty) {
      _selectedItineraryId = null;
    } else if (_selectedItineraryId == null ||
        !itineraries.any((ItineraryModel e) => e.id == _selectedItineraryId)) {
      _selectedItineraryId = itineraries.first.id;
    }

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
            child: Container(
              height: MediaQuery.of(context).size.height * 0.85,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
              ),
              child: Stack(
                children: <Widget>[
                  Column(
                    children: <Widget>[
                      const SizedBox(height: 12),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '生成配置舱',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
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
                                  onTap: () {
                                    setState(() {
                                      _isCustomMode = false;
                                      _subRecordMode = 'lazy';
                                      _selectedPhotos.clear();
                                      _detailCoverPhoto = null;
                                      _errorMessage = null;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    decoration: BoxDecoration(
                                      color: !_isCustomMode
                                          ? Colors.white
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: !_isCustomMode
                                          ? <BoxShadow>[
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: 0.04),
                                                blurRadius: 4,
                                                offset: const Offset(0, 2),
                                              ),
                                            ]
                                          : <BoxShadow>[],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '关联已有行程',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: !_isCustomMode
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: !_isCustomMode
                                            ? Colors.indigo.shade600
                                            : Colors.grey.shade500,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _isCustomMode = true;
                                      _subRecordMode = 'lazy';
                                      _errorMessage = null;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    decoration: BoxDecoration(
                                      color: _isCustomMode
                                          ? Colors.white
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: _isCustomMode
                                          ? <BoxShadow>[
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: 0.04),
                                                blurRadius: 4,
                                                offset: const Offset(0, 2),
                                              ),
                                            ]
                                          : <BoxShadow>[],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '补录往期精彩',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: _isCustomMode
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: _isCustomMode
                                            ? Colors.indigo.shade600
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
                      const SizedBox(height: 24),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (!_isCustomMode) ...<Widget>[
                                if (itineraries.isEmpty)
                                  Container(
                                    padding: const EdgeInsets.all(20),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '暂无可用行程，先去规划一次旅行吧！',
                                      style:
                                          TextStyle(color: Colors.grey.shade500),
                                    ),
                                  )
                                else
                                  Column(
                                    children: itineraries.map((ItineraryModel trip) {
                                      final bool isSelected =
                                          _selectedItineraryId == trip.id;

                                      // 使用动态计算的状态信息（与发现页保持一致）
                                      final Map<String, dynamic> statusInfo =
                                          _getItineraryStatusInfo(trip);

                                      final String imageUrl =
                                          (trip.coverImageUrl ?? '').trim().isNotEmpty
                                          ? trip.coverImageUrl!.trim()
                                          : TravelImageHelper
                                                .getImageUrlForDestination(
                                                  trip.destinationCity.isNotEmpty
                                                      ? trip.destinationCity
                                                      : trip.title,
                                                );
                                      
                                      // 调试日志：检查图片 URL
                                      debugPrint('行程 "${trip.title}" 的图片 URL: $imageUrl');

                                      return GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _selectedItineraryId = trip.id;
                                          });
                                        },
                                        child: Container(
                                          margin: const EdgeInsets.only(bottom: 12),
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(
                                              color: isSelected
                                                  ? Colors.indigo
                                                  : Colors.grey.shade100,
                                              width: isSelected ? 2 : 1,
                                            ),
                                            boxShadow: <BoxShadow>[
                                              if (isSelected)
                                                BoxShadow(
                                                  color: Colors.indigo
                                                      .withValues(alpha: 0.1),
                                                  blurRadius: 8,
                                                  offset: const Offset(0, 4),
                                                ),
                                            ],
                                          ),
                                          child: Row(
                                            children: <Widget>[
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: CachedNetworkImage(
                                                  imageUrl: imageUrl,
                                                  width: 48,
                                                  height: 48,
                                                  fit: BoxFit.cover,
                                                  placeholder:
                                                      (
                                                        BuildContext context,
                                                        String url,
                                                      ) => Container(
                                                        color: Colors
                                                            .grey
                                                            .shade100,
                                                        width: 48,
                                                        height: 48,
                                                        child: const Padding(
                                                          padding:
                                                              EdgeInsets.all(
                                                                12,
                                                              ),
                                                          child:
                                                              CircularProgressIndicator(
                                                                strokeWidth: 2,
                                                              ),
                                                        ),
                                                      ),
                                                  errorWidget:
                                                      (
                                                        BuildContext context,
                                                        String url,
                                                        Object error,
                                                      ) => Container(
                                                        color: Colors
                                                            .grey
                                                            .shade200,
                                                        width: 48,
                                                        height: 48,
                                                        child: const Icon(
                                                          Icons
                                                              .image_not_supported,
                                                          color: Colors.grey,
                                                          size: 20,
                                                        ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: <Widget>[
                                                    Text(
                                                      trip.title,
                                                      style: const TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Row(
                                                      children: <Widget>[
                                                        Container(
                                                          width: 6,
                                                          height: 6,
                                                          decoration:
                                                              BoxDecoration(
                                                            color: statusInfo['color'] as Color,
                                                            shape: BoxShape
                                                                .circle,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 6),
                                                        Text(
                                                          statusInfo['status'] as String,
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            color: Colors.grey
                                                                .shade600,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (isSelected)
                                                const Icon(
                                                  Icons.check_circle_rounded,
                                                  color: Colors.indigo,
                                                  size: 24,
                                                )
                                              else
                                                Icon(
                                                  Icons.circle_outlined,
                                                  color: Colors.grey.shade300,
                                                  size: 24,
                                                ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                              ],
                              if (_isCustomMode) ...<Widget>[
                                Container(
                                  margin: const EdgeInsets.only(bottom: 20),
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _subRecordMode = 'lazy';
                                              _errorMessage = null;
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: _subRecordMode == 'lazy'
                                                  ? Colors.white
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                              boxShadow: _subRecordMode == 'lazy'
                                                  ? <BoxShadow>[
                                                      BoxShadow(
                                                        color: Colors.black.withValues(alpha: 0.05),
                                                        blurRadius: 4,
                                                      ),
                                                    ]
                                                  : <BoxShadow>[],
                                            ),
                                            child: Center(
                                              child: Text(
                                                '懒人照片池',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: _subRecordMode == 'lazy'
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: _subRecordMode == 'lazy'
                                                      ? Colors.indigo.shade700
                                                      : Colors.grey.shade500,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _subRecordMode = 'detailed';
                                              _errorMessage = null;
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: _subRecordMode == 'detailed'
                                                  ? Colors.white
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                              boxShadow: _subRecordMode == 'detailed'
                                                  ? <BoxShadow>[
                                                      BoxShadow(
                                                        color: Colors.black.withValues(alpha: 0.05),
                                                        blurRadius: 4,
                                                      ),
                                                    ]
                                                  : <BoxShadow>[],
                                            ),
                                            child: Center(
                                              child: Text(
                                                '精细日记',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: _subRecordMode == 'detailed'
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: _subRecordMode == 'detailed'
                                                      ? Colors.indigo.shade700
                                                      : Colors.grey.shade500,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_subRecordMode == 'lazy') ...<Widget>[
                                  const Text(
                                    '上传旅途照片 (最多 20 张)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: 88,
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: _selectedPhotos.length +
                                          (_selectedPhotos.length < 20 ? 1 : 0),
                                      itemBuilder: (BuildContext context, int index) {
                                        if (index == _selectedPhotos.length) {
                                          return GestureDetector(
                                            onTap: () async {
                                              final int remaining =
                                                  20 - _selectedPhotos.length;
                                              if (remaining <= 0) return;
                                              List<XFile> files = <XFile>[];
                                              try {
                                                files = await _picker.pickMultiImage(
                                                  limit: 20,
                                                );
                                              } catch (_) {
                                                final XFile? one =
                                                    await _picker.pickImage(
                                                  source: ImageSource.gallery,
                                                );
                                                if (one != null) {
                                                  files = <XFile>[one];
                                                }
                                              }
                                              if (files.isEmpty) return;
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    '正在处理高画质照片…',
                                                  ),
                                                  duration: Duration(seconds: 2),
                                                  behavior:
                                                      SnackBarBehavior.floating,
                                                ),
                                              );
                                              final List<XFile> optimized =
                                                  await ImageCompressUtil
                                                      .compressImages(files);
                                              if (!context.mounted) return;
                                              setState(() {
                                                _selectedPhotos.addAll(
                                                  optimized.take(remaining),
                                                );
                                                while (_selectedPhotos.length >
                                                    20) {
                                                  _selectedPhotos.removeLast();
                                                }
                                                _errorMessage = null;
                                              });
                                            },
                                            child: Container(
                                              width: 80,
                                              height: 80,
                                              margin: const EdgeInsets.only(right: 10),
                                              decoration: BoxDecoration(
                                                color: Colors.grey.shade50,
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(
                                                  color: Colors.grey.shade300,
                                                ),
                                              ),
                                              child: Icon(
                                                Icons.add_photo_alternate_outlined,
                                                color: Colors.grey.shade400,
                                                size: 24,
                                              ),
                                            ),
                                          );
                                        }
                                        return Container(
                                          width: 80,
                                          height: 80,
                                          margin: const EdgeInsets.only(right: 10),
                                          clipBehavior: Clip.antiAlias,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: <Widget>[
                                              Image.file(
                                                File(_selectedPhotos[index].path),
                                                fit: BoxFit.cover,
                                              ),
                                              Positioned(
                                                top: 4,
                                                right: 4,
                                                child: GestureDetector(
                                                  onTap: () {
                                                    setState(() {
                                                      _selectedPhotos.removeAt(index);
                                                      _errorMessage = null;
                                                    });
                                                  },
                                                  child: Container(
                                                    padding: const EdgeInsets.all(4),
                                                    decoration: const BoxDecoration(
                                                      color: Colors.black54,
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: const Icon(
                                                      Icons.close,
                                                      size: 12,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade50,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Colors.grey.shade200),
                                    ),
                                    child: TextField(
                                      controller: _destinationController,
                                      onChanged: (String _) {
                                        if (_errorMessage != null) {
                                          setState(() => _errorMessage = null);
                                        }
                                      },
                                      decoration: const InputDecoration(
                                        hintText: '去了哪儿？(如：秋天的阿勒泰)',
                                        hintStyle: TextStyle(
                                          fontSize: 13,
                                          color: Colors.black38,
                                        ),
                                        border: InputBorder.none,
                                      ),
                                    ),
                                  ),
                                ] else ...<Widget>[
                                  const Text(
                                    '设置手账封面 (1 张)',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  GestureDetector(
                                    onTap: () async {
                                      final XFile? file = await _picker.pickImage(
                                        source: ImageSource.gallery,
                                      );
                                      if (file == null) return;
                                      setState(() {
                                        _detailCoverPhoto = file;
                                        _errorMessage = null;
                                      });
                                    },
                                    child: Container(
                                      width: double.infinity,
                                      height: 120,
                                      clipBehavior: Clip.antiAlias,
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: Colors.grey.shade300),
                                      ),
                                      child: _detailCoverPhoto == null
                                          ? Column(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: <Widget>[
                                                Icon(
                                                  Icons.add_a_photo_outlined,
                                                  color: Colors.grey.shade400,
                                                  size: 32,
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '点击选择封面',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.grey.shade500,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Stack(
                                              fit: StackFit.expand,
                                              children: <Widget>[
                                                Image.file(
                                                  File(_detailCoverPhoto!.path),
                                                  fit: BoxFit.cover,
                                                ),
                                                Positioned(
                                                  top: 8,
                                                  right: 8,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      setState(() {
                                                        _detailCoverPhoto = null;
                                                        _errorMessage = null;
                                                      });
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(6),
                                                      decoration: const BoxDecoration(
                                                        color: Colors.black54,
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: const Icon(
                                                        Icons.close,
                                                        size: 14,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade50,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Colors.grey.shade200),
                                    ),
                                    child: TextField(
                                      controller: _destinationController,
                                      maxLines: 4,
                                      onChanged: (String _) {
                                        if (_errorMessage != null) {
                                          setState(() => _errorMessage = null);
                                        }
                                      },
                                      decoration: const InputDecoration(
                                        hintText:
                                            '详细聊聊行程吧...\n例如：\nDay1: 抵达大理，逛古城\nDay2: 租车环绕洱海，看了双廊的日落\n(AI 将根据您的描述搭建精准的时间轴)',
                                        hintStyle: TextStyle(
                                          fontSize: 13,
                                          color: Colors.black38,
                                          height: 1.5,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                              const SizedBox(height: 24),
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  childAspectRatio: 3.2,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                ),
                                itemCount: diaryStyles.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final Map<String, String> style = diaryStyles[index];
                                  final bool isSelected =
                                      _selectedStyle == style['name'];
                                  return GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _selectedStyle = style['name']!;
                                      });
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.green.shade50
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isSelected
                                              ? Colors.green.shade400
                                              : Colors.grey.shade200,
                                          width: isSelected ? 1.5 : 1.0,
                                        ),
                                        boxShadow: isSelected
                                            ? <BoxShadow>[]
                                            : <BoxShadow>[
                                                BoxShadow(
                                                  color: Colors.black.withValues(alpha: 0.01),
                                                  blurRadius: 4,
                                                ),
                                              ],
                                      ),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: <Widget>[
                                          Text(
                                            style['icon']!,
                                            style: const TextStyle(fontSize: 16),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            style['name']!,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: isSelected
                                                  ? FontWeight.bold
                                                  : FontWeight.w600,
                                              color: isSelected
                                                  ? Colors.green.shade700
                                                  : Colors.grey.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 40),
                            ],
                          ),
                        ),
                      ),
                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              const Icon(
                                Icons.error_outline,
                                color: Colors.redAccent,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 10,
                              offset: const Offset(0, -4),
                            ),
                          ],
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo.shade600,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 0,
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: _isGenerating ||
                                    (!_isCustomMode &&
                                        _selectedItineraryId == null)
                                ? null
                                : _onGenerate,
                            child: Ink(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: <Color>[
                                    Colors.indigo.shade500,
                                    Colors.purple.shade500,
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    Icon(
                                      Icons.auto_awesome,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      '✨ AI 一键生成手账',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_isGenerating)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(24),
                          topRight: Radius.circular(24),
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            color: Colors.white.withValues(alpha: 0.7),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                const SizedBox(
                                  width: 50,
                                  height: 50,
                                  child: CircularProgressIndicator(
                                    color: Colors.indigo,
                                    strokeWidth: 3,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  "AI 正在用『$_selectedStyle』风格\n为您排版回忆...",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.indigo.shade700,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
  } // end build
} // end _DiaryConfigSheetContentState

String _extractDestination(ItineraryModel? itinerary) {
  if (itinerary == null) return '未知';
  final Map<String, dynamic> plan = itinerary.planData;
  final String destination =
      (plan['destinationCity'] ?? plan['destination'] ?? plan['city'] ?? '')
          .toString()
          .trim();
  if (destination.isNotEmpty) return destination;
  return itinerary.title.trim().isNotEmpty ? itinerary.title.trim() : '未知';
}

String _extractCoverImage(ItineraryModel? itinerary) {
  if (itinerary != null) {
    final Map<String, dynamic> plan = itinerary.planData;
    final List<String> candidates = <String>[
      (plan['coverImageUrl'] ?? '').toString(),
      (plan['cover_image_url'] ?? '').toString(),
      (plan['cover'] ?? '').toString(),
      (plan['coverUrl'] ?? '').toString(),
    ];
    for (final String value in candidates) {
      if (value.trim().isNotEmpty) return value.trim();
    }
  }
  return 'https://images.unsplash.com/photo-1596484552834-6a58f850d0a1?w=800';
}