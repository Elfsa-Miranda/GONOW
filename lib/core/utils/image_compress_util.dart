import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// 相册多选后的静默压缩，降低内存峰值与磁盘占用（Web 下不压缩，原样返回）。
class ImageCompressUtil {
  static const int _maxBytes = 1024 * 1024;
  static const int _maxConcurrent = 4;

  /// 批量压缩；单张尽量压到约 1MB 以内，失败则回退原图。
  static Future<List<XFile>> compressImages(List<XFile> originalFiles) async {
    if (originalFiles.isEmpty) return <XFile>[];
    if (kIsWeb) {
      return List<XFile>.from(originalFiles);
    }
    final Directory tempDir = await getTemporaryDirectory();
    final int tick = DateTime.now().microsecondsSinceEpoch;
    final List<XFile> out = <XFile>[];

    for (int start = 0; start < originalFiles.length; start += _maxConcurrent) {
      final int end = (start + _maxConcurrent > originalFiles.length)
          ? originalFiles.length
          : start + _maxConcurrent;
      final List<Future<XFile>> chunk = <Future<XFile>>[];
      for (int i = start; i < end; i++) {
        chunk.add(_compressOne(originalFiles[i], tempDir, tick, i));
      }
      out.addAll(await Future.wait(chunk));
    }
    return out;
  }

  static Future<XFile> _compressOne(
    XFile file,
    Directory tempDir,
    int tick,
    int index,
  ) async {
    try {
      final File src = File(file.path);
      if (!await src.exists()) {
        return file;
      }
      final String safeName =
          file.name.replaceAll(RegExp(r'[^\w\-.]+'), '_').trim();
      final String stem =
          safeName.isEmpty ? 'photo.jpg' : safeName;
      int quality = 82;
      for (int round = 0; round < 6; round++) {
        final String targetPath =
            '${tempDir.path}/cmp_${tick}_${index}_r${round}_q${quality}_$stem.jpg';
        final XFile? result = await FlutterImageCompress.compressAndGetFile(
          file.path,
          targetPath,
          quality: quality,
          minWidth: 1440,
          minHeight: 1440,
          format: CompressFormat.jpeg,
        );
        if (result == null) {
          return file;
        }
        final int len = await File(result.path).length();
        if (len <= _maxBytes || quality <= 38) {
          return result;
        }
        try {
          await File(result.path).delete();
        } catch (_) {}
        quality -= 12;
      }
    } catch (e, st) {
      debugPrint('ImageCompressUtil: $e\n$st');
    }
    return file;
  }
}
