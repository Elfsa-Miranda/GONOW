import 'package:flutter/material.dart';

/// Flutter 启动页（第二阶段）
/// 在原生启动页之后显示，添加导入语文字
/// 背景色与原生启动页一致，实现无缝过渡
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 🚨 核心：这个页面的背景色必须和原生启动页完全相同
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, // 垂直居中
          children: [
            // 你的抠图 Logo，确保位置和静态页尽量一致
            Image.asset(
              'assets/icon/icon.png',
              height: 220, // 进一步放大 Logo（从 180 增加到 220）
            ),
            const SizedBox(height: 4), // Logo 与文字的间距（从 8 减小到 4）
            const Text(
              '开始你的足迹之旅',
              style: TextStyle(
                fontSize: 18,
                color: Color(0xFF666666), // 现代深灰色
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
