import 'dart:async';

import 'package:gonow/core/models/city_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TravelServiceException implements Exception {
  const TravelServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TravelService {
  const TravelService();

  SupabaseClient get _client => Supabase.instance.client;

  Future<List<CityModel>> fetchBlindBoxCities() async {
    try {
      final List<dynamic> rows = await _client
          .from('blind_box_cities')
          .select()
          .timeout(const Duration(seconds: 10));
      return rows
          .whereType<Map<String, dynamic>>()
          .map(CityModel.fromJson)
          .where((CityModel city) => city.name.isNotEmpty && city.imageUrl.isNotEmpty)
          .toList(growable: false);
    } on TimeoutException {
      throw const TravelServiceException('盲盒城市请求超时，请检查网络后重试');
    } catch (_) {
      throw const TravelServiceException('盲盒城市加载失败，请稍后再试');
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> fetchVisaFreeCountries() async {
    try {
      final List<dynamic> rows = await _client
          .from('visa_free_countries')
          .select()
          .timeout(const Duration(seconds: 10));
      final Map<String, List<Map<String, dynamic>>> grouped =
          <String, List<Map<String, dynamic>>>{};
      for (final dynamic row in rows) {
        if (row is! Map<String, dynamic>) continue;
        String continent = (row['continent'] ?? '其他').toString();
        // 将"特别免签区"的济州岛、富国岛合并进亚洲
        if (continent == '特别免签区') continent = '亚洲';
        grouped.putIfAbsent(continent, () => <Map<String, dynamic>>[]).add(row);
      }
      return grouped;
    } on TimeoutException {
      throw const TravelServiceException('免签国家请求超时，请检查网络后重试');
    } catch (_) {
      throw const TravelServiceException('免签国家加载失败，请稍后再试');
    }
  }

  Future<List<Map<String, dynamic>>> fetchInternationalCountries() async {
    try {
      final List<dynamic> rows = await _client
          .from('international_countries')
          .select()
          .timeout(const Duration(seconds: 10));
      return rows.whereType<Map<String, dynamic>>().toList(growable: false);
    } on TimeoutException {
      throw const TravelServiceException('国际盲盒请求超时，请检查网络后重试');
    } catch (_) {
      throw const TravelServiceException('国际盲盒加载失败，请稍后再试');
    }
  }
}
