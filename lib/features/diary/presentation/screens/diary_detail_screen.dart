import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
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
  final TextEditingController _timeInputController = TextEditingController();

  late DiaryModel _diary = widget.initialDiary;
  late final Map<String, dynamic> _editableData = _normalizeEditableData(
    widget.initialDiary.diaryData,
  );
  late List<_TimelineNode> _nodes = _buildNodes(_editableData);
  late bool _isEditing = widget.startEditing;
  bool _publishToCommunity = false;
  int _contentVersion = 0;

  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _titleController.text = _diary.title;
    _quoteController.text = (_diary.diaryData['quote'] ?? '').toString();
    _publishToCommunity = _diary.isPublic;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _quoteController.dispose();
    _aiInputController.dispose();
    _sheetInputController.dispose();
    _timeInputController.dispose();
    _pulseController.dispose();
    super.dispose();
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
            'title': (a['title'] ?? '未命名景点').toString(),
            'time': (a['time'] ?? '').toString(),
            'description': (a['description'] ?? '这段旅程还没有补充描述').toString(),
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
          'title': (day['title'] ?? '未命名景点').toString(),
          'time': (day['time'] ?? '').toString(),
          'description': (day['description'] ?? '这段旅程还没有补充描述').toString(),
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
            title: (item['title'] ?? '未命名景点').toString(),
            time: (item['time'] ?? '').toString(),
            description: (item['description'] ?? '这段旅程还没有补充描述').toString(),
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
  }

  Future<void> _onPressBack() async {
    if (_isEditing) {
      await _persist(asDraft: true);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _toggleEditing() async {
    if (_isEditing) {
      await _persist(asDraft: true);
      if (!mounted) return;
      setState(() => _isEditing = false);
      return;
    }
    setState(() => _isEditing = true);
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
    final List<XFile> images = await _imagePicker.pickMultiImage(
      imageQuality: 88,
      maxWidth: 1800,
    );
    if (images.isEmpty) return;
    final _TimelineNode node = _nodes[nodeIndex];
    final List<dynamic> days = (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
    final Map<String, dynamic> day = days[node.dIdx] as Map<String, dynamic>;
    final List<dynamic> activities = day['activities'] as List<dynamic>;
    final Map<String, dynamic> item = activities[node.aIdx] as Map<String, dynamic>;
    final List<dynamic> photos = (item['photos'] as List<dynamic>?) ?? <dynamic>[];
    setState(() {
      photos.addAll(images.map((XFile e) => e.path).where((String e) => e.isNotEmpty));
      item['photos'] = photos;
      _refreshFromEditableData();
      _contentVersion++;
    });
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
        activities.add(<String, dynamic>{
          'title': '未命名景点',
          'time': '',
          'description': '这段旅程还没有补充描述',
          'lat': 0.0,
          'lng': 0.0,
          'photos': <String>[],
        });
      }
      day['activities'] = activities;
      _refreshFromEditableData();
      _contentVersion++;
    });
  }

  Future<void> _insertActivityAfter(_TimelineNode node) async {
    _sheetInputController.clear();
    _timeInputController.clear();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Material(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text(
                      '插入新景点',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _sheetInputController,
                      decoration: InputDecoration(
                        hintText: '景点标题',
                        filled: true,
                        fillColor: const Color(0xFFF4F6FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _timeInputController,
                      decoration: InputDecoration(
                        hintText: '大致时间（如 14:30）',
                        filled: true,
                        fillColor: const Color(0xFFF4F6FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          final String title = _sheetInputController.text.trim();
                          if (title.isEmpty) return;
                          final List<dynamic> days =
                              (_editableData['days'] as List<dynamic>?) ?? <dynamic>[];
                          final Map<String, dynamic> day =
                              days[node.dIdx] as Map<String, dynamic>;
                          final List<dynamic> activities =
                              day['activities'] as List<dynamic>;
                          activities.insert(node.aIdx + 1, <String, dynamic>{
                            'title': title,
                            'time': _timeInputController.text.trim(),
                            'description': '新增景点待补充描述',
                            'lat': 0.0,
                            'lng': 0.0,
                            'photos': <String>[],
                          });
                          day['activities'] = activities;
                          setState(() {
                            _refreshFromEditableData();
                            _contentVersion++;
                          });
                          _sheetInputController.clear();
                          _timeInputController.clear();
                          Navigator.of(context).pop();
                        },
                        child: const Text('确认插入'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAiCopilotPanel() async {
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
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
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
      child: CustomPaint(
        painter: _DottedPainter(
          color: const Color(0xFF2563EB),
          radius: 12,
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: child,
        ),
      ),
    );
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
        backgroundColor: const Color(0xFFF4F6FA),
        body: Stack(
          children: <Widget>[
            CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 400,
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        Hero(
                          tag: 'diary_cover_${_diary.id}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CachedNetworkImage(
                              imageUrl: _diary.coverImageUrl,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => const _DarkImageFallback(),
                            ),
                          ),
                        ),
                        Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[Color(0x22000000), Color(0xD9000000)],
                            ),
                          ),
                        ),
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 8,
                          left: 8,
                          child: IconButton(
                            onPressed: _onPressBack,
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
                              _isEditing ? Icons.check_rounded : Icons.edit_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _isEditing ? '完成编辑' : '编辑',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 26,
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
                                    color: Colors.white,
                                    fontSize: 32,
                                    height: 1.1,
                                    fontWeight: FontWeight.w900,
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
                ),
                SliverToBoxAdapter(
                  child: Transform.translate(
                    offset: const Offset(0, -20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _editableWrap(
                        onTap: () => _showEditDialog(
                          title: '编辑引言',
                          controller: _quoteController,
                          maxLines: 6,
                        ),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.04),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Stack(
                            children: <Widget>[
                              Positioned(
                                left: 0,
                                top: -6,
                                child: Icon(
                                  Icons.format_quote_rounded,
                                  color: Colors.indigo.shade100,
                                  size: 32,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(left: 28),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 280),
                                  child: Text(
                                    _quoteController.text,
                                    key: ValueKey<String>('quote_$_contentVersion'),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.6,
                                      color: Color(0xFF1F2937),
                                      fontWeight: FontWeight.w600,
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
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 120),
                  sliver: SliverList.builder(
                    itemCount: _nodes.length,
                    itemBuilder: (BuildContext context, int index) {
                      final _TimelineNode node = _nodes[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            Positioned(
                              left: 31,
                              top: 30,
                              bottom: -40,
                              child: Container(
                                width: 2,
                                color: Colors.grey.shade200,
                              ),
                            ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Container(
                                  margin: const EdgeInsets.only(
                                    left: 20,
                                    right: 16,
                                    top: 4,
                                  ),
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: Colors.indigo.shade500,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 3),
                                    boxShadow: const <BoxShadow>[
                                      BoxShadow(
                                        color: Colors.black12,
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Container(
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
                                        Row(
                                          children: <Widget>[
                                            Expanded(
                                              child: _editableWrap(
                                                onTap: () => _showNodeEditDialog(
                                                  index: index,
                                                  title: '编辑节点标题',
                                                  field: _NodeField.title,
                                                  initial: node.title,
                                                ),
                                                child: Text(
                                                  'Day ${node.day} · ${node.title}${node.time.isNotEmpty ? ' · ${node.time}' : ''}',
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w800,
                                                    color: Color(0xFF0F172A),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (_isEditing)
                                              IconButton(
                                                onPressed: () => _deleteActivity(
                                                  node.dIdx,
                                                  node.aIdx,
                                                ),
                                                icon: const Icon(
                                                  Icons.delete_forever_rounded,
                                                  color: Colors.redAccent,
                                                  size: 20,
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        _editableWrap(
                                          onTap: () => _showNodeEditDialog(
                                            index: index,
                                            title: '编辑节点描述',
                                            field: _NodeField.description,
                                            initial: node.description,
                                          ),
                                          child: AnimatedSwitcher(
                                            duration: const Duration(milliseconds: 300),
                                            child: Text(
                                              node.description,
                                              key: ValueKey<String>(
                                                'node_desc_${index}_$_contentVersion',
                                              ),
                                              style: const TextStyle(
                                                fontSize: 13,
                                                height: 1.58,
                                                color: Color(0xFF475569),
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        SizedBox(
                                          height: 80,
                                          child: ListView.builder(
                                            scrollDirection: Axis.horizontal,
                                            itemCount: node.photos.length + (_isEditing ? 1 : 0),
                                            itemBuilder: (BuildContext context, int photoIndex) {
                                              if (_isEditing && photoIndex == node.photos.length) {
                                                return GestureDetector(
                                                  onTap: () => _addPhoto(index),
                                                  child: Container(
                                                    width: 88,
                                                    margin: const EdgeInsets.only(right: 10),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFFF3F5F9),
                                                      borderRadius: BorderRadius.circular(12),
                                                      border: Border.all(
                                                        color: const Color(0xFFD3D9E4),
                                                      ),
                                                    ),
                                                    child: const Icon(
                                                      Icons.add_rounded,
                                                      color: Color(0xFF64748B),
                                                    ),
                                                  ),
                                                );
                                              }
                                              final String url = node.photos[photoIndex];
                                              return Container(
                                                width: 88,
                                                margin: const EdgeInsets.only(right: 10),
                                                clipBehavior: Clip.antiAlias,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(12),
                                                ),
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: <Widget>[
                                                    _buildNodeImage(url),
                                                    if (_isEditing)
                                                      Positioned(
                                                        top: 4,
                                                        right: 4,
                                                        child: GestureDetector(
                                                          onTap: () => _deletePhoto(index, photoIndex),
                                                          child: Container(
                                                            width: 20,
                                                            height: 20,
                                                            decoration: const BoxDecoration(
                                                              color: Colors.red,
                                                              shape: BoxShape.circle,
                                                            ),
                                                            child: const Icon(
                                                              Icons.close_rounded,
                                                              size: 14,
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
                                        if (_isEditing && index < _nodes.length - 1)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 12),
                                            child: GestureDetector(
                                              onTap: () => _insertActivityAfter(node),
                                              child: CustomPaint(
                                                painter: _DottedPainter(
                                                  color: const Color(0xFF9CA3AF),
                                                  radius: 10,
                                                ),
                                                child: Container(
                                                  width: double.infinity,
                                                  padding:
                                                      const EdgeInsets.symmetric(vertical: 10),
                                                  alignment: Alignment.center,
                                                  child: const Text(
                                                    '+ 插入新景点',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: Color(0xFF6B7280),
                                                    ),
                                                  ),
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
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            if (_isEditing)
              Positioned(
                right: 18,
                bottom: 96,
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
        bottomNavigationBar: SafeArea(
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
                    onPressed: () async {
                      await _persist(asDraft: true);
                      if (!mounted) return;
                      Navigator.of(this.context).pop();
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
                      await _persist(asDraft: _isEditing);
                      if (!mounted) return;
                      if (_isEditing) {
                        setState(() => _isEditing = false);
                      } else {
                        await _persist(asDraft: false);
                        if (!mounted) return;
                        Navigator.of(this.context).pop();
                      }
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
        ),
      ),
    );
  }

  Widget _buildNodeImage(String pathOrUrl) {
    if (!pathOrUrl.startsWith('http://') && !pathOrUrl.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(pathOrUrl),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _DarkImageFallback(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: pathOrUrl,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => const _DarkImageFallback(),
      ),
    );
  }

  Future<void> _showEditDialog({
    required String title,
    required TextEditingController controller,
    int maxLines = 1,
  }) async {
    _sheetInputController
      ..text = controller.text
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: controller.text.length),
      );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Material(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: TextField(
                        controller: _sheetInputController,
                        maxLines: maxLines,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFFF4F6FA),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
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
                  ],
                ),
              ),
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
      ..text = initial
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: initial.length),
      );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Material(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: TextField(
                        controller: _sheetInputController,
                        maxLines: field == _NodeField.description ? 6 : 1,
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFFF4F6FA),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
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
                          setState(() {
                            if (field == _NodeField.title) {
                              activity['title'] = _sheetInputController.text.trim();
                            } else {
                              activity['description'] =
                                  _sheetInputController.text.trim();
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
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    _sheetInputController.clear();
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

class _DottedPainter extends CustomPainter {
  _DottedPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final Path path = Path()..addRRect(rect);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      const double dash = 5;
      const double gap = 4;
      while (distance < metric.length) {
        final double end = math.min(metric.length, distance + dash);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}
