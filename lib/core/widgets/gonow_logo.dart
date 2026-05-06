import 'package:flutter/material.dart';

/// GoNow Logo Widget
/// 完全复现设计图的logo，包含渐变背景和"GO！"文字
class GoNowLogo extends StatelessWidget {
  final double size;
  final double? width;
  final double? height;

  const GoNowLogo({
    super.key,
    this.size = 120,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final logoWidth = width ?? size;
    final logoHeight = height ?? size;

    return Container(
      width: logoWidth,
      height: logoHeight,
      decoration: BoxDecoration(
        // 从左上角蓝色到右下角紫色的渐变
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF4A90E2), // 左上角蓝色
            Color(0xFF7B68EE), // 中间蓝紫色
            Color(0xFF9B59D0), // 右下角紫色
          ],
          stops: [0.0, 0.5, 1.0],
        ),
        // 圆角矩形
        borderRadius: BorderRadius.circular(logoWidth * 0.22),
        // 轻微的外阴影
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Stack(
          children: [
            // 文字阴影层
            Positioned(
              left: logoWidth * 0.02,
              top: logoHeight * 0.02,
              child: Text(
                'GO！',
                style: TextStyle(
                  fontSize: logoWidth * 0.35,
                  fontWeight: FontWeight.w900,
                  color: Colors.black.withOpacity(0.15),
                  letterSpacing: -2,
                  height: 1.0,
                ),
              ),
            ),
            // 主文字层
            Text(
              'GO！',
              style: TextStyle(
                fontSize: logoWidth * 0.35,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: -2,
                height: 1.0,
                shadows: [
                  Shadow(
                    color: Colors.black.withOpacity(0.25),
                    offset: const Offset(2, 2),
                    blurRadius: 4,
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

/// 小尺寸的GoNow Logo（用于导航栏等）
class GoNowLogoSmall extends StatelessWidget {
  const GoNowLogoSmall({super.key});

  @override
  Widget build(BuildContext context) {
    return const GoNowLogo(size: 40);
  }
}

/// 中等尺寸的GoNow Logo（用于启动页等）
class GoNowLogoMedium extends StatelessWidget {
  const GoNowLogoMedium({super.key});

  @override
  Widget build(BuildContext context) {
    return const GoNowLogo(size: 120);
  }
}

/// 大尺寸的GoNow Logo（用于欢迎页等）
class GoNowLogoLarge extends StatelessWidget {
  const GoNowLogoLarge({super.key});

  @override
  Widget build(BuildContext context) {
    return const GoNowLogo(size: 200);
  }
}
