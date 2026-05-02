import 'package:flutter/material.dart';

/// 全屏横向滑动 + 双指缩放；由调用方提供每张图的渲染（本地路径 / 网络 / blob 等）。
void showFullScreenPhotoGallery(
  BuildContext context,
  List<String> photos,
  int initialIndex, {
  required Widget Function(String pathOrUrl) imageBuilder,
}) {
  if (photos.isEmpty) return;
  FocusScope.of(context).unfocus();
  final int safeIndex = initialIndex.clamp(0, photos.length - 1);
  Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      pageBuilder:
          (BuildContext context, Animation<double> animation,
              Animation<double> secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: FullScreenPhotoGalleryOverlay(
            photos: photos,
            initialIndex: safeIndex,
            imageBuilder: imageBuilder,
          ),
        );
      },
    ),
  );
}

class FullScreenPhotoGalleryOverlay extends StatefulWidget {
  const FullScreenPhotoGalleryOverlay({
    required this.photos,
    required this.initialIndex,
    required this.imageBuilder,
    super.key,
  });

  final List<String> photos;
  final int initialIndex;
  final Widget Function(String pathOrUrl) imageBuilder;

  @override
  State<FullScreenPhotoGalleryOverlay> createState() =>
      _FullScreenPhotoGalleryOverlayState();
}

class _FullScreenPhotoGalleryOverlayState
    extends State<FullScreenPhotoGalleryOverlay> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _currentIndex = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double statusTop = MediaQuery.paddingOf(context).top;
    // 与 PageView 同一层 Stack + 显式避让刘海，× 与页码同一横排贴屏幕左上 / 右上
    final double rowTop = statusTop + 4;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: <Widget>[
          PageView.builder(
            controller: _pageController,
            physics: const BouncingScrollPhysics(),
            itemCount: widget.photos.length,
            onPageChanged: (int index) {
              setState(() => _currentIndex = index);
            },
            itemBuilder: (BuildContext context, int index) {
              final String pathOrUrl = widget.photos[index];
              return InteractiveViewer(
                key: ValueKey<String>('gallery_${index}_$pathOrUrl'),
                minScale: 0.8,
                maxScale: 4.0,
                child: Center(
                  child: widget.imageBuilder(pathOrUrl),
                ),
              );
            },
          ),
          Positioned(
            top: rowTop,
            left: 4,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 44,
                minHeight: 44,
              ),
              icon: const Icon(
                Icons.close,
                color: Colors.white,
                size: 28,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            top: rowTop,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '${_currentIndex + 1} / ${widget.photos.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
