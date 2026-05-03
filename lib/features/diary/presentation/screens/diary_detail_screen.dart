import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gonow/features/common/presentation/widgets/full_screen_photo_gallery.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
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
  final TextEditingController _aiInputController = TextEditingController();
  final TextEditingController _sheetInputController = TextEditingController();

  late DiaryModel _diary = widget.initialDiary;
  late Map<String, dynamic> _editableData = _normalizeEditableData(
    Map<String, dynamic>.from(widget.initialDiary.diaryData),
  );
  late List<_TimelineNode> _nodes = _buildNodes(_editableData);
  late bool _isEditing = widget.startEditing;
  bool _publishToCommunity = false;
  int _contentVersion = 0;
  String _snapshotDataStr = '';
  String _snapshotTitle = '';

  late final AnimationController _pulseController;

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
    _aiInputController.dispose();
    _sheetInputController.dispose();
    _pulseController.dispose();
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
          activities.add(<String, dynamic>{
            'title': _realOrEmpty(a['title']),
            'time': (a['time'] ?? '').toString(),
            'description': _realOrEmpty(a['description']),
            'lat': (a['lat'] as num?)?.toDouble() ?? 0,
            'lng': (a['lng'] as num?)?.toDouble() ?? 0,
            'photos': ((a['photos'] as List<dynamic>?) ?? <dynamic>[])
                .map((dynamic e) => e.toString())
                .where((String e) => e.isNotEmpty)
                .toList(growable: false),
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
      normalizedDays.add(<String, dynamic>{
        'day': dayNo,
        'activities': activities,
      });
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
            photos: ((item['photos'] as List<dynamic>?) ?? <dynamic>[])
                .map((dynamic e) => e.toString())
                .where((String e) => e.isNotEmpty)
                .toList(growable: true),
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
    final Map<String, dynamic> updatedData = <String, dynamic>{
      ..._editableData,
      'quote': _quoteController.text.trim(),
      'days': _editableData['days'],
      'updatedAt': DateTime.now().toIso8601String(),
    };
    final DiaryModel updated = _diary.copyWith(
      title: _titleController.text.trim().isEmpty
          ? '未命名手账'
          : _titleController.text.trim(),
      isDraft: asDraft,
      isPublic: asDraft ? false : _publishToCommunity,
      diaryData: updatedData,
    );
    await provider.saveDiary(updated);
    _diary = updated;
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
  }

  /// 脏数据检测：仅在确有改动时才需要返回确认弹窗。
  bool _hasUnsavedChanges() {
    if (_titleController.text.trim() != _snapshotTitle) {
      return true;
    }

    if (jsonEncode(_editableData) != _snapshotDataStr) {
      return true;
    }

    return false;
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

  Future<void> _deletePhoto(int nodeIndex, int photoIndex) async {
    final _TimelineNode node = _nodes[nodeIndex];
    final List<dynamic> days = (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> day = days[node.dIdx] as Map<String, dynamic>;
    final List<dynamic> activities = day['activities'] as List<dynamic>;
    final Map<String, dynamic> item = activities[node.aIdx] as Map<String, dynamic>;
    final List<dynamic> photos = (item['photos'] as List<dynamic>?) ?? <dynamic>[];
    if (photoIndex < 0 || photoIndex >= photos.length) return;
    setState(() {
      photos.removeAt(photoIndex);
      item['photos'] = photos;
      _refreshFromEditableData();
      _contentVersion++;
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

    final _TimelineNode node = _nodes[nodeIndex];
    final List<dynamic> days =
        (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (node.dIdx < 0 || node.dIdx >= days.length) return;
    final Map<String, dynamic> day = days[node.dIdx] as Map<String, dynamic>;
    final List<dynamic> activities = day['activities'] as List<dynamic>;
    if (node.aIdx < 0 || node.aIdx >= activities.length) return;
    final Map<String, dynamic> item =
        activities[node.aIdx] as Map<String, dynamic>;

    final List<String> existing = ((item['photos'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic e) => e.toString())
        .where((String e) => e.isNotEmpty)
        .toList(growable: true);

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

  Future<void> _openAiCopilotPanel() async {
    // 🚨 Drop keyboard focus before opening modal
    FocusScope.of(context).unfocus();
    
    _aiInputController.clear();
    final List<String> quickActions = <String>[
      '✨ 一键优化文案',
      '📖 补充景点百科',
      '🎯 提炼旅行亮点',
      '🌦 增加天气感受',
    ];
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
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: Material(
                color: const Color(0xFFF5F7FA),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 44,
                        height: 5,
                        margin: const EdgeInsets.only(top: 10, bottom: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD6DCE6),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      const Text(
                        'AI 伴创面板',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: quickActions.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 3.2,
                            ),
                            itemBuilder: (BuildContext context, int index) {
                              final String action = quickActions[index];
                              return OutlinedButton(
                                onPressed: () async {
                                  final String seed = action.trim();
                                  if (seed.isEmpty) return;
                                  final String oldQuote =
                                      _quoteController.text.trim();
                                  final String newQuote =
                                      '「$seed」\n\n沿路的光影被重新排版，文字更有节奏。';
                                  final List<dynamic> days =
                                      (_editableData['days'] as List<dynamic>?) ??
                                          <dynamic>[];
                                  for (final dynamic dayItem in days) {
                                    final Map<String, dynamic> day =
                                        dayItem as Map<String, dynamic>;
                                    final List<dynamic> activities =
                                        day['activities'] as List<dynamic>? ??
                                            <dynamic>[];
                                    for (final dynamic actItem in activities) {
                                      final Map<String, dynamic> act =
                                          actItem as Map<String, dynamic>;
                                      final String oldDesc =
                                          (act['description'] ?? '').toString();
                                      act['description'] =
                                          '$oldDesc\n\nAI润色：$seed，让画面更具临场感。';
                                    }
                                  }
                                  if (!mounted) return;
                                  Navigator.of(context).pop();
                                  setState(() {
                                    _quoteController.text = oldQuote.isEmpty
                                        ? newQuote
                                        : '$oldQuote\n$newQuote';
                                    _refreshFromEditableData();
                                    _contentVersion++;
                                  });
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF1F2937),
                                  side: const BorderSide(
                                    color: Color(0xFFD5DBE5),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  action,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 10,
                              offset: const Offset(0, -4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: TextField(
                                controller: _aiInputController,
                                decoration: const InputDecoration(
                                  hintText: '✍️ 告诉管家你的具体想法 (如：把这段写幽默点)',
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () async {
                                final String seed =
                                    _aiInputController.text.trim();
                                if (seed.isEmpty) return;
                                final String oldQuote =
                                    _quoteController.text.trim();
                                final String newQuote =
                                    '「$seed」\n\n沿路的光影被重新排版，文字更有节奏。';
                                final List<dynamic> days =
                                    (_editableData['days'] as List<dynamic>?) ??
                                        <dynamic>[];
                                for (final dynamic dayItem in days) {
                                  final Map<String, dynamic> day =
                                      dayItem as Map<String, dynamic>;
                                  final List<dynamic> activities =
                                      day['activities'] as List<dynamic>? ??
                                          <dynamic>[];
                                  for (final dynamic actItem in activities) {
                                    final Map<String, dynamic> act =
                                        actItem as Map<String, dynamic>;
                                    final String oldDesc =
                                        (act['description'] ?? '').toString();
                                    act['description'] =
                                        '$oldDesc\n\nAI润色：$seed，让画面更具临场感。';
                                  }
                                }
                                _aiInputController.clear();
                                if (!mounted) return;
                                Navigator.of(context).pop();
                                setState(() {
                                  _quoteController.text = oldQuote.isEmpty
                                      ? newQuote
                                      : '$oldQuote\n$newQuote';
                                  _refreshFromEditableData();
                                  _contentVersion++;
                                });
                              },
                              icon: const Icon(
                                Icons.send_rounded,
                                color: Color(0xFF4F46E5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    _aiInputController.clear();
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
    return _editableWrap(
      onTap: () => _showEditDialog(
        title: '编辑引言',
        controller: _quoteController,
        maxLines: 6,
        showAiCopilot: true,
      ),
      child: Container(
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
              child: Text(
                _quoteController.text.trim().isEmpty
                    ? '每次出发，都是对平淡生活的一次温柔越狱。'
                    : _quoteController.text,
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

  Future<void> _addNewDay() async {
    final List<dynamic> days = (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    final int newDayNumber = days.length + 1;
    setState(() {
      days.add(<String, dynamic>{
        'day': newDayNumber,
        'summary': '新的一天开始了...',
        'activities': <Map<String, dynamic>>[
          <String, dynamic>{
            'title': '新的记录点',
            'time': '',
            'description': '记录这一天的精彩瞬间',
            'lat': 0.0,
            'lng': 0.0,
            'photos': <String>[],
          },
        ],
      });
      _editableData['days'] = days;
      _refreshFromEditableData();
      _contentVersion++;
    });
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
                              child: CachedNetworkImage(
                                imageUrl: _diary.coverImageUrl,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  color: Colors.blueGrey.shade800,
                                ),
                              ),
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
                      return ReorderableDelayedDragStartListener(
                        key: ObjectKey(actMap),
                        index: index,
                        enabled: _isEditing,
                        child: Column(
                          key: ValueKey<String>(
                            'timeline_node_${node.dIdx}_${node.aIdx}',
                          ),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                          if (showDayHeader)
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
                                          Container(
                                            padding: const EdgeInsets.fromLTRB(
                                              14,
                                              14,
                                              14,
                                              14,
                                            ),
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
                                                  builder:
                                                      (BuildContext context) {
                                                    final String timeStr =
                                                        node.time.trim();
                                                    final bool isRealTime =
                                                        _looksLikeTimeLabel(
                                                            timeStr);
                                                    final String titleLine =
                                                        _displayNodeTitleLine(
                                                            node);
                                                    return Row(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .center,
                                                      children: <Widget>[
                                                        if (isRealTime)
                                                          InkWell(
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(6),
                                                            onTap: _isEditing
                                                                ? () =>
                                                                    _pickAndSaveActivityTime(
                                                                      index,
                                                                    )
                                                                : null,
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .only(
                                                                right: 8,
                                                              ),
                                                              child: Text(
                                                                timeStr,
                                                                style:
                                                                    TextStyle(
                                                                  color: Colors
                                                                      .indigo
                                                                      .shade600,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                  fontSize: 14,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        Expanded(
                                                          child: _editableWrap(
                                                            onTap: () =>
                                                                _showNodeEditDialog(
                                                              index: index,
                                                              title:
                                                                  '编辑节点标题',
                                                              field: _NodeField
                                                                  .title,
                                                              initial:
                                                                  node.title,
                                                            ),
                                                            child: Text(
                                                              titleLine,
                                                              style:
                                                                  const TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
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
                                            if (_isEditing)
                                              Builder(
                                                builder: (BuildContext context) {
                                                  String realDesc = node.description.trim();
                                                  if (_isDummyDescriptionContent(realDesc)) {
                                                    realDesc = '';
                                                  }

                                                  return Container(
                                                    margin: const EdgeInsets.only(bottom: 4),
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
                                                            decoration:
                                                                const InputDecoration(
                                                              hintText:
                                                                  '新增景点待补充描述...',
                                                              hintStyle: TextStyle(
                                                                color: Colors
                                                                    .black38,
                                                                fontSize: 13,
                                                              ),
                                                              contentPadding:
                                                                  EdgeInsets
                                                                      .all(12),
                                                              border:
                                                                  InputBorder
                                                                      .none,
                                                            ),
                                                            onChanged:
                                                                (String val) {
                                                              final List<
                                                                      dynamic>
                                                                  days =
                                                                  (_editableData['days']
                                                                          as List<
                                                                              dynamic>?) ??
                                                                      <dynamic>[];
                                                              final Map<String,
                                                                      dynamic>
                                                                  day =
                                                                  days[node.dIdx]
                                                                      as Map<
                                                                          String,
                                                                          dynamic>;
                                                              final List<
                                                                      dynamic>
                                                                  activities =
                                                                  day['activities']
                                                                      as List<
                                                                          dynamic>;
                                                              final Map<String,
                                                                      dynamic>
                                                                  item =
                                                                  activities[node.aIdx]
                                                                      as Map<
                                                                          String,
                                                                          dynamic>;

                                                              item['description'] =
                                                                  val;

                                                              setState(() {
                                                                _refreshFromEditableData();
                                                                _contentVersion++;
                                                              });
                                                            },
                                                          ),
                                                        ),
                                                        // Single AI Polish Button
                                                        IconButton(
                                                          icon: const Icon(
                                                            Icons.auto_awesome,
                                                            color: Colors.indigo,
                                                            size: 20,
                                                          ),
                                                          onPressed: _openAiCopilotPanel,
                                                          tooltip: 'AI一键润色',
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              )
                                            else if (node.description.trim().isNotEmpty &&
                                                !_isDummyDescriptionContent(node.description))
                                              Padding(
                                                padding: const EdgeInsets.only(bottom: 4),
                                                child: Text(
                                                  _dedupeDescriptionParagraphs(
                                                    node.description,
                                                  ),
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    color: Color(0xFF475569),
                                                    height: 1.5,
                                                  ),
                                                ),
                                              ),
                                            const SizedBox(height: 12),
                                            SizedBox(
                                              height: 100,
                                              child: ListView.builder(
                                                scrollDirection: Axis.horizontal,
                                                physics: const BouncingScrollPhysics(),
                                                itemCount: node.photos.length + (_isEditing ? 1 : 0),
                                                itemBuilder: (BuildContext context, int photoIndex) {
                                                  if (_isEditing && photoIndex == node.photos.length) {
                                                    return GestureDetector(
                                                      onTap: () => _addPhoto(index),
                                                      child: Container(
                                                        width: 75,
                                                        margin: const EdgeInsets.only(right: 10),
                                                        decoration: BoxDecoration(
                                                          color: Colors.grey.shade50,
                                                          borderRadius: BorderRadius.circular(12),
                                                          border: Border.all(
                                                            color: Colors.grey.shade300,
                                                          ),
                                                        ),
                                                        child: const Icon(
                                                          Icons.add_a_photo_outlined,
                                                          color: Colors.grey,
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                  final String url = node.photos[photoIndex];
                                                  return Container(
                                                    width: 75,
                                                    margin: const EdgeInsets.only(right: 10),
                                                    clipBehavior: Clip.antiAlias,
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(12),
                                                    ),
                                                    child: Stack(
                                                      fit: StackFit.expand,
                                                      children: <Widget>[
                                                        GestureDetector(
                                                          behavior:
                                                              HitTestBehavior.opaque,
                                                          onTap: () =>
                                                              _showFullScreenGallery(
                                                            context,
                                                            node.photos,
                                                            photoIndex,
                                                          ),
                                                          child: _buildNodeImage(url),
                                                        ),
                                                        if (_isEditing)
                                                          Positioned(
                                                            top: 4,
                                                            right: 4,
                                                            child: GestureDetector(
                                                              behavior:
                                                                  HitTestBehavior
                                                                      .opaque,
                                                              onTap: () => _deletePhoto(
                                                                index,
                                                                photoIndex,
                                                              ),
                                                              child: Container(
                                                                padding: const EdgeInsets.all(4),
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
                                                  );
                                                },
                                              ),
                                            ),
                                              ],
                                            ),
                                          ),
                                          if (_isEditing)
                                            Positioned(
                                              top: 8,
                                              right: 8,
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
                          if (_isEditing && !isLastOfDay)
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
                          if (_isEditing && isLastOfDay)
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
                      ),
                    );
                    },
                  ),
                ),
                if (_isEditing)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                    sliver: SliverToBoxAdapter(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.add_circle, color: Colors.indigo),
                        label: const Text(
                          '开启新的一天',
                          style: TextStyle(
                            color: Colors.indigo,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo.shade50,
                          elevation: 0,
                          minimumSize: const Size(double.infinity, 56),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: _addNewDay,
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
                    onPressed: _openAiCopilotPanel,
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
          errorBuilder: (_, _, _) => const _DarkImageFallback(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        File(p),
        fit: BoxFit.cover,
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
                                  onPressed: () async {
                                    await _openAiCopilotPanel();
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
