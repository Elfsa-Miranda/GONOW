import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 生成GoNow应用图标
/// 运行方式: flutter run -d <device> scripts/generate_icon.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 创建图标
  final iconWidget = Container(
    width: 1024,
    height: 1024,
    decoration: BoxDecoration(
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
      borderRadius: BorderRadius.circular(225), // 22% 圆角
    ),
    child: Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 文字阴影
          Positioned(
            left: 20,
            top: 20,
            child: Text(
              'GO！',
              style: TextStyle(
                fontSize: 358,
                fontWeight: FontWeight.w900,
                color: Colors.black.withOpacity(0.15),
                letterSpacing: -10,
                height: 1.0,
              ),
            ),
          ),
          // 主文字
          Text(
            'GO！',
            style: TextStyle(
              fontSize: 358,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: -10,
              height: 1.0,
              shadows: [
                Shadow(
                  color: Colors.black.withOpacity(0.25),
                  offset: const Offset(8, 8),
                  blurRadius: 16,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  print('请使用以下步骤生成图标：');
  print('1. 在线生成工具：访问 https://icon.kitchen/');
  print('2. 上传一个临时图片，然后使用自定义设计');
  print('3. 或者使用 Figma/Photoshop 等工具手动创建 1024x1024 的图标');
  print('4. 将生成的图标保存为 assets/icon/icon.png');
  print('5. 运行: flutter pub get');
  print('6. 运行: dart run flutter_launcher_icons');
}
