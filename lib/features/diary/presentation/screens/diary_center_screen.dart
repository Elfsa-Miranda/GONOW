import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

/// 手账瀑布流封面：网络 URL 与本地文件路径（补录草稿）混合渲染。
Widget _buildSmartDiaryCoverImage(String url, double height) {
  if (url.isEmpty) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Container(
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.image, color: Colors.grey),
      ),
    );
  }
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      width: double.infinity,
      height: height,
      errorWidget: (BuildContext context, String imageUrl, Object error) =>
          SizedBox(
        width: double.infinity,
        height: height,
        child: const _ImageErrorFallback(),
      ),
    );
  }
  if (kIsWeb) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Container(
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(
          Icons.image_not_supported_outlined,
          color: Colors.grey,
        ),
      ),
    );
  }
  return Image.file(
    File(url),
    fit: BoxFit.cover,
    width: double.infinity,
    height: height,
    errorBuilder:
        (BuildContext context, Object error, StackTrace? stackTrace) =>
            SizedBox(
      width: double.infinity,
      height: height,
      child: const _ImageErrorFallback(),
    ),
  );
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
    await showDiaryConfigSheet(context);
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
    return Consumer<DiaryProvider>(
      builder: (BuildContext context, DiaryProvider diaryProvider, Widget? _) {
        final List<DiaryModel> myDiaries = diaryProvider.myDiaries;
        final int draftsCount = diaryProvider.drafts.length;
        final bool showEmpty = myDiaries.isEmpty && draftsCount == 0;
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
                                      '${myDiaries.length + draftsCount}',
                                  style: TextStyle(
                                    color: Colors.indigo.shade500,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const TextSpan(text: ' 段 · 草稿 '),
                                TextSpan(
                                  text: '$draftsCount',
                                  style: TextStyle(
                                    color: Colors.indigo.shade500,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const TextSpan(text: ' · 社区精选 '),
                                TextSpan(
                                  text: '${diaryProvider.communityDiaries.length}',
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
            sliver: showEmpty
                ? SliverToBoxAdapter(
                    child: _DiaryEmptyState(
                      onCreate: () => _onCreateDiary(context),
                    ),
                  )
                : SliverMasonryGrid.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childCount: myDiaries.length + 1,
                    itemBuilder: (BuildContext context, int index) {
                      if (index == 0) {
                        return _StaggerReveal(
                          index: index,
                          enabled: false,
                          child: _DraftEntryCard(
                            draftCount: draftsCount,
                            onTap: () =>
                                _openDraftBox(context, diaryProvider.drafts),
                          ),
                        );
                      }
                      final DiaryModel diary = myDiaries[index - 1];
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
      },
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
                  '$draftCount 篇待完成',
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
    final String dateLabel = diary.createdAt != null
        ? '${diary.createdAt!.year.toString().padLeft(4, '0')}.${diary.createdAt!.month.toString().padLeft(2, '0')}.${diary.createdAt!.day.toString().padLeft(2, '0')}'
        : (diary.diaryData['dateLabel'] ?? '2026.01.01')
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
      onLongPress: () async {
        final bool? confirm = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('删除手账'),
            content: const Text(
              '确定要永久删除这篇手账吗？此操作将清理相关图片与数据，且无法恢复。',
            ),
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
        if (confirm != true || !context.mounted) return;
        final DiaryProvider provider = Provider.of<DiaryProvider>(
          context,
          listen: false,
        );
        final bool success = await provider.deleteDiary(diary.id);
        if (!context.mounted) return;
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('手账已删除')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('删除失败，请检查网络连接后重试'),
            ),
          );
        }
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
                  child: _buildSmartDiaryCoverImage(
                    diary.coverImageUrl,
                    140 + (diary.id.codeUnitAt(0) % 2) * 40,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiaryEmptyState extends StatelessWidget {
  const _DiaryEmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE6EBF3)),
      ),
      child: Column(
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4FF),
              borderRadius: BorderRadius.circular(20),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.auto_stories_outlined,
              size: 32,
              color: Color(0xFF5B6DF6),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '还没有记录任何回忆',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '快点击下方按钮制作吧~',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: onCreate,
            child: const Text('立即创建'),
          ),
        ],
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
