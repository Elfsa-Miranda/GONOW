import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:gonow/core/utils/image_compress_util.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:gonow/features/diary/presentation/screens/diary_detail_screen.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

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
  // 在进入 showModalBottomSheet 之前保存外层 context 的导航器与 ScaffoldMessenger。
  // builder 内部的 (BuildContext context) 会把外层 context 遮蔽（shadow），
  // 如果在 builder 内用被遮蔽的 context 调用 maybePop / push，
  // 拿到的是 BottomSheet 子路由的 Navigator，而非真正的根 Navigator，
  // 导致 pop+push 在同一帧操作两个 Overlay，触发 GlobalKey 重复崩溃。
  final NavigatorState outerNav = Navigator.of(context);
  final ScaffoldMessengerState outerMessenger = ScaffoldMessenger.of(context);
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

  final ImagePicker picker = ImagePicker();
  bool isCustomMode = false;
  /// `lazy` 懒人照片池；`detailed` 精细日记（仅补录模式）
  String subRecordMode = 'lazy';
  String selectedStyle = '文艺清新';
  bool isGenerating = false;
  String? errorMessage;
  final TextEditingController destinationController = TextEditingController();
  final List<XFile> selectedPhotos = <XFile>[];
  XFile? detailCoverPhoto;

  await showModalBottomSheet<void>(
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
                                    setModalState(() {
                                      isCustomMode = false;
                                      subRecordMode = 'lazy';
                                      selectedPhotos.clear();
                                      detailCoverPhoto = null;
                                      errorMessage = null;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    decoration: BoxDecoration(
                                      color: !isCustomMode
                                          ? Colors.white
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: !isCustomMode
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
                                        fontWeight: !isCustomMode
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: !isCustomMode
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
                                    setModalState(() {
                                      isCustomMode = true;
                                      subRecordMode = 'lazy';
                                      errorMessage = null;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isCustomMode
                                          ? Colors.white
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: isCustomMode
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
                                        fontWeight: isCustomMode
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: isCustomMode
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
                              if (!isCustomMode) ...<Widget>[
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.grey.shade200),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.02),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    children: <Widget>[
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade100,
                                          borderRadius: BorderRadius.circular(12),
                                          image: const DecorationImage(
                                            image: NetworkImage(
                                              'https://images.unsplash.com/photo-1508804185872-d7badad00f7d?w=200',
                                            ),
                                            fit: BoxFit.cover,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      const Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              '北京五日带父母舒心游',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 15,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            SizedBox(height: 6),
                                            Row(
                                              children: <Widget>[
                                                Icon(
                                                  Icons.circle,
                                                  size: 8,
                                                  color: Colors.green,
                                                ),
                                                SizedBox(width: 6),
                                                Text(
                                                  '刚结束',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.green,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      Icon(Icons.check_circle, color: Colors.indigo),
                                    ],
                                  ),
                                ),
                              ],
                              if (isCustomMode) ...<Widget>[
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
                                            setModalState(() {
                                              subRecordMode = 'lazy';
                                              errorMessage = null;
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: subRecordMode == 'lazy'
                                                  ? Colors.white
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                              boxShadow: subRecordMode == 'lazy'
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
                                                  fontWeight: subRecordMode == 'lazy'
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: subRecordMode == 'lazy'
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
                                            setModalState(() {
                                              subRecordMode = 'detailed';
                                              errorMessage = null;
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(vertical: 8),
                                            decoration: BoxDecoration(
                                              color: subRecordMode == 'detailed'
                                                  ? Colors.white
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(8),
                                              boxShadow: subRecordMode == 'detailed'
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
                                                  fontWeight: subRecordMode == 'detailed'
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  color: subRecordMode == 'detailed'
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
                                if (subRecordMode == 'lazy') ...<Widget>[
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
                                      itemCount: selectedPhotos.length +
                                          (selectedPhotos.length < 20 ? 1 : 0),
                                      itemBuilder: (BuildContext context, int index) {
                                        if (index == selectedPhotos.length) {
                                          return GestureDetector(
                                            onTap: () async {
                                              final int remaining =
                                                  20 - selectedPhotos.length;
                                              if (remaining <= 0) return;
                                              List<XFile> files = <XFile>[];
                                              try {
                                                files = await picker.pickMultiImage(
                                                  limit: 20,
                                                );
                                              } catch (_) {
                                                final XFile? one =
                                                    await picker.pickImage(
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
                                              setModalState(() {
                                                selectedPhotos.addAll(
                                                  optimized.take(remaining),
                                                );
                                                while (selectedPhotos.length >
                                                    20) {
                                                  selectedPhotos.removeLast();
                                                }
                                                errorMessage = null;
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
                                                File(selectedPhotos[index].path),
                                                fit: BoxFit.cover,
                                              ),
                                              Positioned(
                                                top: 4,
                                                right: 4,
                                                child: GestureDetector(
                                                  onTap: () {
                                                    setModalState(() {
                                                      selectedPhotos.removeAt(index);
                                                      errorMessage = null;
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
                                      controller: destinationController,
                                      onChanged: (String _) {
                                        if (errorMessage != null) {
                                          setModalState(() => errorMessage = null);
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
                                      final XFile? file = await picker.pickImage(
                                        source: ImageSource.gallery,
                                      );
                                      if (file == null) return;
                                      setModalState(() {
                                        detailCoverPhoto = file;
                                        errorMessage = null;
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
                                      child: detailCoverPhoto == null
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
                                                  File(detailCoverPhoto!.path),
                                                  fit: BoxFit.cover,
                                                ),
                                                Positioned(
                                                  top: 8,
                                                  right: 8,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      setModalState(() {
                                                        detailCoverPhoto = null;
                                                        errorMessage = null;
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
                                      controller: destinationController,
                                      maxLines: 4,
                                      onChanged: (String _) {
                                        if (errorMessage != null) {
                                          setModalState(() => errorMessage = null);
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
                                      selectedStyle == style['name'];
                                  return GestureDetector(
                                    onTap: () {
                                      setModalState(() {
                                        selectedStyle = style['name']!;
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
                      if (errorMessage != null)
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
                                errorMessage!,
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
                            onPressed: () async {
                              FocusManager.instance.primaryFocus?.unfocus();
                              FocusScope.of(context).unfocus();
                              setModalState(() => errorMessage = null);
                              await Future<void>.delayed(
                                const Duration(milliseconds: 100),
                              );
                              if (!context.mounted) return;

                              if (isCustomMode) {
                                if (destinationController.text.trim().isEmpty) {
                                  setModalState(() {
                                    errorMessage = subRecordMode == 'detailed'
                                        ? '请填写详细行程描述'
                                        : '请告诉管家您去过的目的地哦';
                                  });
                                  return;
                                }
                                if (subRecordMode == 'lazy' && selectedPhotos.isEmpty) {
                                  setModalState(() {
                                    errorMessage = '请至少上传一张旅途照片';
                                  });
                                  return;
                                }
                                if (subRecordMode == 'detailed' && detailCoverPhoto == null) {
                                  setModalState(() {
                                    errorMessage = '请选择一张手账封面图';
                                  });
                                  return;
                                }
                              }

                              final ItineraryProvider itineraryProvider =
                                  Provider.of<ItineraryProvider>(
                                context,
                                listen: false,
                              );
                              final ItineraryModel? existingItinerary = isCustomMode
                                  ? null
                                  : (itineraryProvider.activeItinerary ??
                                      itineraryProvider.currentItinerary);

                              if (!isCustomMode && existingItinerary == null) {
                                setModalState(() {
                                  errorMessage = '未找到可关联的已有行程';
                                });
                                return;
                              }

                              setModalState(() => isGenerating = true);
                              final DiaryProvider diaryProvider =
                                  Provider.of<DiaryProvider>(
                                context,
                                listen: false,
                              );
                              final Map<String, dynamic>? aiGeneratedData =
                                  await diaryProvider.generateDiaryFromAI(
                                destination: isCustomMode
                                    ? destinationController.text.trim()
                                    : _extractDestination(existingItinerary),
                                style: selectedStyle,
                                existingPlanData: existingItinerary?.planData,
                                subRecordMode: isCustomMode ? subRecordMode : null,
                                customPhotoCount:
                                    isCustomMode && subRecordMode == 'lazy'
                                        ? selectedPhotos.length
                                        : null,
                              );
                              if (!context.mounted) return;

                              if (aiGeneratedData == null) {
                                setModalState(() {
                                  isGenerating = false;
                                  errorMessage = 'AI 思考超时了，请检查网络后重试';
                                });
                                return;
                              }

                              // 🚨 3. 【绝对防御：结构锁死、深拷贝与反向文本注入】
                              Map<String, dynamic> finalDiaryData;
                              String? autoCoverImageUrl;
                              if (!isCustomMode && existingItinerary != null) {
                                // 关联模式：坚守原有行程作为“绝对骨架”（深拷贝）
                                finalDiaryData = jsonDecode(
                                  jsonEncode(existingItinerary.planData),
                                ) as Map<String, dynamic>;
                                finalDiaryData['quote'] =
                                    aiGeneratedData['quote'] ??
                                    '用$selectedStyle的方式，记录这段闪光的日子。';
                                finalDiaryData['dateLabel'] =
                                    aiGeneratedData['dateLabel'] ?? '刚刚生成';

                                try {
                                  final List<dynamic> orgDays =
                                      (finalDiaryData['days'] as List<dynamic>?) ??
                                      (finalDiaryData['daily_schedules']
                                              as List<dynamic>?) ??
                                      <dynamic>[];
                                  final List<dynamic>? aiDays =
                                      aiGeneratedData['days'] as List<dynamic>?;

                                  // 智能首图提取：遍历原行程，找到第一张有效图片作为封面
                                  for (final dynamic dayRaw in orgDays) {
                                    if (autoCoverImageUrl != null) break;
                                    final Map<String, dynamic> dayMap =
                                        Map<String, dynamic>.from(
                                      dayRaw as Map? ?? <String, dynamic>{},
                                    );
                                    final List<dynamic> acts =
                                        (dayMap['activities'] as List<dynamic>?) ??
                                        <dynamic>[];
                                    for (final dynamic actRaw in acts) {
                                      final Map<String, dynamic> actMap =
                                          Map<String, dynamic>.from(
                                        actRaw as Map? ?? <String, dynamic>{},
                                      );
                                      final List<dynamic> images =
                                          (actMap['images'] as List<dynamic>?) ??
                                          <dynamic>[];
                                      if (images.isNotEmpty) {
                                        autoCoverImageUrl =
                                            images.first.toString().trim();
                                        if (autoCoverImageUrl.isNotEmpty) break;
                                      }
                                      final String imageUrl =
                                          (actMap['imageUrl'] ?? '').toString().trim();
                                      if (imageUrl.isNotEmpty) {
                                        autoCoverImageUrl = imageUrl;
                                        break;
                                      }
                                    }
                                  }
                                  if (aiDays != null) {
                                    for (int i = 0; i < orgDays.length; i++) {
                                      if (i >= aiDays.length) break;
                                      final Map<String, dynamic> orgDay =
                                          Map<String, dynamic>.from(
                                        orgDays[i] as Map? ??
                                            <String, dynamic>{},
                                      );
                                      final Map<String, dynamic> aiDay =
                                          Map<String, dynamic>.from(
                                        aiDays[i] as Map? ?? <String, dynamic>{},
                                      );
                                      if (aiDay['summary'] != null) {
                                        orgDay['summary'] = aiDay['summary'];
                                      }
                                      final List<dynamic> orgActs =
                                          (orgDay['activities']
                                              as List<dynamic>?) ??
                                          <dynamic>[];
                                      final List<dynamic>? aiActs =
                                          aiDay['activities'] as List<dynamic>?;
                                      if (aiActs != null) {
                                        for (int j = 0; j < orgActs.length; j++) {
                                          if (j >= aiActs.length) break;
                                          final Map<String, dynamic> orgAct =
                                              Map<String, dynamic>.from(
                                            orgActs[j] as Map? ??
                                                <String, dynamic>{},
                                          );
                                          final Map<String, dynamic> aiAct =
                                              Map<String, dynamic>.from(
                                            aiActs[j] as Map? ??
                                                <String, dynamic>{},
                                          );
                                          if (aiAct['description'] != null) {
                                            orgAct['description'] =
                                                aiAct['description'];
                                          }
                                          if (aiAct['tag'] != null) {
                                            orgAct['tag'] = aiAct['tag'];
                                          }
                                          orgActs[j] = orgAct;
                                        }
                                      }
                                      orgDay['activities'] = orgActs;
                                      orgDays[i] = orgDay;
                                    }
                                  }
                                  if (finalDiaryData['days'] is List<dynamic>) {
                                    finalDiaryData['days'] = orgDays;
                                  } else if (finalDiaryData['daily_schedules']
                                      is List<dynamic>) {
                                    finalDiaryData['daily_schedules'] = orgDays;
                                  }
                                } catch (e) {
                                  debugPrint('🚨 文本反向注入发生异常，但不影响主干渲染: $e');
                                }
                              } else {
                                // 补录模式：信任 AI 生成骨架
                                finalDiaryData = aiGeneratedData;
                              }

                              if (isCustomMode && subRecordMode == 'lazy') {
                                _injectLazyPoolPhotosIntoLazyNode(
                                  finalDiaryData,
                                  selectedPhotos,
                                );
                              }

                              final String newDiaryId =
                                  'local_${DateTime.now().millisecondsSinceEpoch}';
                              final String extractedTitle =
                                  (aiGeneratedData['title'] ?? '').toString().trim();
                              final String newDiaryTitle = extractedTitle.isNotEmpty
                                  ? extractedTitle
                                  : (isCustomMode
                                      ? destinationController.text.trim()
                                      : existingItinerary!.title);
                              const String kDefaultDiaryCover =
                                  'https://images.unsplash.com/photo-1596484552834-6a58f850d0a1?w=800';
                              String finalCoverImg = kDefaultDiaryCover;
                              if (isCustomMode && selectedPhotos.isNotEmpty) {
                                finalCoverImg = selectedPhotos.first.path;
                              } else if (isCustomMode &&
                                  detailCoverPhoto != null) {
                                finalCoverImg = detailCoverPhoto!.path;
                              } else if (!isCustomMode &&
                                  existingItinerary != null) {
                                final String fromAi =
                                    (autoCoverImageUrl ?? '').trim();
                                final String fromPlan =
                                    _extractCoverImage(existingItinerary)
                                        .trim();
                                if (fromAi.isNotEmpty) {
                                  finalCoverImg = fromAi;
                                } else if (fromPlan.isNotEmpty) {
                                  finalCoverImg = fromPlan;
                                }
                              }

                              final DiaryModel generatedDiary = DiaryModel(
                                id: newDiaryId,
                                userId: 'current_user',
                                title: '✨ $newDiaryTitle',
                                authorName: '旅行者',
                                coverImageUrl: finalCoverImg,
                                isDraft: true,
                                isPublic: false,
                                styleType: selectedStyle,
                                diaryData: finalDiaryData,
                              );

                              if (!context.mounted) return;

                              FocusManager.instance.primaryFocus?.unfocus();
                              await Future<void>.delayed(
                                const Duration(milliseconds: 100),
                              );
                              if (!context.mounted) return;

                              // ── 修复：用外层 Navigator/ScaffoldMessenger 操作 ──
                              // 1. 先隐藏任何正在显示的 SnackBar（用外层 messenger，
                              //    避免在 builder context 的 Overlay 里操作）
                              outerMessenger.hideCurrentSnackBar();

                              // 2. 关闭 BottomSheet（用外层 nav 的 maybePop）
                              //    maybePop 是异步的，确保 BottomSheet Overlay 完全移除
                              if (outerNav.canPop()) {
                                await outerNav.maybePop();
                              }

                              // 3. 用 addPostFrameCallback 把 push 延迟到下一帧，
                              //    确保当前帧的 Overlay 销毁流程（_Theater finalizeTree）
                              //    完全结束后再挂载新路由，彻底消除 GlobalKey 重复。
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (outerNav.mounted) {
                                  outerNav.push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => DiaryDetailScreen(
                                        initialDiary: generatedDiary,
                                        startEditing: true,
                                      ),
                                    ),
                                  );
                                }
                              });
                            },
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
                  if (isGenerating)
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
                                  "AI 正在用『$selectedStyle』风格\n为您排版回忆...",
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
        },
      );
    },
  );

  destinationController.dispose();
}

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