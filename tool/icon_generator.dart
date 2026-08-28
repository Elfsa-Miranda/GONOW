import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// GoNow图标生成器
/// 
/// 使用方法：
/// 1. 创建一个临时Flutter项目或在现有项目中运行
/// 2. flutter run tool/icon_generator.dart
/// 3. 点击"生成图标"按钮
/// 4. 图标将保存到 assets/icon/icon.png

void main() {
  runApp(const IconGeneratorApp());
}

class IconGeneratorApp extends StatelessWidget {
  const IconGeneratorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoNow Icon Generator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const IconGeneratorScreen(),
    );
  }
}

class IconGeneratorScreen extends StatefulWidget {
  const IconGeneratorScreen({super.key});

  @override
  State<IconGeneratorScreen> createState() => _IconGeneratorScreenState();
}

class _IconGeneratorScreenState extends State<IconGeneratorScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  bool _isGenerating = false;
  String _status = '准备生成图标';

  Future<void> _generateIcon() async {
    setState(() {
      _isGenerating = true;
      _status = '正在生成图标...';
    });

    try {
      // 等待渲染完成
      await Future.delayed(const Duration(milliseconds: 500));

      // 获取RenderRepaintBoundary
      RenderRepaintBoundary boundary = _repaintKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;

      // 转换为图片
      ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      // 保存文件
      final directory = Directory('assets/icon');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final file = File('assets/icon/icon.png');
      await file.writeAsBytes(pngBytes);

      setState(() {
        _status = '✅ 图标已生成！\n保存位置: ${file.path}';
        _isGenerating = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('图标生成成功！'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _status = '❌ 生成失败: $e';
        _isGenerating = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('生成失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GoNow 图标生成器'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '预览图标：',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            // 图标预览
            RepaintBoundary(
              key: _repaintKey,
              child: _buildIcon(),
            ),
            const SizedBox(height: 40),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _isGenerating ? null : _generateIcon,
              icon: _isGenerating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_isGenerating ? '生成中...' : '生成图标'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 40),
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                '生成后的步骤：\n'
                '1. 运行: flutter pub get\n'
                '2. 运行: dart run flutter_launcher_icons\n'
                '3. 重新构建应用',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIcon() {
    return Container(
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
  }
}
