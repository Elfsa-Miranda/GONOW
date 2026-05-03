import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:gonow/core/constants/ai_config.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:gonow/core/utils/image_compress_util.dart';
import 'package:gonow/features/common/presentation/widgets/full_screen_photo_gallery.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class DiaryDetailScreen extends StatefulWidget {
  const DiaryDetailScreen({
    required this.initialDiary,
    this.startEditing = false,
    super.key,
  });

  final DiaryModel initialDiary;
  final bool startEditing;

  @override
  State<DiaryDetailScreen> createState() => _DiaryDetailScreenState();
}

class _DiaryDetailScreenState extends State<DiaryDetailScreen>
    with SingleTickerProviderStateMixin {
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _quoteController = TextEditingController();
  final TextEditingController _sheetInputController = TextEditingController();

  late DiaryModel _diary = widget.initialDiary;
  late String _editableCoverImageUrl = widget.initialDiary.coverImageUrl;
  late Map<String, dynamic> _editableData = _normalizeEditableData(
    Map<String, dynamic>.from(widget.initialDiary.diaryData),
  );
  late List<_TimelineNode> _nodes = _buildNodes(_editableData);
  late bool _isEditing = widget.startEditing;
  bool _publishToCommunity = false;
  int _contentVersion = 0;
  String _snapshotDataStr = '';
  String _snapshotTitle = '';
  String _snapshotCoverImageUrl = '';

  late final AnimationController _pulseController;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _titleController.text = _diary.title;
    _quoteController.text = (_diary.diaryData['quote'] ?? '').toString();
    _publishToCommunity = _diary.isPublic;
    if (_isEditing) {
      _captureEditSnapshot();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _quoteController.dispose();
    _sheetInputController.dispose();
    _pulseController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _isPlaceholderText(String value) {
    const Set<String> placeholders = <String>{
      '未命名景点',
      '这段旅程还没有补充描述',
      '新增景点待补充描述',
      '新增景点待补充描述...',
      '新的记录点',
      '记录这一天的精彩瞬间',
      '这一天，我们在路上...',
      '新的一天开始了...',
    };
    return placeholders.contains(value.trim());
  }

  String _realOrEmpty(dynamic raw) {
    final String value = (raw ?? '').toString().trim();
    if (value.isEmpty || _isPlaceholderText(value)) return '';
    return value;
  }

  /// 兼容历史数据：`images` / `photos` / `imageUrl` / `image_url`，去重。
  List<String> _collectActivityDisplayImages(Map<String, dynamic> item) {
    final List<String> displayImages = <String>[];
    if (item['images'] != null && item['images'] is List) {
      displayImages.addAll(
        List<String>.from(
          (item['images'] as List<dynamic>).map((dynamic e) => e.toString().trim()),
        ).where((String e) => e.isNotEmpty),
      );
    }
    if (item['photos'] != null && item['photos'] is List) {
      displayImages.addAll(
        List<String>.from(
          (item['photos'] as List<dynamic>).map((dynamic e) => e.toString().trim()),
        ).where((String e) => e.isNotEmpty),
      );
    }
    final String imageUrl =
        (item['imageUrl'] ?? item['image_url'] ?? '').toString().trim();
    if (displayImages.isEmpty && imageUrl.isNotEmpty) {
      displayImages.add(imageUrl);
    }
    return displayImages.toSet().toList();
  }

  void _handleDeletePhoto(int dIdx, int aIdx, String urlToRemove) {
    final List<dynamic> days =
        (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (dIdx < 0 || dIdx >= days.length) return;
    final Map<String, dynamic> day = days[dIdx] as Map<String, dynamic>;
    final List<dynamic> activities = day['activities'] as List<dynamic>? ?? <dynamic>[];
    if (aIdx < 0 || aIdx >= activities.length) return;
    final Map<String, dynamic> item =
        activities[aIdx] as Map<String, dynamic>? ?? <String, dynamic>{};
    final String url = urlToRemove.trim();
    if (url.isEmpty) return;

    for (final String key in <String>['photos', 'images']) {
      final Object? raw = item[key];
      if (raw is List<dynamic>) {
        final List<dynamic> list = List<dynamic>.from(raw);
        list.removeWhere((dynamic e) => e.toString().trim() == url);
        item[key] = list;
      }
    }
    if ((item['imageUrl'] ?? '').toString().trim() == url) {
      item['imageUrl'] = '';
    }
    if ((item['image_url'] ?? '').toString().trim() == url) {
      item['image_url'] = '';
    }
    item['photos'] = _collectActivityDisplayImages(item);
    setState(() {
      _refreshFromEditableData();
      _contentVersion++;
    });
  }

  Future<void> _pickAndUploadImage(int dIdx, int aIdx, String _) async {
    final int nodeIndex =
        _nodes.indexWhere((_TimelineNode n) => n.dIdx == dIdx && n.aIdx == aIdx);
    if (nodeIndex < 0) return;
    await _addPhoto(nodeIndex);
  }

  Map<String, dynamic> _normalizeEditableData(Map<String, dynamic> data) {
    final List<dynamic> rawDays = (data['days'] as List<dynamic>?) ?? <dynamic>[];
    final List<Map<String, dynamic>> normalizedDays = <Map<String, dynamic>>[];
    for (int i = 0; i < rawDays.length; i++) {
      final Map<String, dynamic> day =
          rawDays[i] as Map<String, dynamic>? ?? <String, dynamic>{};
      final int dayNo = (day['day'] as num?)?.toInt() ?? i + 1;
      final List<dynamic>? rawActivities = day['activities'] as List<dynamic>?;
      final List<Map<String, dynamic>> activities = <Map<String, dynamic>>[];
      if (rawActivities != null && rawActivities.isNotEmpty) {
        for (final dynamic act in rawActivities) {
          final Map<String, dynamic> a =
              act as Map<String, dynamic>? ?? <String, dynamic>{};
          final List<String> mergedPhotos = _collectActivityDisplayImages(a);
          activities.add(<String, dynamic>{
            'title': _realOrEmpty(a['title']),
            'time': (a['time'] ?? '').toString(),
            'description': _realOrEmpty(a['description']),
            'lat': (a['lat'] as num?)?.toDouble() ?? 0,
            'lng': (a['lng'] as num?)?.toDouble() ?? 0,
            'photos': mergedPhotos,
            if (_isLazyPoolActivity(a)) 'is_lazy_pool': true,
            if (a['tag'] != null) 'tag': a['tag'],
            if (a['recommended_duration'] != null)
              'recommended_duration': a['recommended_duration'],
            if (a['images'] != null) 'images': a['images'],
            if (a['imageUrl'] != null) 'imageUrl': a['imageUrl'],
            if (a['image_url'] != null) 'image_url': a['image_url'],
          });
        }
      } else {
        activities.add(<String, dynamic>{
          'title': _realOrEmpty(day['title']),
          'time': (day['time'] ?? '').toString(),
          'description': _realOrEmpty(day['description']),
          'lat': (day['lat'] as num?)?.toDouble() ?? 0,
          'lng': (day['lng'] as num?)?.toDouble() ?? 0,
          'photos': ((day['photos'] as List<dynamic>?) ?? <dynamic>[])
              .map((dynamic e) => e.toString())
              .where((String e) => e.isNotEmpty)
              .toList(growable: false),
        });
      }
      final Map<String, dynamic> normalizedDay = <String, dynamic>{
        'day': dayNo,
        'activities': activities,
      };
      if (day.containsKey('summary')) {
        normalizedDay['summary'] = day['summary'];
      }
      if (day.containsKey('dayTitle')) {
        normalizedDay['dayTitle'] = day['dayTitle'];
      }
      normalizedDays.add(normalizedDay);
    }
    return <String, dynamic>{
      ...data,
      'days': normalizedDays,
    };
  }

  List<_TimelineNode> _buildNodes(Map<String, dynamic> editableData) {
    final List<dynamic> rawDays =
        (editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    final List<_TimelineNode> nodes = <_TimelineNode>[];
    for (int dIdx = 0; dIdx < rawDays.length; dIdx++) {
      final Map<String, dynamic> day =
          rawDays[dIdx] as Map<String, dynamic>? ?? <String, dynamic>{};
      final int dayNo = (day['day'] as num?)?.toInt() ?? dIdx + 1;
      final List<dynamic> activities =
          (day['activities'] as List<dynamic>?) ?? <dynamic>[];
      for (int aIdx = 0; aIdx < activities.length; aIdx++) {
        final Map<String, dynamic> item =
            activities[aIdx] as Map<String, dynamic>? ?? <String, dynamic>{};
        nodes.add(
          _TimelineNode(
            day: dayNo,
            dIdx: dIdx,
            aIdx: aIdx,
            title: _realOrEmpty(item['title']),
            time: (item['time'] ?? '').toString(),
            description: _realOrEmpty(item['description']),
            lat: (item['lat'] as num?)?.toDouble() ?? 0,
            lng: (item['lng'] as num?)?.toDouble() ?? 0,
            photos: _collectActivityDisplayImages(item),
          ),
        );
      }
    }
    return nodes;
  }

  void _refreshFromEditableData() {
    _nodes = _buildNodes(_editableData);
  }

  Map<String, dynamic> _activityMapForTimelineIndex(int index) {
    final _TimelineNode n = _nodes[index];
    final List<dynamic> days =
        (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> day = days[n.dIdx] as Map<String, dynamic>;
    final List<dynamic> acts = day['activities'] as List<dynamic>;
    return acts[n.aIdx] as Map<String, dynamic>;
  }

  /// 懒人照片池：兼容字符串布尔与标题「记忆碎片」兜底。
  bool _isLazyPoolActivity(Map<String, dynamic> item) {
    if (item['is_lazy_pool'] == true) return true;
    final String f = item['is_lazy_pool']?.toString().toLowerCase() ?? '';
    if (f == 'true' || f == '1') return true;
    return (item['title'] ?? '').toString().contains('记忆碎片');
  }

  /// 该「天」以懒人池首条活动呈现时，隐藏 DAY N 头部，避免刻板时间轴感。
  bool _isLazyPoolDay(int dIdx) {
    final List<dynamic>? days = _editableData['days'] as List<dynamic>?;
    if (days == null || dIdx < 0 || dIdx >= days.length) return false;
    final Map<String, dynamic>? day =
        days[dIdx] as Map<String, dynamic>?;
    final List<dynamic>? acts = day?['activities'] as List<dynamic>?;
    if (acts == null || acts.isEmpty) return false;
    final Map<String, dynamic>? first =
        acts.first as Map<String, dynamic>?;
    if (first == null) return false;
    return _isLazyPoolActivity(first);
  }

  /// 当前手账是否为懒人池（以首日首条活动为准）。
  bool _isLazyPoolDiaryFromEditable() {
    return _isLazyPoolDay(0);
  }

  bool _hasLazyPoolPreviewText(Map<String, dynamic> item) {
    final String desc = (item['description'] ?? '').toString().trim();
    if (desc.isEmpty ||
        desc.contains('新增景点待补充') ||
        desc.contains('AI润色') ||
        desc.contains('一键优化文案') ||
        _isDummyDescriptionContent(desc)) {
      return false;
    }
    return true;
  }

  /// 懒人池散文区：编辑态 TextField + 润色；预览态纯文本。
  Widget _buildLazyPoolDescriptionArea(
    _TimelineNode node,
    Map<String, dynamic> item,
  ) {
    if (_isEditing) {
      return Builder(
        builder: (BuildContext context) {
          String realDesc =
              (item['description'] ?? '').toString().trim();
          if (realDesc.contains('新增景点待补充') ||
              realDesc.contains('AI润色') ||
              realDesc.contains('一键优化文案') ||
              _isDummyDescriptionContent(realDesc)) {
            realDesc = '';
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextFormField(
                  key: ValueKey<String>(
                    'desc_lazy_${node.dIdx}_${node.aIdx}',
                  ),
                  initialValue: realDesc,
                  maxLines: null,
                  decoration: const InputDecoration(
                    hintText: '写下这段回忆的散文或随笔…',
                    hintStyle: TextStyle(
                      color: Colors.black38,
                      fontSize: 14,
                    ),
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade800,
                    height: 1.75,
                  ),
                  onChanged: (String val) {
                    item['description'] = val;
                    setState(() {
                      _refreshFromEditableData();
                      _contentVersion++;
                    });
                  },
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.auto_awesome,
                  color: Colors.indigo,
                  size: 22,
                ),
                onPressed: () {
                  _openAiCopilotPanel(
                    targetKey: 'desc_${node.dIdx}_${node.aIdx}',
                    originalText: realDesc,
                  );
                },
                tooltip: 'AI一键润色',
              ),
            ],
          );
        },
      );
    }
    return Builder(
      builder: (BuildContext context) {
        final String desc =
            (item['description'] ?? '').toString().trim();
        if (!_hasLazyPoolPreviewText(item)) {
          return const SizedBox.shrink();
        }
        return Text(
          _dedupeDescriptionParagraphs(desc),
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade800,
            height: 1.85,
          ),
        );
      },
    );
  }

  /// 标准时间轴节点白卡片（标题、时间、横向相册、描述）；外层再包 [ReorderableDelayedDragStartListener]。
  Widget _buildStandardTimelineMainCard(
    BuildContext context,
    int index,
    _TimelineNode node,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Builder(
            builder: (BuildContext context) {
              final String timeStr = node.time.trim();
              final bool isRealTime = _looksLikeTimeLabel(timeStr);
              final String titleLine = _displayNodeTitleLine(node);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (isRealTime)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _isEditing
                          ? () => _pickAndSaveActivityTime(index)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          timeStr,
                          style: TextStyle(
                            color: Colors.indigo.shade600,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: _editableWrap(
                      onTap: () => _showNodeEditDialog(
                        index: index,
                        title: '编辑节点标题',
                        field: _NodeField.title,
                        initial: node.title,
                      ),
                      child: Text(
                        titleLine,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (BuildContext context) {
              final List<dynamic> days =
                  (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
              if (node.dIdx < 0 || node.dIdx >= days.length) {
                return const SizedBox.shrink();
              }
              final Map<String, dynamic> day =
                  days[node.dIdx] as Map<String, dynamic>? ?? <String, dynamic>{};
              final List<dynamic> activities =
                  (day['activities'] as List<dynamic>?) ?? <dynamic>[];
              if (node.aIdx < 0 || node.aIdx >= activities.length) {
                return const SizedBox.shrink();
              }
              final Map<String, dynamic> item =
                  activities[node.aIdx] as Map<String, dynamic>? ??
                  <String, dynamic>{};
              final List<String> displayImages =
                  _collectActivityDisplayImages(item);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (displayImages.isNotEmpty || _isEditing)
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 8),
                      child: SizedBox(
                        height: 160,
                        child: _buildPhotoGallery(
                          item,
                          node.dIdx,
                          node.aIdx,
                        ),
                      ),
                    ),
                  if (_isEditing)
                    Builder(
                      builder: (BuildContext context) {
                        String realDesc =
                            (item['description'] ?? '').toString().trim();
                        if (realDesc.contains('新增景点待补充') ||
                            realDesc.contains('AI润色') ||
                            realDesc.contains('一键优化文案') ||
                            _isDummyDescriptionContent(realDesc)) {
                          realDesc = '';
                        }
                        return Container(
                          margin: const EdgeInsets.only(top: 4, bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.indigo.shade100,
                              style: BorderStyle.solid,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: TextFormField(
                                  key: ValueKey<String>(
                                    'desc_${node.dIdx}_${node.aIdx}',
                                  ),
                                  initialValue: realDesc,
                                  maxLines: null,
                                  decoration: const InputDecoration(
                                    hintText: '新增景点待补充描述...',
                                    hintStyle: TextStyle(
                                      color: Colors.black38,
                                      fontSize: 13,
                                    ),
                                    contentPadding: EdgeInsets.all(12),
                                    border: InputBorder.none,
                                  ),
                                  onChanged: (String val) {
                                    item['description'] = val;
                                    setState(() {
                                      _refreshFromEditableData();
                                      _contentVersion++;
                                    });
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.auto_awesome,
                                  color: Colors.indigo,
                                  size: 20,
                                ),
                                onPressed: () {
                                  _openAiCopilotPanel(
                                    targetKey: 'desc_${node.dIdx}_${node.aIdx}',
                                    originalText: realDesc,
                                  );
                                },
                                tooltip: 'AI一键润色',
                              ),
                            ],
                          ),
                        );
                      },
                    )
                  else
                    Builder(
                      builder: (BuildContext context) {
                        final String desc =
                            (item['description'] ?? '').toString().trim();
                        if (desc.isEmpty ||
                            desc.contains('新增景点待补充') ||
                            desc.contains('AI润色') ||
                            desc.contains('一键优化文案') ||
                            _isDummyDescriptionContent(desc)) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 4),
                          child: Text(
                            _dedupeDescriptionParagraphs(desc),
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF475569),
                              height: 1.5,
                            ),
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 无时间轴圆点/竖线的沉浸式懒人池：预览态 Masonry 瀑布流；编辑态 ReorderableGrid 调序；评论区长按拖整条。
  Widget _buildLazyPoolTimelineItem(
    BuildContext context,
    int index,
    _TimelineNode node,
    Map<String, dynamic> item, {
    required int reorderIndex,
  }) {
    final List<String> images = List<String>.from(
      _collectActivityDisplayImages(item),
    );
    final bool showDescRail = _isEditing || _hasLazyPoolPreviewText(item);

    final Widget commentArea = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.indigo.withValues(alpha: 0.08),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.format_quote_rounded,
                color: Colors.indigo.shade200,
                size: 20,
              ),
              const SizedBox(width: 8),
              if (_isEditing)
                Text(
                  '长按此处可拖动整个照片池',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.indigo.shade300,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _buildLazyPoolDescriptionArea(node, item),
        ],
      ),
    );

    late final Widget galleryWidget;
    if (!_isEditing) {
      // ── 预览态：无边框沉浸式瀑布流 ──
      galleryWidget = MasonryGridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: images.length,
        itemBuilder: (BuildContext context, int imgIndex) {
          // 「微错落」算法：基准 160px，每张图在 ±30px 内克制偏移
          // 奇偶列各自有一个轻微相位差，左右高度差始终 ≤ 50px，整体均衡美观
          const List<double> _offsetPattern = <double>[0, 30, -20, 20, -30, 10];
          final double baseHeight = 160.0;
          final double cardHeight =
              baseHeight + _offsetPattern[imgIndex % _offsetPattern.length];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showFullScreenGallery(
              context,
              images,
              imgIndex,
            ),
            child: Container(
              height: cardHeight,
              // 彻底去除白底和内边距，图片直接撑满容器
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: double.infinity,
                  height: double.infinity,
                  child: _buildNodeImage(images[imgIndex]),
                ),
              ),
            ),
          );
        },
      );
    } else {
      // ── 编辑态：与预览态完全一致的瀑布流 + 删除角标 ──
      const List<double> _editOffsetPattern = <double>[0, 30, -20, 20, -30, 10];
      final int totalItems = images.length + 1;
      galleryWidget = MasonryGridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: totalItems,
        itemBuilder: (BuildContext context, int imgIndex) {
          // 「添加照片」卡片
          if (imgIndex == images.length) {
            return GestureDetector(
              key: ValueKey<String>('lazy_add_${node.dIdx}_${node.aIdx}'),
              onTap: () => _pickAndUploadImage(
                node.dIdx,
                node.aIdx,
                (item['title'] ?? '记忆碎片').toString(),
              ),
              child: Container(
                height: 160.0,
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.grey.shade300,
                    style: BorderStyle.solid,
                    width: 2,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.add_a_photo_rounded,
                      color: Colors.grey.shade400,
                      size: 28,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '添加照片',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // 与预览态完全相同的高度算法
          final double cardHeight =
              160.0 + _editOffsetPattern[imgIndex % _editOffsetPattern.length];

          return Stack(
            key: ValueKey<String>(
              'lazy_photo_${node.dIdx}_${node.aIdx}_${images[imgIndex]}_$imgIndex',
            ),
            clipBehavior: Clip.none,
            children: <Widget>[
              // 照片卡片：与预览态完全一致，无白边
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showFullScreenGallery(
                  context,
                  images,
                  imgIndex,
                ),
                child: Container(
                  height: cardHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: double.infinity,
                      height: double.infinity,
                      child: _buildNodeImage(images[imgIndex]),
                    ),
                  ),
                ),
              ),
              // 删除角标（浮在图片右上角内侧）
              Positioned(
                top: 6,
                right: 6,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _handleDeletePhoto(
                    node.dIdx,
                    node.aIdx,
                    images[imgIndex],
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(5),
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
          );
        },
      );
    }

    final Widget bodyColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (images.isNotEmpty || _isEditing)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: galleryWidget,
          ),
        if (showDescRail)
          _isEditing
              ? ReorderableDelayedDragStartListener(
                  index: reorderIndex,
                  child: commentArea,
                )
              : commentArea,
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, bottom: 40),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          bodyColumn,
          if (_isEditing)
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmDeleteActivity(node),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.red.shade100),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Colors.black12, blurRadius: 4),
                    ],
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.red),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _onTimelineReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      _applyTimelineReorder(oldIndex, newIndex);
      _contentVersion++;
    });
  }

  /// 全局顺序重排后，按「各天活动数量不变」将扁平列表重新切回 days[].activities。
  void _applyTimelineReorder(int oldIndex, int newIndex) {
    final List<dynamic> days =
        (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (days.isEmpty) return;

    final List<int> sizes = <int>[];
    for (final dynamic d in days) {
      final Map<String, dynamic> day = d as Map<String, dynamic>;
      final List<dynamic>? acts = day['activities'] as List<dynamic>?;
      sizes.add(acts?.length ?? 0);
    }
    final int total = sizes.fold<int>(0, (int a, int b) => a + b);
    if (total != _nodes.length ||
        oldIndex < 0 ||
        oldIndex >= total ||
        newIndex < 0 ||
        newIndex >= total) {
      return;
    }

    final List<Map<String, dynamic>> flat = <Map<String, dynamic>>[];
    for (final _TimelineNode n in _nodes) {
      final Map<String, dynamic> day = days[n.dIdx] as Map<String, dynamic>;
      final List<dynamic> acts = day['activities'] as List<dynamic>;
      flat.add(acts[n.aIdx] as Map<String, dynamic>);
    }

    final Map<String, dynamic> moved = flat.removeAt(oldIndex);
    flat.insert(newIndex, moved);

    int offset = 0;
    for (int dIdx = 0; dIdx < days.length; dIdx++) {
      final Map<String, dynamic> day = Map<String, dynamic>.from(
        days[dIdx] as Map<String, dynamic>,
      );
      final int sz = sizes[dIdx];
      final List<Map<String, dynamic>> chunk =
          List<Map<String, dynamic>>.from(flat.sublist(offset, offset + sz));
      day['activities'] = chunk;
      days[dIdx] = day;
      offset += sz;
    }
    _editableData['days'] = days;
    _refreshFromEditableData();
  }

  Widget _timelineReorderProxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) {
        final double t = Curves.easeOut.transform(animation.value);
        return Material(
          elevation: 10 * t,
          shadowColor: Colors.black45,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          color: Colors.transparent,
          child: child,
        );
      },
      child: child,
    );
  }

  Future<void> _persist({required bool asDraft}) async {
    final DiaryProvider provider = context.read<DiaryProvider>();
    final String finalQuote =
        (_editableData['quote'] ?? _quoteController.text).toString().trim();
    final Map<String, dynamic> updatedData = <String, dynamic>{
      ..._editableData,
      'quote': finalQuote,
      'days': _editableData['days'],
      'updatedAt': DateTime.now().toIso8601String(),
    };
    final DiaryModel updated = _diary.copyWith(
      title: _titleController.text.trim().isEmpty
          ? '未命名手账'
          : _titleController.text.trim(),
      coverImageUrl: _editableCoverImageUrl.trim().isEmpty
          ? _diary.coverImageUrl
          : _editableCoverImageUrl.trim(),
      isDraft: asDraft,
      isPublic: asDraft ? false : _publishToCommunity,
      diaryData: updatedData,
    );
    await provider.saveDiary(updated);
    _diary = updated;
    _editableCoverImageUrl = updated.coverImageUrl;
    _captureEditSnapshot();
  }

  static const Duration _editSnackDuration = Duration(milliseconds: 1500);

  /// 编辑页统一短提示（1.5s、中等灰底）。「相册多选」提示请勿使用本方法。
  SnackBar _editSnackBar(String message) {
    return SnackBar(
      content: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF1F2937),
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      duration: _editSnackDuration,
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFFCBD5E1),
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  void _showEditSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(_editSnackBar(message));
  }

  void _captureEditSnapshot() {
    _snapshotTitle = _titleController.text.trim();
    _snapshotDataStr = jsonEncode(_editableData);
    _snapshotCoverImageUrl = _editableCoverImageUrl.trim();
  }

  /// 脏数据检测：仅在确有改动时才需要返回确认弹窗。
  bool _hasUnsavedChanges() {
    if (_titleController.text.trim() != _snapshotTitle) {
      return true;
    }

    if (jsonEncode(_editableData) != _snapshotDataStr) {
      return true;
    }
    if (_editableCoverImageUrl.trim() != _snapshotCoverImageUrl) {
      return true;
    }

    return false;
  }

  Future<void> _pickAndReplaceCover() async {
    FocusScope.of(context).unfocus();
    List<XFile> picked = <XFile>[];
    try {
      picked = await _imagePicker.pickMultiImage(limit: 1);
    } catch (_) {
      final XFile? single = await _imagePicker.pickImage(
        source: ImageSource.gallery,
      );
      if (single != null) picked = <XFile>[single];
    }
    if (picked.isEmpty) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在上传新封面...'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    final DiaryProvider provider = context.read<DiaryProvider>();
    final String localPath = picked.first.path;
    final String? uploadedUrl = await provider.uploadDiaryCoverImage(localPath);
    if (!mounted) return;

    setState(() {
      _editableCoverImageUrl = (uploadedUrl ?? localPath).trim();
      _contentVersion++;
    });
    _showEditSnackBar(uploadedUrl == null ? '已替换封面（本地）' : '封面已更新');
  }

  Widget _buildSmartCoverImage(String pathOrUrl) {
    final String p = pathOrUrl.trim();
    if (p.isEmpty) {
      return Container(color: Colors.blueGrey.shade800);
    }
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: p,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(color: Colors.blueGrey.shade800),
      );
    }
    if (p.startsWith('blob:') || kIsWeb) {
      return Image.network(
        p,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(color: Colors.blueGrey.shade800),
      );
    }
    return Image.file(
      File(p),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(color: Colors.blueGrey.shade800),
    );
  }

  Future<bool> _onPressBack() async {
    if (!_isEditing) {
      if (mounted) Navigator.of(context).pop();
      return true;
    }

    if (!_hasUnsavedChanges()) {
      if (mounted) Navigator.of(context).pop();
      return true;
    }

    final bool? shouldSave = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text(
          '保存修改？',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '您正在编辑中，直接退出将丢失未保存的改动。是否保存当前改动？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('丢弃改动', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '保存改动',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.indigo.shade600,
              ),
            ),
          ),
        ],
      ),
    );

    if (shouldSave == null) return false;

    if (shouldSave) {
      await _persist(asDraft: _diary.isDraft);
      if (!mounted) return false;

      _showEditSnackBar('✅ 改动已保存');
      Navigator.of(context).pop();
      return true;
    } else {
      if (!mounted) return false;
      Navigator.of(context).pop();
      return true;
    }
  }

  Future<void> _toggleEditing() async {
    if (_isEditing) {
      await _persist(asDraft: true);
      if (!mounted) return;

      _showEditSnackBar('✅ 已安全保存至草稿箱');

      setState(() => _isEditing = false);
      return;
    }

    setState(() {
      _captureEditSnapshot();
      _isEditing = true;
    });
  }

  Future<void> _addPhoto(int nodeIndex) async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();

    if (nodeIndex < 0 || nodeIndex >= _nodes.length) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('💡 提示：在相册中长按图片即可进行多选'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    List<XFile> picked = <XFile>[];
    try {
      picked = await _imagePicker.pickMultiImage(
        imageQuality: 88,
        maxWidth: 1800,
      );
    } catch (e, st) {
      debugPrint('pickMultiImage failed: $e\n$st');
      try {
        final XFile? one = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 88,
          maxWidth: 1800,
        );
        if (one != null) picked = <XFile>[one];
      } catch (e2, st2) {
        debugPrint('pickImage fallback failed: $e2\n$st2');
        if (mounted) {
          _showEditSnackBar('无法打开相册，请检查系统权限或稍后重试');
        }
        return;
      }
    }

    if (picked.isEmpty) return;

    if (!kIsWeb) {
      picked = await ImageCompressUtil.compressImages(picked);
    }
    if (!mounted) return;

    final _TimelineNode node = _nodes[nodeIndex];
    final List<dynamic> days =
        (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (node.dIdx < 0 || node.dIdx >= days.length) return;
    final Map<String, dynamic> day = days[node.dIdx] as Map<String, dynamic>;
    final List<dynamic> activities = day['activities'] as List<dynamic>;
    if (node.aIdx < 0 || node.aIdx >= activities.length) return;
    final Map<String, dynamic> item =
        activities[node.aIdx] as Map<String, dynamic>;

    final List<String> existing = _collectActivityDisplayImages(item).toList(growable: true);

    final List<String> newPaths = <String>[];
    for (final XFile x in picked) {
      final String p = x.path.trim();
      if (p.isNotEmpty) newPaths.add(p);
    }
    if (newPaths.isEmpty) {
      if (mounted) {
        _showEditSnackBar(
          kIsWeb
              ? '未能读取所选图片，请重试或换用其它浏览器'
              : '未能读取所选图片路径，请重试',
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      existing.addAll(newPaths);
      item['photos'] = existing;
      _refreshFromEditableData();
      _contentVersion++;
    });

    if (mounted && newPaths.length > 1) {
      _showEditSnackBar('已添加 ${newPaths.length} 张图片');
    }
  }

  Future<void> _confirmDeleteActivity(_TimelineNode node) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('确认删除'),
          content: const Text('确定要删除这个行程节点吗？此操作不可恢复。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                '删除',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await _deleteActivity(node.dIdx, node.aIdx);
  }

  Future<void> _deleteActivity(int dIdx, int aIdx) async {
    final List<dynamic> days = (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (dIdx < 0 || dIdx >= days.length) return;
    final Map<String, dynamic> day = days[dIdx] as Map<String, dynamic>;
    final List<dynamic> activities = day['activities'] as List<dynamic>? ?? <dynamic>[];
    if (aIdx < 0 || aIdx >= activities.length) return;
    setState(() {
      activities.removeAt(aIdx);
      if (activities.isEmpty) {
        days.removeAt(dIdx);
        for (int i = 0; i < days.length; i++) {
          final Map<String, dynamic> currentDay =
              days[i] as Map<String, dynamic>;
          currentDay['day'] = i + 1;
        }
      } else {
        day['activities'] = activities;
      }
      _editableData['days'] = days;
      _refreshFromEditableData();
      _contentVersion++;
    });
  }

  Future<void> _insertActivityAfter(_TimelineNode node) async {
    FocusScope.of(context).unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return _InsertNodeBottomSheet(
          onConfirm: (String title, String time) {
            final List<dynamic> days =
                (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
            final Map<String, dynamic> day =
                days[node.dIdx] as Map<String, dynamic>;
            final List<dynamic> activities = day['activities'] as List<dynamic>;
            activities.insert(node.aIdx + 1, <String, dynamic>{
              'title': title,
              'time': time,
              'description': '',
              'lat': 0.0,
              'lng': 0.0,
              'photos': <String>[],
            });
            day['activities'] = activities;
            setState(() {
              _refreshFromEditableData();
              _contentVersion++;
            });
          },
          onPickTime: _pickTimeIntoController,
        );
      },
    );
  }

  void _handleAiTextUpdate(String targetKey, String newText) {
    setState(() {
      if (targetKey == 'quote') {
        _quoteController.text = newText;
        _editableData['quote'] = newText;
      } else if (targetKey.startsWith('desc_')) {
        final List<String> parts = targetKey.split('_');
        if (parts.length == 3) {
          final int? dIdx = int.tryParse(parts[1]);
          final int? aIdx = int.tryParse(parts[2]);
          if (dIdx != null && aIdx != null) {
            final List<dynamic> days =
                (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
            if (dIdx >= 0 &&
                dIdx < days.length &&
                days[dIdx] is Map<String, dynamic>) {
              final Map<String, dynamic> day =
                  days[dIdx] as Map<String, dynamic>;
              final List<dynamic> activities =
                  day['activities'] as List<dynamic>? ?? <dynamic>[];
              if (aIdx >= 0 &&
                  aIdx < activities.length &&
                  activities[aIdx] is Map<String, dynamic>) {
                final Map<String, dynamic> act =
                    activities[aIdx] as Map<String, dynamic>;
                act['description'] = newText;
              }
            }
          }
        }
      }
      _refreshFromEditableData();
      _contentVersion++;
    });
  }

  void _handleAiStructureUpdate(Map<String, dynamic> newDiaryData) {
    setState(() {
      _editableData = _normalizeEditableData(
        Map<String, dynamic>.from(newDiaryData),
      );
      _quoteController.text = (_editableData['quote'] ?? '').toString();
      _refreshFromEditableData();
      _contentVersion++;
    });
  }

  void _openAiCopilotPanel({
    required String targetKey,
    required String originalText,
  }) {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return _DiaryAiCopilotBottomSheet(
          fullDiaryData: _editableData,
          targetKey: targetKey,
          originalText: originalText,
          onTextUpdate: _handleAiTextUpdate,
          onStructureUpdate: _handleAiStructureUpdate,
        );
      },
    );
  }

  Widget _editableWrap({
    required Widget child,
    required VoidCallback onTap,
  }) {
    if (!_isEditing) return child;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.indigo.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.indigo.withValues(alpha: 0.3),
          ),
        ),
        child: child,
      ),
    );
  }

  String _getDaySummary(int dIdx) {
    final List<dynamic> days = (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (dIdx < 0 || dIdx >= days.length) return '这一天，我们在路上...';
    final Map<String, dynamic> day = days[dIdx] as Map<String, dynamic>;
    return (day['summary'] ?? '这一天，我们在路上...').toString();
  }

  /// 仅用于 UI：短时间且含数字才显示为蓝色「时间」。
  bool _looksLikeTimeLabel(String timeStr) {
    final String s = timeStr.trim();
    if (s.isEmpty || s.length > 8) return false;
    return RegExp(r'[0-9]').hasMatch(s);
  }

  bool _isValid24HourTime(String timeStr) {
    return RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$').hasMatch(timeStr);
  }

  TimeOfDay? _tryParseTimeOfDay(String raw) {
    final String s = raw.trim();
    if (!_isValid24HourTime(s)) return null;
    final List<String> parts = s.split(':');
    final int h = int.parse(parts[0]);
    final int m = int.parse(parts[1]);
    return TimeOfDay(hour: h, minute: m);
  }

  String _formatTimeOfDay24h(TimeOfDay t) {
    final String h = t.hour.toString().padLeft(2, '0');
    final String m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _showCupertinoTimePicker({
    required String initialTime,
    required ValueChanged<String> onConfirm,
  }) async {
    // 🚨 CRITICAL FIX: Drop keyboard focus to prevent rendering crash
    FocusScope.of(context).unfocus();
    
    TimeOfDay selected = _tryParseTimeOfDay(initialTime) ?? TimeOfDay.now();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return AnimatedPadding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
                    child: Row(
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            onConfirm(_formatTimeOfDay24h(selected));
                            Navigator.of(context).pop();
                          },
                          child: const Text(
                            '确定',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 220,
                    child: Localizations.override(
                      context: context,
                      locale: const Locale('zh', 'CN'),
                      child: CupertinoDatePicker(
                        mode: CupertinoDatePickerMode.time,
                        use24hFormat: true,
                        initialDateTime: DateTime(
                          2026,
                          1,
                          1,
                          selected.hour,
                          selected.minute,
                        ),
                        onDateTimeChanged: (DateTime value) {
                          selected = TimeOfDay(
                            hour: value.hour,
                            minute: value.minute,
                          );
                        },
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

  Future<void> _pickTimeIntoController(TextEditingController controller) async {
    await _showCupertinoTimePicker(
      initialTime: controller.text.trim(),
      onConfirm: (String value) {
        controller.text = value;
      },
    );
  }

  Future<void> _pickAndSaveActivityTime(int index) async {
    if (!_isEditing) return;
    final _TimelineNode node = _nodes[index];
    await _showCupertinoTimePicker(
      initialTime: node.time.trim(),
      onConfirm: (String formatted) {
        final List<dynamic> days =
            (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
        final Map<String, dynamic> day =
            days[node.dIdx] as Map<String, dynamic>;
        final List<dynamic> activities = day['activities'] as List<dynamic>;
        final Map<String, dynamic> activity =
            activities[node.aIdx] as Map<String, dynamic>;
        setState(() {
          activity['time'] = formatted;
          _refreshFromEditableData();
          _contentVersion++;
        });
      },
    );
  }

  /// 非合法时间字符串合并回标题展示。
  String _displayNodeTitleLine(_TimelineNode node) {
    final String timeStr = node.time.trim();
    final String base =
        node.title.trim().isEmpty ? '路上的瞬间' : node.title.trim();
    if (_looksLikeTimeLabel(timeStr)) return base;
    if (timeStr.isNotEmpty) return '$timeStr$base';
    return base;
  }

  /// 去掉连续重复段落（多次 AI 润色可能追加相同块）。
  String _dedupeDescriptionParagraphs(String raw) {
    final List<String> parts =
        raw.split(RegExp(r'\n\s*\n', multiLine: true));
    final List<String> out = <String>[];
    String? previous;
    for (final String p in parts) {
      final String t = p.trim();
      if (t.isEmpty) continue;
      if (t == previous) continue;
      previous = t;
      out.add(t);
    }
    return out.join('\n\n');
  }

  /// AI / 模板占位：命中则视为空串，以展示 hint。
  bool _isDummyDescriptionContent(String raw) {
    final String t = raw.trim();
    if (t.isEmpty) return false;
    const List<String> dummyFragments = <String>[
      '新增景点待补充',
      'AI润色',
      '一键优化文案',
      '继续在编辑态补充',
      '这段旅程还没有补充',
      '未命名景点',
      '记录这一天的',
      '从行程自动提炼',
    ];
    for (final String word in dummyFragments) {
      if (t.contains(word)) return true;
    }
    return false;
  }

  Widget _buildQuoteBridgeCard() {
    final String quoteText =
        (_editableData['quote'] ?? _quoteController.text).toString();
    return Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // Flipped large quote watermark
            Positioned(
              top: -15,
              left: -10,
              child: Transform.scale(
                scaleX: -1,
                child: Icon(
                  Icons.format_quote_rounded,
                  size: 64,
                  color: Colors.indigo.withValues(alpha: 0.08),
                ),
              ),
            ),
            // 正文下移，避免与背景装饰引号重叠
            Padding(
              padding: const EdgeInsets.only(top: 32, left: 6),
              child: _isEditing
                  ? Container(
                      margin: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                        color: Colors.indigo.shade50.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.indigo.shade100,
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>('quote_input_key'),
                              initialValue: quoteText,
                              maxLines: null,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade800,
                                height: 1.6,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: const InputDecoration(
                                hintText: '写一段走心的前言引语...',
                                hintStyle: TextStyle(
                                  color: Colors.black38,
                                  fontSize: 13,
                                ),
                                contentPadding: EdgeInsets.all(12),
                                border: InputBorder.none,
                              ),
                              onChanged: (String val) {
                                _editableData['quote'] = val;
                                _quoteController.text = val;
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.auto_awesome,
                              color: Colors.indigo,
                              size: 20,
                            ),
                            tooltip: 'AI一键润色引言',
                            onPressed: () => _openAiCopilotPanel(
                              targetKey: 'quote',
                              originalText:
                                  _editableData['quote']?.toString() ?? '',
                            ),
                          ),
                        ],
                      ),
                    )
                  : Text(
                      quoteText.trim().isNotEmpty
                          ? quoteText.trim()
                          : '每次出发，都是对平淡生活的一次温柔越狱。',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade800,
                        height: 1.6,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ],
        ),
    );
  }

  Future<void> _showDaySummaryEditDialog(int dIdx) async {
    final List<dynamic> days = (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (dIdx < 0 || dIdx >= days.length) return;
    final Map<String, dynamic> day = days[dIdx] as Map<String, dynamic>;
    final TextEditingController controller = TextEditingController(
      text: _realOrEmpty(day['summary']),
    );
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('编辑当天总结'),
          content: TextField(
            controller: controller,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: '这一天，我们在路上...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  day['summary'] = controller.text.trim();
                  _refreshFromEditableData();
                  _contentVersion++;
                });
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        await _onPressBack();
      },
      child: Scaffold(
        backgroundColor: _isEditing
            ? const Color(0xFFF8F9FB)
            : const Color(0xFFF4F6FA),
        body: Stack(
          children: <Widget>[
            CustomScrollView(
              controller: _scrollController,
              slivers: <Widget>[
                // Hero + 引言：引言置于封面下方，不遮盖配图与标题
                SliverToBoxAdapter(
                  child: Column(
                    children: <Widget>[
                      SizedBox(
                        height: 350,
                        width: double.infinity,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            Hero(
                              tag: 'diary_cover_${_diary.id}',
                              child: _buildSmartCoverImage(_editableCoverImageUrl),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: <Color>[
                                    Colors.black.withValues(alpha: 0.8),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                            if (_isEditing)
                              Positioned.fill(
                                child: GestureDetector(
                                  onTap: _pickAndReplaceCover,
                                  child: Container(
                                    color: Colors.black.withValues(alpha: 0.4),
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(24),
                                          border: Border.all(
                                            color: Colors.white.withValues(alpha: 0.5),
                                          ),
                                          boxShadow: <BoxShadow>[
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.1),
                                              blurRadius: 8,
                                            ),
                                          ],
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Icon(
                                              Icons.camera_alt,
                                              color: Colors.white,
                                              size: 18,
                                            ),
                                            SizedBox(width: 8),
                                            Text(
                                              '更换封面图',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              top: MediaQuery.of(context).padding.top + 8,
                              left: 8,
                              child: IconButton(
                                onPressed: () async {
                                  await _onPressBack();
                                },
                                icon: const Icon(
                                  Icons.arrow_back_ios_new_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Positioned(
                              top: MediaQuery.of(context).padding.top + 8,
                              right: 8,
                              child: TextButton.icon(
                                onPressed: _toggleEditing,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.black.withValues(alpha: 0.25),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                icon: Icon(
                                  _isEditing
                                      ? Icons.save_alt_rounded
                                      : Icons.edit_outlined,
                                  size: 18,
                                ),
                                label: Text(
                                  _isEditing ? '存草稿' : '编辑',
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            if (_isEditing)
                              Positioned(
                                top: MediaQuery.of(context).padding.top + 8,
                                right: 120,
                                child: IconButton(
                                  onPressed: () async {
                                    final bool? confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (BuildContext ctx) => AlertDialog(
                                        title: const Text('彻底删除'),
                                        content: const Text(
                                          '确定要销毁整篇手账吗？所有回忆将不可恢复。',
                                        ),
                                        actions: <Widget>[
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, false),
                                            child: const Text('取消'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: const Text(
                                              '确定销毁',
                                              style: TextStyle(
                                                color: Colors.red,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm != true) return;
                                    if (!context.mounted) return;
                                    final ScaffoldMessengerState messenger =
                                        ScaffoldMessenger.of(context);
                                    final DiaryProvider provider =
                                        Provider.of<DiaryProvider>(
                                      context,
                                      listen: false,
                                    );
                                    final bool success =
                                        await provider.deleteDiary(_diary.id);
                                    if (!context.mounted) return;
                                    if (success) {
                                      Navigator.of(context).pop();
                                      messenger.showSnackBar(
                                        _editSnackBar('手账已彻底销毁'),
                                      );
                                    } else {
                                      messenger.showSnackBar(
                                        _editSnackBar(
                                          '销毁失败，请检查网络连接',
                                        ),
                                      );
                                    }
                                  },
                                  style: IconButton.styleFrom(
                                    backgroundColor:
                                        Colors.black.withValues(alpha: 0.25),
                                  ),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    color: Colors.redAccent,
                                    size: 20,
                                  ),
                                  tooltip: '删除手账',
                                ),
                              ),
                            Positioned(
                              bottom: 20,
                              left: 20,
                              right: 20,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  _editableWrap(
                                    onTap: () => _showEditDialog(
                                      title: '编辑手账标题',
                                      controller: _titleController,
                                    ),
                                    child: Text(
                                      _titleController.text,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        color: Colors.white,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: <Widget>[
                                      CircleAvatar(
                                        radius: 15,
                                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                                        child: Text(
                                          (_diary.authorName.isNotEmpty
                                                  ? _diary.authorName[0]
                                                  : '旅')
                                              .toUpperCase(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        '${_diary.authorName} · ${(_diary.diaryData['dateLabel'] ?? '2026-05-03').toString()}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
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
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _buildQuoteBridgeCard(),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 120),
                  sliver: SliverReorderableList(
                    itemCount: _nodes.length,
                    onReorder: _onTimelineReorder,
                    proxyDecorator: _timelineReorderProxyDecorator,
                    itemBuilder: (BuildContext context, int index) {
                      final _TimelineNode node = _nodes[index];
                      final bool showDayHeader =
                          index == 0 || _nodes[index - 1].day != node.day;
                      final bool isLastOfDay = index == _nodes.length - 1 ||
                          _nodes[index + 1].day != node.day;
                      final bool lineToNextInSameDay = index < _nodes.length - 1 &&
                          _nodes[index + 1].day == node.day;
                      final Map<String, dynamic> actMap =
                          _activityMapForTimelineIndex(index);
                      final bool isLazyNode = _isLazyPoolActivity(actMap);
                      return Column(
                        key: ValueKey<String>(
                          'timeline_node_${node.dIdx}_${node.aIdx}_${node.time}',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          if (showDayHeader && !_isLazyPoolDay(node.dIdx))
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (node.dIdx > 0) const SizedBox(height: 48),
                                Padding(
                              padding: const EdgeInsets.fromLTRB(24, 0, 20, 24),
                              child: Row(
                                children: <Widget>[
                                  // 蓝底药丸 DAY 1
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.indigo.shade500,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      'DAY ${node.day}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // 当天总结文字 (编辑态下带虚线框并支持点击修改)
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: _isEditing
                                          ? () {
                                              _showDaySummaryEditDialog(node.dIdx);
                                            }
                                          : null,
                                      child: Container(
                                        padding: _isEditing
                                            ? const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 4,
                                              )
                                            : EdgeInsets.zero,
                                        decoration: _isEditing
                                            ? BoxDecoration(
                                                border: Border.all(
                                                  color: Colors.indigo.shade200,
                                                  style: BorderStyle.solid,
                                                ),
                                                borderRadius: BorderRadius.circular(8),
                                                color: Colors.indigo.withValues(alpha: 0.05),
                                              )
                                            : null,
                                        child: Text(
                                          _getDaySummary(node.dIdx),
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.grey.shade900,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                              ],
                            ),
                          if (isLazyNode)
                            _buildLazyPoolTimelineItem(
                              context,
                              index,
                              node,
                              actMap,
                              reorderIndex: index,
                            )
                          else
                            Padding(
                            padding: const EdgeInsets.only(bottom: 32),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: <Widget>[
                                if (lineToNextInSameDay)
                                  Positioned(
                                    left: 31,
                                    top: 30,
                                    bottom: -40,
                                    child: Container(
                                      width: 2,
                                      color: Colors.indigo.shade50,
                                    ),
                                  ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Container(
                                      margin: const EdgeInsets.only(
                                        left: 24,
                                        right: 16,
                                        top: 4,
                                      ),
                                      width: 14,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.indigo.shade500,
                                          width: 3,
                                                ),
                                        boxShadow: const <BoxShadow>[
                                          BoxShadow(
                                            color: Colors.black12,
                                            blurRadius: 2,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: <Widget>[
                                          if (_isEditing)
                                            ReorderableDelayedDragStartListener(
                                              index: index,
                                              child: _buildStandardTimelineMainCard(
                                                context,
                                                index,
                                                node,
                                              ),
                                            )
                                          else
                                            _buildStandardTimelineMainCard(
                                              context,
                                              index,
                                              node,
                                            ),
                                          if (_isEditing)
                                            Positioned(
                                              top: 6,
                                              right: 6,
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.opaque,
                                                onTap: () => _confirmDeleteActivity(node),
                                                child: Container(
                                                  padding: const EdgeInsets.all(6),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: Colors.red.shade100,
                                                    ),
                                                    boxShadow: const <BoxShadow>[
                                                      BoxShadow(
                                                        color: Colors.black12,
                                                        blurRadius: 4,
                                                      ),
                                                    ],
                                                  ),
                                                  child: const Icon(
                                                    Icons.close,
                                                    size: 14,
                                                    color: Colors.red,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (_isEditing && !isLastOfDay && !isLazyNode)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 48,
                                top: 4,
                                bottom: 8,
                              ),
                              child: InkWell(
                                onTap: () => _insertActivityAfter(node),
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.add_circle,
                                      color: Colors.indigo.shade300,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '添加记录点',
                                      style: TextStyle(
                                        color: Colors.indigo.shade400,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (_isEditing && isLastOfDay && !isLazyNode)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 31,
                                top: 4,
                                bottom: 24,
                                right: 16,
                              ),
                              child: InkWell(
                                onTap: () => _insertActivityAfter(node),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  decoration: BoxDecoration(
                                    color: Colors.indigo.shade50.withValues(alpha: 0.5),
                                    border: Border.all(color: Colors.indigo.shade200),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: <Widget>[
                                      Icon(
                                        Icons.add_circle_outline,
                                        color: Colors.indigo.shade400,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '添加记录点',
                                        style: TextStyle(
                                          color: Colors.indigo.shade600,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                if (_isEditing)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                    sliver: SliverToBoxAdapter(
                      child: Builder(
                        builder: (BuildContext context) {
                          final bool isLazyPool =
                              _isLazyPoolDiaryFromEditable();
                          return ElevatedButton.icon(
                            icon: Icon(
                              isLazyPool
                                  ? Icons.post_add_rounded
                                  : Icons.add_circle,
                              color: Colors.indigo,
                            ),
                            label: Text(
                              isLazyPool
                                  ? '开启新的照片池'
                                  : '开启新的一天',
                              style: const TextStyle(
                                color: Colors.indigo,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo.shade50,
                              elevation: 0,
                              minimumSize: const Size(double.infinity, 56),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            onPressed: () {
                              setState(() {
                                final List<dynamic> days =
                                    (_editableData['days']
                                            as List<dynamic>?) ??
                                        <dynamic>[];
                                if (isLazyPool) {
                                  days.add(<String, dynamic>{
                                    'dayTitle': '旅途掠影',
                                    'summary': '',
                                    'activities': <Map<String, dynamic>>[
                                      <String, dynamic>{
                                        'is_lazy_pool': true,
                                        'title': '记忆碎片',
                                        'description': '',
                                        'time': '',
                                        'lat': 0.0,
                                        'lng': 0.0,
                                        'photos': <String>[],
                                        'images': <String>[],
                                      },
                                    ],
                                  });
                                } else {
                                  final int newDayNumber = days.length + 1;
                                  days.add(<String, dynamic>{
                                    'day': newDayNumber,
                                    'dayTitle': '新的一天',
                                    'summary': '继续探索...',
                                    'title': '新的开始',
                                    'time': '',
                                    'description': '记录新的精彩瞬间',
                                    'activities': <dynamic>[],
                                  });
                                }
                                _editableData['days'] = days;
                                _editableData = _normalizeEditableData(
                                  Map<String, dynamic>.from(_editableData),
                                );
                                _refreshFromEditableData();
                                _contentVersion++;
                              });
                              Future<void>.delayed(
                                const Duration(milliseconds: 100),
                                () {
                                  if (!mounted ||
                                      !_scrollController.hasClients) {
                                    return;
                                  }
                                  _scrollController.animateTo(
                                    _scrollController.position.maxScrollExtent,
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
            if (_isEditing)
              Positioned(
                right: 16,
                bottom: 44,
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (BuildContext context, Widget? child) {
                    final double scale = 1 + _pulseController.value * 0.08;
                    return Transform.scale(
                      scale: scale,
                      child: child,
                    );
                  },
                  child: FloatingActionButton(
                    heroTag: 'ai_copilot_fab',
                    backgroundColor: const Color(0xFF4F46E5),
                    onPressed: () => _openAiCopilotPanel(
                      targetKey: 'global',
                      originalText: '用户请求全局修改',
                    ),
                    child: const Icon(Icons.auto_awesome_rounded),
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: _isEditing
            ? SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Color(0x12000000),
                  blurRadius: 10,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      const Text(
                        '🌍 公开至发现页',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      Switch(
                        value: _publishToCommunity,
                        onChanged: (bool value) {
                          setState(() => _publishToCommunity = value);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_isEditing)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _editableData = _normalizeEditableData(
                          Map<String, dynamic>.from(_diary.diaryData),
                        );
                        _titleController.text = _diary.title;
                        _quoteController.text =
                            (_diary.diaryData['quote'] ?? '').toString();
                        _editableCoverImageUrl = _diary.coverImageUrl;
                        _publishToCommunity = _diary.isPublic;
                        _refreshFromEditableData();
                        _captureEditSnapshot();
                        _contentVersion++;
                        _isEditing = false;
                      });
                      if (!context.mounted) return;
                      _showEditSnackBar('已取消编辑，改动未保存');
                    },
                    child: const Text(
                      '取消',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                const SizedBox(width: 6),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: <Color>[
                        Colors.indigo.shade600,
                        Colors.purple.shade500,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.indigo.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: () async {
                      await _persist(asDraft: false);
                      if (!context.mounted) return;
                      setState(() => _isEditing = false);
                      _showEditSnackBar('🎉 保存成功！');
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                    child: Text(
                      _publishToCommunity ? '完成并发布' : '完成',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        )
            : null,
      ),
    );
  }

  /// 全屏横向滑动 + 双指缩放查看节点照片。
  /// 常规节点横向照片画廊：编辑态长按拖拽重排；末尾「添加」格不包拖拽监听，不可被拖走。
  Widget _buildPhotoGallery(Map<String, dynamic> activity, int dayIdx, int actIdx) {
    final List<String> images = List<String>.from(_collectActivityDisplayImages(activity));

    return SizedBox(
      height: 160,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: images.length + (_isEditing ? 1 : 0),
        onReorder: (int oldIndex, int newIndex) {
          if (!_isEditing) return;
          if (oldIndex >= images.length || newIndex > images.length) return;
          setState(() {
            if (newIndex > oldIndex) {
              newIndex -= 1;
            }
            final String movedImage = images.removeAt(oldIndex);
            images.insert(newIndex, movedImage);
            activity['photos'] = List<String>.from(images);
            activity['images'] = List<String>.from(images);
            if (images.isNotEmpty) {
              activity['imageUrl'] = images.first;
              activity['image_url'] = images.first;
            } else {
              activity['imageUrl'] = '';
              activity['image_url'] = '';
            }
            _contentVersion++;
            _refreshFromEditableData();
          });
        },
        itemBuilder: (BuildContext context, int imgIndex) {
          if (imgIndex < images.length) {
            final Widget photoWidget = Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 120,
                      height: 160,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showFullScreenGallery(
                          context,
                          images,
                          imgIndex,
                        ),
                        child: _buildNodeImage(images[imgIndex]),
                      ),
                    ),
                  ),
                  if (_isEditing)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: GestureDetector(
                        onTap: () => _handleDeletePhoto(dayIdx, actIdx, images[imgIndex]),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            );
            if (_isEditing) {
              return ReorderableDelayedDragStartListener(
                key: ValueKey<String>('photo_${dayIdx}_${actIdx}_${imgIndex}_${images[imgIndex]}'),
                index: imgIndex,
                child: photoWidget,
              );
            }
            return Container(
              key: ValueKey<String>('photo_${dayIdx}_${actIdx}_${imgIndex}_${images[imgIndex]}'),
              child: photoWidget,
            );
          }
          return GestureDetector(
            key: ValueKey<String>('add_photo_${dayIdx}_$actIdx'),
            onTap: () => _pickAndUploadImage(
              dayIdx,
              actIdx,
              (activity['title'] ?? '景点').toString(),
            ),
            child: Container(
              width: 120,
              height: 160,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Icon(Icons.add_a_photo_outlined, color: Colors.grey, size: 28),
            ),
          );
        },
      ),
    );
  }

  void _showFullScreenGallery(
    BuildContext context,
    List<String> photos,
    int initialIndex,
  ) {
    showFullScreenPhotoGallery(
      context,
      photos,
      initialIndex,
      imageBuilder: _buildNodeImage,
    );
  }

  Widget _buildNodeImage(String pathOrUrl) {
    final String p = pathOrUrl.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CachedNetworkImage(
          imageUrl: p,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorWidget: (_, _, _) => const _DarkImageFallback(),
        ),
      );
    }
    if (p.startsWith('blob:')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          p,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => const _DarkImageFallback(),
        ),
      );
    }
    if (kIsWeb) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          p,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => const _DarkImageFallback(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        File(p),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => const _DarkImageFallback(),
      ),
    );
  }

  Future<void> _showEditDialog({
    required String title,
    required TextEditingController controller,
    int maxLines = 1,
    bool showAiCopilot = false,
  }) async {
    _sheetInputController
      ..text = _realOrEmpty(controller.text)
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: _realOrEmpty(controller.text).length),
      );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
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
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: showAiCopilot
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Expanded(
                                  child: TextField(
                                    controller: _sheetInputController,
                                    maxLines: null,
                                    keyboardType: TextInputType.multiline,
                                    decoration: InputDecoration(
                                      border: InputBorder.none,
                                      hintText: '请输入内容...',
                                      hintStyle: TextStyle(
                                        color: Colors.grey.shade400,
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.auto_awesome,
                                    color: Colors.indigo,
                                    size: 20,
                                  ),
                                  tooltip: 'AI一键润色',
                                  onPressed: () {
                                    _openAiCopilotPanel(
                                      targetKey: 'global',
                                      originalText: '用户请求全局修改',
                                    );
                                    if (!mounted) return;
                                    _sheetInputController.text =
                                        _realOrEmpty(controller.text);
                                    _sheetInputController.selection =
                                        TextSelection.collapsed(
                                      offset: _sheetInputController.text.length,
                                    );
                                  },
                                ),
                              ],
                            )
                          : TextField(
                              controller: _sheetInputController,
                              maxLines: null,
                              keyboardType: TextInputType.multiline,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                hintText: '请输入内容...',
                                hintStyle: TextStyle(color: Colors.grey.shade400),
                              ),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          controller.text = _sheetInputController.text.trim();
                          _contentVersion++;
                        });
                        _sheetInputController.clear();
                        Navigator.of(context).pop();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF111827),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    _sheetInputController.clear();
  }

  Future<void> _showNodeEditDialog({
    required int index,
    required String title,
    required _NodeField field,
    required String initial,
  }) async {
    _sheetInputController
      ..text = _realOrEmpty(initial)
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: _realOrEmpty(initial).length),
      );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
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
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextField(
                        controller: _sheetInputController,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: field == _NodeField.title
                              ? '标题 / 记录点 (如：海边吹风)'
                              : '新增景点待补充描述...',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        final _TimelineNode node = _nodes[index];
                        final List<dynamic> days =
                            (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
                        final Map<String, dynamic> day =
                            days[node.dIdx] as Map<String, dynamic>;
                        final List<dynamic> activities =
                            day['activities'] as List<dynamic>;
                        final Map<String, dynamic> activity =
                            activities[node.aIdx] as Map<String, dynamic>;
                        final String editedValue =
                            _sheetInputController.text.trim();
                        setState(() {
                          if (field == _NodeField.title) {
                            activity['title'] = editedValue;
                          } else {
                            activity['description'] = editedValue;
                          }
                          _refreshFromEditableData();
                          _contentVersion++;
                        });
                        _sheetInputController.clear();
                        Navigator.of(context).pop();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF111827),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    _sheetInputController.clear();
  }
}

class _DiaryAiCopilotBottomSheet extends StatefulWidget {
  const _DiaryAiCopilotBottomSheet({
    required this.fullDiaryData,
    required this.targetKey,
    required this.originalText,
    required this.onTextUpdate,
    required this.onStructureUpdate,
  });

  final Map<String, dynamic> fullDiaryData;
  final String targetKey;
  final String originalText;
  final void Function(String targetKey, String newText) onTextUpdate;
  final void Function(Map<String, dynamic> newDiaryData) onStructureUpdate;

  @override
  State<_DiaryAiCopilotBottomSheet> createState() =>
      _DiaryAiCopilotBottomSheetState();
}

class _DiaryAiCopilotBottomSheetState extends State<_DiaryAiCopilotBottomSheet> {
  final TextEditingController _aiInputController = TextEditingController();
  bool _isProcessing = false;

  @override
  void dispose() {
    _aiInputController.dispose();
    super.dispose();
  }

  void _fillShortcut(String text) {
    setState(() {
      _aiInputController.text = text;
      _aiInputController.selection = TextSelection.fromPosition(
        TextPosition(offset: _aiInputController.text.length),
      );
    });
  }

  String _stripMarkdownJsonFence(String raw) {
    String content = raw.trim();
    if (content.contains('```json')) {
      content = content.split('```json')[1].split('```')[0].trim();
    } else if (content.contains('```')) {
      final List<String> parts = content.split('```');
      if (parts.length >= 2) {
        content = parts[1].trim();
        if (content.startsWith('json')) {
          content = content.substring(4).trim();
        }
      }
    }
    return content;
  }

  Map<String, dynamic> _decodeAiResultJson(String rawContent) {
    final String stripped = _stripMarkdownJsonFence(rawContent);
    if (stripped.isEmpty) {
      throw FormatException('模型返回内容为空');
    }
    final Object? decoded = jsonDecode(stripped);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw FormatException('模型返回不是 JSON 对象');
  }

  Future<void> _submitRequest() async {
    final String prompt = _aiInputController.text.trim();
    if (prompt.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() => _isProcessing = true);

    // 基于焦点的动态场景说明（供模型路由）
    String contextAnalysis = '用户正在通过伴创面板与手账交互。';
    if (widget.targetKey == 'quote') {
      contextAnalysis = '用户正在编辑【手账开篇引言】。';
    } else if (widget.targetKey.startsWith('desc_')) {
      final List<String> parts = widget.targetKey.split('_');
      if (parts.length == 3) {
        final int? dIdx = int.tryParse(parts[1]);
        final int? aIdx = int.tryParse(parts[2]);
        if (dIdx != null && aIdx != null) {
          try {
            final Object? daysRaw = widget.fullDiaryData['days'];
            if (daysRaw is List<dynamic> &&
                dIdx >= 0 &&
                dIdx < daysRaw.length) {
              final Object? dayRaw = daysRaw[dIdx];
              if (dayRaw is Map) {
                final Object? actsRaw = dayRaw['activities'];
                if (actsRaw is List<dynamic> &&
                    aIdx >= 0 &&
                    aIdx < actsRaw.length) {
                  final Object? actRaw = actsRaw[aIdx];
                  if (actRaw is Map) {
                    final String spotName =
                        (actRaw['title'] ?? '未知景点').toString();
                    contextAnalysis =
                        '用户正在编辑第 ${dIdx + 1} 天的景点【$spotName】的描述文案。';
                  }
                }
              }
            }
          } catch (_) {
            contextAnalysis = '用户正在编辑具体景点的文案。';
          }
          if (contextAnalysis ==
              '用户正在通过伴创面板与手账交互。') {
            contextAnalysis = '用户正在编辑具体景点的文案。';
          }
        } else {
          contextAnalysis = '用户正在编辑具体景点的文案。';
        }
      } else {
        contextAnalysis = '用户正在编辑具体景点的文案。';
      }
    } else if (widget.targetKey == 'global') {
      contextAnalysis =
          '用户正在进行【全局操作】（可能想新增某天的行程、增加打卡点，或者整体调整风格）。';
    }

    final String originalForPrompt =
        widget.originalText.trim().isEmpty ? '无内容' : widget.originalText;
    final String diaryJson = jsonEncode(widget.fullDiaryData);

    final String systemPrompt = '''
你是一个顶级的旅行手账专属伴创 AI。你的任务是根据用户的需求，精准修改或生成手账数据。

【当前手账的完整JSON大纲】：
$diaryJson

【用户当前的编辑场景】（极其重要）：
- $contextAnalysis
- 焦点处原稿内容 (originalText): $originalForPrompt

用户发出的指令："$prompt"

【智能路由与执行规则】
你需要分析用户的指令，判断他属于以下哪种意图，并严格返回下方定义的 JSON 格式：

意图 A: 【局部文案润色/补充百科】 (如：一键优化、写生动点、补充点历史背景)
👉 规则：你只需要专注修改原稿内容，结合景点背景生成最精彩的文案。将 action_type 设为 "update_text"，并将改写后的纯文本放入 updated_text 字段。

意图 B: 【行程结构修改/新增打卡点】 (如：第一天加个火锅店、把第二天行程删掉、新增一天的安排)
👉 规则：你不需要拘泥于原稿！请统观整个手账 JSON 结构，在合适的天数(days)和时间间隙中，插入或修改节点(activity)对象。必须自动顺延上下文的时间！将 action_type 设为 "update_structure"，并将修改后的【完整手账JSON对象】放入 updated_diary_data 字段。

意图 C: 【纯粹聊天/旅游问答】 (如：这里天气怎么样？需要带外套吗？)
👉 规则：如果用户明显不是要修改手账内容，只是提问。将 action_type 设为 "chat"，在 reply_msg 给出亲切回答即可。

【强制输出格式】（绝对只输出合法的 JSON，不要包裹 Markdown 代码块，不要输出废话）：
{
  "action_type": "update_text" 或 "update_structure" 或 "chat",
  "reply_msg": "无论哪种意图，请在这里给用户一句亲切的管家式回复（如：好的，已经为您润色好了/已为您插好了景点）",
  "updated_text": "意图A时填入最终的高质量纯文本，否则为空字符串",
  "updated_diary_data": null
}
说明：意图 B 时 updated_diary_data 必须为完整手账 JSON 对象；意图 A、C 时 updated_diary_data 必须为 JSON null。
''';

    try {
      final http.Response response = await http
          .post(
            Uri.parse(AiConfig.deepseekEndpoint),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${AiConfig.deepseekApiKey}',
            },
            body: jsonEncode(<String, Object?>{
              'model': AiConfig.deepseekModel,
              'messages': <Map<String, String>>[
                <String, String>{'role': 'system', 'content': systemPrompt},
                <String, String>{'role': 'user', 'content': prompt},
              ],
              'response_format': <String, String>{'type': 'json_object'},
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception('API Error: ${response.statusCode}');
      }

      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final List<dynamic>? choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        throw Exception('Empty choices');
      }
      final Map<String, dynamic>? message =
          choices.first['message'] as Map<String, dynamic>?;
      final Object? rawContent = message?['content'];
      final String contentStr = rawContent is String
          ? rawContent
          : rawContent is Map
              ? jsonEncode(rawContent)
              : rawContent?.toString() ?? '';

      final Map<String, dynamic> result = _decodeAiResultJson(contentStr);

      if (!mounted) return;

      final String replyMsg =
          (result['reply_msg'] ?? '操作已完成。').toString().trim();
      if (replyMsg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✨ $replyMsg')),
        );
      }

      final String actionType =
          (result['action_type'] ?? '').toString().trim();
      final Object? struct = result['updated_diary_data'];
      final String updatedText =
          (result['updated_text'] ?? '').toString().trim();

      if (actionType == 'update_structure' && struct != null) {
        if (struct is Map<String, dynamic>) {
          widget.onStructureUpdate(struct);
        } else if (struct is Map) {
          widget.onStructureUpdate(Map<String, dynamic>.from(struct));
        }
      } else if (actionType == 'update_text' &&
          updatedText.isNotEmpty) {
        widget.onTextUpdate(widget.targetKey, updatedText);
      }

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e, st) {
      debugPrint('伴创失败: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('管家网络连接异常，请重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.auto_awesome, color: Colors.indigo, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    'AI 伴创面板',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                  const Spacer(),
                  if (_isProcessing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.indigo,
                      ),
                    ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2.8,
                      children: <Widget>[
                        _buildShortcutBtn(
                          '✨ 一键优化文案',
                          '更文艺、更感性',
                          Colors.indigo,
                          '帮我把这段文案润色得更有文艺感和画面感。',
                        ),
                        _buildShortcutBtn(
                          '📖 补充景点百科',
                          '增加深度内涵',
                          Colors.purple,
                          '帮我在这段描述中补充一些关于这里的历史背景或冷知识。',
                        ),
                        _buildShortcutBtn(
                          '🎯 提炼旅行亮点',
                          '总结高光时刻',
                          Colors.orange,
                          '帮我提炼这段行程的核心亮点，用活泼的语气输出。',
                        ),
                        _buildShortcutBtn(
                          '🗺️ 新增打卡点',
                          '结构化插入行程',
                          Colors.teal,
                          '请在第一天和第二天之间，帮我插入一个新的打卡点：[请填写]。',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '✍️ 告诉管家你的具体想法',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Colors.black38,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 12,
                                top: 4,
                                bottom: 4,
                              ),
                              child: TextField(
                                controller: _aiInputController,
                                maxLines: 4,
                                minLines: 1,
                                style: const TextStyle(fontSize: 14),
                                decoration: const InputDecoration(
                                  hintText:
                                      '例如：帮我把第二天下午的行程换成去吃火锅...',
                                  border: InputBorder.none,
                                  hintStyle: TextStyle(color: Colors.black38),
                                ),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: _isProcessing ? null : _submitRequest,
                            child: Container(
                              margin: const EdgeInsets.all(4),
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                gradient: _isProcessing
                                    ? null
                                    : const LinearGradient(
                                        colors: <Color>[
                                          Colors.indigo,
                                          Colors.purple,
                                        ],
                                      ),
                                color: _isProcessing ? Colors.grey : null,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.arrow_upward_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
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
  }

  Widget _buildShortcutBtn(
    String title,
    String sub,
    MaterialColor color,
    String prompt,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _fillShortcut(prompt),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.shade100),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: color.shade700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(fontSize: 9, color: color.shade400),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InsertNodeBottomSheet extends StatefulWidget {
  const _InsertNodeBottomSheet({
    required this.onConfirm,
    this.onPickTime,
  });

  final void Function(String title, String time) onConfirm;
  final Future<void> Function(TextEditingController controller)? onPickTime;

  @override
  State<_InsertNodeBottomSheet> createState() => _InsertNodeBottomSheetState();
}

class _InsertNodeBottomSheetState extends State<_InsertNodeBottomSheet> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();
  String? _errorMessage;

  static final RegExp _timeRegex =
      RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');

  @override
  void dispose() {
    _titleController.dispose();
    _timeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        decoration: const BoxDecoration(
          color: Color(0xFFF5F7FA),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(28),
            topRight: Radius.circular(28),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              child: const Center(
                child: Text(
                  '插入新记录点',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: TextField(
                        controller: _titleController,
                        onChanged: (String _) {
                          if (_errorMessage != null) {
                            setState(() => _errorMessage = null);
                          }
                        },
                        decoration: const InputDecoration(
                          hintText: '标题 / 记录点 (如：海边吹风)',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _errorMessage != null
                              ? Colors.red.shade300
                              : Colors.grey.shade200,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _timeController,
                              keyboardType: TextInputType.datetime,
                              onChanged: (String _) {
                                if (_errorMessage != null) {
                                  setState(() => _errorMessage = null);
                                }
                              },
                              decoration: const InputDecoration(
                                hintText: '大概时间 (格式: HH:mm，选填)',
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '选择时间',
                            icon: const Icon(Icons.schedule_rounded),
                            color: Colors.indigo.shade600,
                            onPressed: () async {
                              if (widget.onPickTime == null) return;
                              await widget.onPickTime!(_timeController);
                              if (_errorMessage != null &&
                                  _timeRegex.hasMatch(_timeController.text.trim())) {
                                setState(() => _errorMessage = null);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, left: 4),
                        child: Row(
                          children: <Widget>[
                            const Icon(
                              Icons.error_outline,
                              color: Colors.redAccent,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          final String timeInput = _timeController.text.trim();
                          final String titleInput = _titleController.text.trim();

                          if (titleInput.isEmpty) {
                            setState(() => _errorMessage = '请填写标题');
                            return;
                          }

                          if (timeInput.isNotEmpty &&
                              !_timeRegex.hasMatch(timeInput)) {
                            setState(() {
                              _errorMessage = '时间格式有误，请输入如 14:30 的24小时制时间';
                            });
                            return;
                          }

                          widget.onConfirm(titleInput, timeInput);
                          Navigator.of(context).pop();
                        },
                        child: const Text(
                          '确认插入',
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
            ),
          ],
        ),
      ),
    );
  }
}

enum _NodeField { title, description }

class _TimelineNode {
  const _TimelineNode({
    required this.day,
    required this.dIdx,
    required this.aIdx,
    required this.title,
    required this.time,
    required this.description,
    required this.lat,
    required this.lng,
    required this.photos,
  });

  final int day;
  final int dIdx;
  final int aIdx;
  final String title;
  final String time;
  final String description;
  final double lat;
  final double lng;
  final List<String> photos;

  _TimelineNode copyWith({
    int? day,
    int? dIdx,
    int? aIdx,
    String? title,
    String? time,
    String? description,
    double? lat,
    double? lng,
    List<String>? photos,
  }) {
    return _TimelineNode(
      day: day ?? this.day,
      dIdx: dIdx ?? this.dIdx,
      aIdx: aIdx ?? this.aIdx,
      title: title ?? this.title,
      time: time ?? this.time,
      description: description ?? this.description,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      photos: photos ?? List<String>.from(this.photos),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'day': day,
      'dIdx': dIdx,
      'aIdx': aIdx,
      'title': title,
      'time': time,
      'description': description,
      'lat': lat,
      'lng': lng,
      'photos': photos,
    };
  }
}

class _DarkImageFallback extends StatelessWidget {
  const _DarkImageFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1F2937),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x8A2A2E37), Color(0xFF0B1020)],
              ),
            ),
          ),
          const Center(
            child: Icon(Icons.image_not_supported_outlined, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}