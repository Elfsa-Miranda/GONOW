import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:gonow/features/diary/presentation/screens/diary_detail_screen.dart';
import 'package:gonow/features/diary/presentation/widgets/diary_config_sheet.dart';
import 'package:provider/provider.dart';

class DiaryCenterScreen extends StatefulWidget {
  const DiaryCenterScreen({super.key});

  @override
  State<DiaryCenterScreen> createState() => _DiaryCenterScreenState();
}

class _DiaryCenterScreenState extends State<DiaryCenterScreen> {
  bool _pageVisible = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pageVisible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _pageVisible = true);
    });
  }

  Future<void> _onCreateDiary(BuildContext context) async {
    HapticFeedback.lightImpact();
    final DiaryConfigResult? config = await showDiaryConfigSheet(context);
    if (config == null || !context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.all(Radius.circular(14)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'AI 正在编排你的手账...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!context.mounted) return;
    Navigator.of(context).pop();
    final DiaryModel generated = DiaryModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: config.mode == DiaryCreateMode.itinerary
          ? 'AI 旅行手账 · ${config.styleType}'
          : '${config.locationText} · 回忆手账',
      coverImageUrl:
          'https://images.unsplash.com/photo-1527631746610-bca00a040d60?auto=format&fit=crop&w=1200&q=80',
      authorName: '旅行者_Leo',
      isDraft: true,
      isPublic: false,
      styleType: config.styleType,
      diaryData: <String, dynamic>{
        'dateLabel': DateTime.now().toIso8601String().substring(0, 10),
        'likes': 0,
        'quote': '把走过的路写成句子，未来翻开仍会发光。',
        'summary': 'AI 已根据你的选择生成首版手账，进入编辑态可继续润色。',
        'days': <Map<String, dynamic>>[
          <String, dynamic>{
            'day': 1,
            'title': config.mode == DiaryCreateMode.itinerary
                ? '从行程自动提炼的第一天'
                : config.locationText,
            'description': '继续在编辑态补充细节、图片和旅行感受。',
            'photos': config.imagePaths,
            'lat': 39.9042,
            'lng': 116.4074,
          },
        ],
      },
    );
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DiaryDetailScreen(
          initialDiary: generated,
          startEditing: true,
        ),
      ),
    );
  }

  Future<void> _openDraftBox(
    BuildContext context,
    List<DiaryModel> drafts,
  ) async {
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
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: Material(
              color: Colors.white,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.72,
                  child: drafts.isEmpty
                      ? const Center(
                          child: Text(
                            '草稿箱暂时空空如也',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
                          itemCount: drafts.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (BuildContext context, int index) {
                            final DiaryModel diary = drafts[index];
                            return ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: const BorderSide(color: Color(0xFFE7EAF0)),
                              ),
                              tileColor: const Color(0xFFF8FAFD),
                              title: Text(
                                diary.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                diary.styleType,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () async {
                                Navigator.of(context).pop();
                                await Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => DiaryDetailScreen(
                                      initialDiary: diary,
                                      startEditing: true,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final DiaryProvider provider = context.watch<DiaryProvider>();
    final List<DiaryModel> display = <DiaryModel>[
      ...provider.myDiaries,
      ...provider.communityDiaries.where(
        (DiaryModel diary) =>
            !provider.myDiaries.any((DiaryModel mine) => mine.id == diary.id),
      ),
    ];
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        opacity: _pageVisible ? 1 : 0,
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 16,
                  left: 20,
                  right: 20,
                  bottom: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '✨ 你的数字旅行日记',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                        letterSpacing: -0.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Container(
                          width: 3,
                          height: 12,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: Colors.indigo.shade300,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Expanded(
                          child: RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                                fontWeight: FontWeight.w500,
                              ),
                              children: <InlineSpan>[
                                const TextSpan(text: '累计记录了 '),
                                TextSpan(
                                  text:
                                      '${provider.myDiaries.length + provider.drafts.length}',
                                  style: TextStyle(
                                    color: Colors.indigo.shade500,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const TextSpan(text: ' 段 · 草稿 '),
                                TextSpan(
                                  text: '${provider.drafts.length}',
                                  style: TextStyle(
                                    color: Colors.indigo.shade500,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const TextSpan(text: ' · 社区精选 '),
                                TextSpan(
                                  text: '${provider.communityDiaries.length}',
                                  style: TextStyle(
                                    color: Colors.indigo.shade500,
                                    fontWeight: FontWeight.w700,
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
              ),
            ),
            SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            sliver: SliverMasonryGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childCount: display.length + 1,
              itemBuilder: (BuildContext context, int index) {
                if (index == 0) {
                  return _StaggerReveal(
                    index: index,
                    enabled: false,
                    child: _DraftEntryCard(
                      draftCount: provider.drafts.length,
                      onTap: () => _openDraftBox(context, provider.drafts),
                    ),
                  );
                }
                final DiaryModel diary = display[index - 1];
                return _StaggerReveal(
                  index: index,
                  enabled: false,
                  child: _DiaryCard(diary: diary),
                );
              },
            ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 24,
        ),
        child: SizedBox(
          width: MediaQuery.of(context).size.width - 48,
          height: 56,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(24),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: TextButton(
              onPressed: () => _onCreateDiary(context),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          Colors.indigo.shade500,
                          Colors.purple.shade500,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.add, size: 16, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '制作新手账',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DraftEntryCard extends StatelessWidget {
  const _DraftEntryCard({required this.draftCount, required this.onTap});

  final int draftCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: const Color(0xFF9EA6B5),
            borderRadius: 20,
            strokeWidth: 1.6,
            dashLength: 6,
            gapLength: 4,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.edit_document,
                    size: 24,
                    color: Colors.indigo.shade400,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '草稿箱',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF374151),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$draftCount 条未发布',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiaryCard extends StatelessWidget {
  const _DiaryCard({required this.diary});

  final DiaryModel diary;

  @override
  Widget build(BuildContext context) {
    final int likes = (diary.diaryData['likes'] as num?)?.toInt() ?? 0;
    final String dateLabel = (diary.diaryData['dateLabel'] ?? '2026.01.01')
        .toString()
        .replaceAll('-', '.');
    return GestureDetector(
      onTap: () async {
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => DiaryDetailScreen(initialDiary: diary),
          ),
        );
      },
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Stack(
              children: <Widget>[
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  child: CachedNetworkImage(
                    imageUrl: diary.coverImageUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: 140 + (diary.id.codeUnitAt(0) % 2) * 40,
                    errorWidget: (_, _, _) => const _ImageErrorFallback(),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      dateLabel,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (diary.isPublic)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8B5CF6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '✨ 公开',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    diary.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      const Icon(
                        Icons.favorite_rounded,
                        size: 15,
                        color: Color(0xFFE11D48),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$likes',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF4B5563),
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
    );
  }
}

class _ImageErrorFallback extends StatelessWidget {
  const _ImageErrorFallback();

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
                colors: <Color>[Color(0x992A2E37), Color(0xFF111827)],
              ),
            ),
          ),
          const Center(
            child: Icon(Icons.photo_album_outlined, color: Colors.white70, size: 28),
          ),
        ],
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.borderRadius,
    required this.strokeWidth,
    required this.dashLength,
    required this.gapLength,
  });

  final Color color;
  final double borderRadius;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect rRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(borderRadius),
    );
    final Path path = Path()..addRRect(rRect);
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final PathMetrics metrics = path.computeMetrics();
    for (final PathMetric metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = distance + dashLength;
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashLength + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.gapLength != gapLength;
  }
}

class _StaggerReveal extends StatelessWidget {
  const _StaggerReveal({
    required this.index,
    required this.enabled,
    required this.child,
  });

  final int index;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
