import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _DiaryConfigSheetBodyState extends State<_DiaryConfigSheetBody> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _retroLocationController =
      TextEditingController();
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
  int _selectedModeIndex = 0;
  bool _submitting = false;

  @override
  void dispose() {
    _retroLocationController.dispose();
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
    final bool isRetro = _selectedModeIndex == 1;
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
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: Material(
        color: Colors.white,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.86,
            child: Column(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: _buildModeTab(
                            label: '关联已有行程',
                            selected: _selectedModeIndex == 0,
                            onTap: () {
                              if (_selectedModeIndex == 0) return;
                              HapticFeedback.lightImpact();
                              setState(() => _selectedModeIndex = 0);
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _buildModeTab(
                            label: '补录往期精彩',
                            selected: _selectedModeIndex == 1,
                            onTap: () {
                              if (_selectedModeIndex == 1) return;
                              HapticFeedback.lightImpact();
                              setState(() => _selectedModeIndex = 1);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _selectedModeIndex == 0
                        ? _buildItineraryMode(
                            key: const ValueKey<String>('itinerary_mode'),
                          )
                        : _buildRetroMode(
                            key: const ValueKey<String>('retro_mode'),
                          ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: <Color>[
                              Colors.indigo.shade500,
                              Colors.purple.shade500,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.indigo.withValues(alpha: 0.3),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeTab({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.indigo.shade700 : Colors.grey.shade500,
          ),
        ),
      ),
    );
  }

  Widget _buildItineraryMode({Key? key}) {
    return ListView(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
            color: Colors.grey.shade50,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.blue.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.map_rounded,
                  size: 18,
                  color: Colors.indigo.shade500,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
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
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildStyleGrid(),
      ],
    );
  }

  Widget _buildRetroMode({Key? key}) {
    return ListView(
      key: key,
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
        childAspectRatio: 1.95,
      ),
      itemBuilder: (BuildContext context, int index) {
        final _StyleItem style = _styleItems[index];
        final bool selected = style.label == _selectedStyle;
        final String emoji = style.label.split(' ').first;
        final String label = style.label.replaceFirst('$emoji ', '');
        return GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _selectedStyle = style.label);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? Colors.indigo.shade50 : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? Colors.indigo.shade400 : Colors.transparent,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(emoji, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? const Color(0xFF111827)
                        : const Color(0xFF4B5563),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
