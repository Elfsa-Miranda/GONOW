// lib/core/services/amap_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:gonow/core/constants/amap_config.dart';

class AmapService {
  // ─── 地理编码 ───────────────────────────────────────────────────
  /// 将地点名称转换为经纬度，city 可为空字符串
  static Future<Map<String, double>?> geocode(
    String keyword, {
    String city = '',
  }) async {
    final k = keyword.trim();
    if (k.isEmpty) return null;
    try {
      final uri = Uri.https(
        'restapi.amap.com',
        '/v3/geocode/geo',
        {
          'key': AMapConfig.webApiKey,
          'address': k,
          if (city.trim().isNotEmpty) 'city': city.trim(),
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data['status']?.toString() != '1') return null;
      final geocodes = data['geocodes'] as List?;
      if (geocodes == null || geocodes.isEmpty) return null;
      final loc = (geocodes.first as Map)['location']?.toString() ?? '';
      final parts = loc.split(',');
      if (parts.length < 2) return null;
      final lng = double.tryParse(parts[0].trim());
      final lat = double.tryParse(parts[1].trim());
      if (lat == null || lng == null) return null;
      return {'lat': lat, 'lng': lng};
    } catch (e) {
      debugPrint('AmapService geocode 失败: $e');
      return null;
    }
  }

  // ─── 天气查询 ───────────────────────────────────────────────────
  /// 先用城市名查 adcode，再查实时天气，返回给 AI 用的文字描述
  static Future<String?> getWeatherDescription(String cityName) async {
    try {
      // Step1: 城市名 → adcode
      final geoUri = Uri.https(
        'restapi.amap.com',
        '/v3/geocode/geo',
        {'key': AMapConfig.webApiKey, 'address': cityName.trim()},
      );
      final geoRes = await http.get(geoUri).timeout(const Duration(seconds: 10));
      if (geoRes.statusCode != 200) return null;
      final geoData = jsonDecode(utf8.decode(geoRes.bodyBytes));
      if (geoData['status']?.toString() != '1') return null;
      final geocodes = geoData['geocodes'] as List?;
      if (geocodes == null || geocodes.isEmpty) return null;
      final adcode = (geocodes.first as Map)['adcode']?.toString() ?? '';
      if (adcode.isEmpty) return null;

      // Step2: adcode → 实时天气
      final wxUri = Uri.https(
        'restapi.amap.com',
        '/v3/weather/weatherInfo',
        {
          'key': AMapConfig.webApiKey,
          'city': adcode,
          'extensions': 'base',
        },
      );
      final wxRes = await http.get(wxUri).timeout(const Duration(seconds: 10));
      if (wxRes.statusCode != 200) return null;
      final wxData = jsonDecode(utf8.decode(wxRes.bodyBytes));
      if (wxData['status']?.toString() != '1') return null;
      final lives = wxData['lives'] as List?;
      if (lives == null || lives.isEmpty) return null;
      final live = lives.first as Map;

      return '【实时天气数据】'
          '城市：${live['city']}，'
          '天气：${live['weather']}，'
          '气温：${live['temperature']}℃，'
          '风向：${live['winddirection']}风${live['windpower']}级，'
          '湿度：${live['humidity']}%';
    } catch (e) {
      debugPrint('AmapService getWeatherDescription 失败: $e');
      return null;
    }
  }

  // ─── 城市名提取工具（修正版）─────────────────────────────────────
  /// 用正则从自然语言中粗提取地名片段，交给高德 geocode 自行解析。
  /// 不再维护城市白名单，高德能识别全国所有城市/区县/景区名。
  static String? extractLocationFromText(String text) {
    // 非地名黑名单，过滤掉时间词等误匹配
    const blacklist = ['今天', '明天', '后天', '最近', '现在', '这里', '那里', '当地', '附近', '天气', '气温', '下雨'];

    // 模式1：「XX天气」「XX的天气」「XX气温」「XX下雨」
    // 匹配关键词前面的2-8个汉字
    final pattern1 = RegExp(r'([\u4e00-\u9fa5]{2,8}?)(?:的)?(?:天气|气温|下雨|会下雨)');
    final m1 = pattern1.firstMatch(text);
    if (m1 != null) {
      String word = m1.group(1)!;
      // 去除尾部的黑名单词（如"北京今天"→"北京"）
      for (final black in blacklist) {
        if (word.endsWith(black)) {
          word = word.substring(0, word.length - black.length);
        }
      }
      if (word.length >= 2 && !blacklist.contains(word)) {
        return word;
      }
    }

    // 模式2：「去XX」「在XX」「到XX」「来XX」
    // 匹配动词后面的2-6个汉字（限制长度避免吃太多）
    final pattern2 = RegExp(r'(?:去|在|到|来)([\u4e00-\u9fa5]{2,6})');
    final m2 = pattern2.firstMatch(text);
    if (m2 != null) {
      String word = m2.group(1)!;
      // 去除常见的尾部动词（如"上海玩"→"上海"）
      const tailWords = ['玩', '看', '逛', '吃', '住', '游', '旅游', '旅行', '出差', '工作'];
      for (final tail in tailWords) {
        if (word.endsWith(tail)) {
          word = word.substring(0, word.length - tail.length);
        }
      }
      if (word.length >= 2 && !blacklist.contains(word)) {
        return word;
      }
    }

    return null;
  }
}
