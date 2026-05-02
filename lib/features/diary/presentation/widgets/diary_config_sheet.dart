import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

enum DiaryCreateMode { itinerary, retro }

class DiaryConfigResult {
  const DiaryConfigResult({
    required this.mode,
    required this.styleType,
    required this.selectedTripId,
    required this.locationText,
    required this.imagePaths,
  });

  final DiaryCreateMode mode;
  final String styleType;
  final String? selectedTripId;
  final String locationText;
  final List<String> imagePaths;
}

Future<DiaryConfigResult?> showDiaryConfigSheet(
  BuildContext context, {
  List<Map<String, String>> tripOptions = const <Map<String, String>>[
    <String, String>{'id': 'trip_beijing', 'title': '北京 5 天亲子行'},
    <String, String>{'id': 'trip_hangzhou', 'title': '杭州 3 天慢游'},
    <String, String>{'id': 'trip_chengdu', 'title': '成都 4 天美食局'},
  ],
}) {
  return showModalBottomSheet<DiaryConfigResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: const _DiaryConfigSheetBody(),
      );
    },
  );
}

class _DiaryConfigSheetBody extends StatefulWidget {
  const _DiaryConfigSheetBody();

  @override
  State<_DiaryConfigSheetBody> createState() => _DiaryConfigSheetBodyState();
}

class _DiaryConfigSheetBodyState extends State<_DiaryConfigSheetBody>
    with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _retroLocationController =
      TextEditingController();

  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  final List<Map<String, String>> _tripOptions = const <Map<String, String>>[
    <String, String>{'id': 'trip_beijing', 'title': '北京 5 天亲子行'},
    <String, String>{'id': 'trip_hangzhou', 'title': '杭州 3 天慢游'},
    <String, String>{'id': 'trip_chengdu', 'title': '成都 4 天美食局'},
  ];
  final List<_StyleItem> _styleItems = const <_StyleItem>[
    _StyleItem(label: '🍃 文艺清新', color: Color(0xFF5E9E7B)),
    _StyleItem(label: '🎬 电影质感', color: Color(0xFF5C6BC0)),
    _StyleItem(label: '🌈 多巴胺色彩', color: Color(0xFFE91E63)),
    _StyleItem(label: '🍔 饕餮食客', color: Color(0xFFFF7043)),
    _StyleItem(label: '🪖 硬核特种兵', color: Color(0xFF546E7A)),
    _StyleItem(label: '🌑 孤独探索者', color: Color(0xFF616161)),
    _StyleItem(label: '🏕 荒野露营派', color: Color(0xFF2E7D32)),
    _StyleItem(label: '🧘 慢生活疗愈', color: Color(0xFF8E24AA)),
    _StyleItem(label: '🏛 城市建筑控', color: Color(0xFF3949AB)),
    _StyleItem(label: '🎧 夜色霓虹流', color: Color(0xFF00897B)),
  ];

  String _selectedStyle = '🍃 文艺清新';
  String _selectedTripId = 'trip_beijing';
  final List<String> _pickedImagePaths = <String>[];
  bool _submitting = false;

  @override
  void dispose() {
    _retroLocationController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final List<XFile> result = await _picker.pickMultiImage(
      imageQuality: 88,
      maxWidth: 1800,
    );
    if (result.isEmpty) return;
    setState(() {
      _pickedImagePaths.addAll(
        result.map((XFile item) => item.path).where((String e) => e.isNotEmpty),
      );
    });
  }

  Future<void> _submit() async {
    final bool isRetro = _tabController.index == 1;
    if (isRetro && _retroLocationController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写你去哪儿了')),
      );
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    Navigator.of(context).pop(
      DiaryConfigResult(
        mode: isRetro ? DiaryCreateMode.retro : DiaryCreateMode.itinerary,
        styleType: _selectedStyle,
        selectedTripId: isRetro ? null : _selectedTripId,
        locationText: _retroLocationController.text.trim(),
        imagePaths: List<String>.from(_pickedImagePaths),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: Material(
        color: Colors.white,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.86,
            child: Column(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(top: 10, bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0E3E8),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F4F8),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      indicator: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      labelColor: const Color(0xFF111827),
                      unselectedLabelColor: const Color(0xFF6B7280),
                      labelStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      tabs: const <Widget>[
                        Tab(text: '关联已有行程'),
                        Tab(text: '补录往期精彩'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: <Widget>[
                      _buildItineraryMode(),
                      _buildRetroMode(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: <Color>[Color(0xFF8E2DE2), Color(0xFF4A00E0)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x443F51B5),
                            blurRadius: 18,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: TextButton(
                        onPressed: _submitting ? null : _submit,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                '✨ AI 一键生成手账',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
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
      ),
    );
  }

  Widget _buildItineraryMode() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFDDE3EE)),
            color: const Color(0xFFF7F9FC),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedTripId,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              borderRadius: BorderRadius.circular(14),
              items: _tripOptions
                  .map(
                    (Map<String, String> option) => DropdownMenuItem<String>(
                      value: option['id'],
                      child: Text(option['title'] ?? ''),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (String? value) {
                if (value == null) return;
                setState(() => _selectedTripId = value);
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildStyleGrid(),
      ],
    );
  }

  Widget _buildRetroMode() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      children: <Widget>[
        SizedBox(
          height: 96,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _pickedImagePaths.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == _pickedImagePaths.length) {
                return GestureDetector(
                  onTap: _pickImages,
                  child: Container(
                    width: 88,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F5F8),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFD9DEE6)),
                    ),
                    child: const Icon(
                      Icons.add_photo_alternate_outlined,
                      color: Color(0xFF657388),
                    ),
                  ),
                );
              }
              return Container(
                width: 88,
                margin: const EdgeInsets.only(right: 10),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.file(
                  File(_pickedImagePaths[index]),
                  fit: BoxFit.cover,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: TextField(
            controller: _retroLocationController,
            decoration: InputDecoration(
              hintText: '你去哪儿了？',
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              filled: true,
              fillColor: const Color(0xFFF6F8FB),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F8ED),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFB4E0C1)),
          ),
          child: const Row(
            children: <Widget>[
              Icon(Icons.shield_moon_outlined, size: 18, color: Color(0xFF2E7D32)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '隐私保护：系统不会读取照片位置信息',
                  style: TextStyle(
                    color: Color(0xFF2E7D32),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildStyleGrid(),
      ],
    );
  }

  Widget _buildStyleGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _styleItems.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.7,
      ),
      itemBuilder: (BuildContext context, int index) {
        final _StyleItem style = _styleItems[index];
        final bool selected = style.label == _selectedStyle;
        return GestureDetector(
          onTap: () => setState(() => _selectedStyle = style.label),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? style.color.withValues(alpha: 0.12) : const Color(0xFFF4F6F8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? style.color : const Color(0xFFE1E6ED),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Text(
              style.label,
              style: TextStyle(
                fontSize: 13,
                color: selected ? const Color(0xFF111827) : const Color(0xFF4B5563),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StyleItem {
  const _StyleItem({required this.label, required this.color});

  final String label;
  final Color color;
}
