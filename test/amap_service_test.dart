import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/services/amap_service.dart';
import 'package:http/http.dart' as http;

void main() {
  group('AmapService Tests', () {
    test('extractLocationFromText - 应该正确提取城市名', () {
      expect(AmapService.extractLocationFromText('北京今天天气怎么样'), '北京');
      expect(AmapService.extractLocationFromText('我想去上海玩'), '上海');
      expect(AmapService.extractLocationFromText('深圳的气温多少度'), '深圳');
      expect(AmapService.extractLocationFromText('成都会下雨吗'), '成都');
      expect(AmapService.extractLocationFromText('杭州天气'), '杭州');
      expect(AmapService.extractLocationFromText('去大理'), '大理');
      expect(AmapService.extractLocationFromText('在朝阳区'), '朝阳区');
    });

    test('extractLocationFromText - 应该过滤时间词黑名单', () {
      expect(AmapService.extractLocationFromText('今天天气怎么样'), null);
      expect(AmapService.extractLocationFromText('明天天气'), null);
      expect(AmapService.extractLocationFromText('最近天气如何'), null);
      expect(AmapService.extractLocationFromText('现在天气'), null);
      expect(AmapService.extractLocationFromText('当地天气'), null);
    });

    test('extractLocationFromText - 无地名应该返回 null', () {
      expect(AmapService.extractLocationFromText('天气怎么样'), null);
      expect(AmapService.extractLocationFromText('帮我规划行程'), null);
    });

    test('extractLocationFromText - 应该支持非标准地名', () {
      // 高德能识别区县、景区等非标准地名
      expect(AmapService.extractLocationFromText('西湖天气'), '西湖');
      expect(AmapService.extractLocationFromText('去黄山'), '黄山');
      expect(AmapService.extractLocationFromText('在海淀区'), '海淀区');
    });

    test('geocode - 应该返回有效的经纬度', () async {
      final coords = await AmapService.geocode(
        '天安门',
        city: '北京',
        get: (uri) async {
          expect(uri.host, 'restapi.amap.com');
          expect(uri.path, '/v3/geocode/geo');
          expect(uri.queryParameters['address'], '天安门');
          expect(uri.queryParameters['city'], '北京');
          return http.Response.bytes(
            utf8.encode(
              '{"status":"1","geocodes":[{"location":"116.397,39.908"}]}',
            ),
            200,
          );
        },
      );

      expect(coords, {'lat': 39.908, 'lng': 116.397});
    });

    test('geocode - 应该支持非标准地名（区县/景区）', () async {
      Future<http.Response> fakeGeocode(Uri uri) async {
        final address = uri.queryParameters['address'];
        final location = address == '朝阳区' ? '116.443,39.921' : '120.155,30.274';
        return http.Response.bytes(
          utf8.encode('{"status":"1","geocodes":[{"location":"$location"}]}'),
          200,
        );
      }

      final coords1 = await AmapService.geocode('朝阳区', get: fakeGeocode);
      final coords2 = await AmapService.geocode('西湖', get: fakeGeocode);

      expect(coords1, {'lat': 39.921, 'lng': 116.443});
      expect(coords2, {'lat': 30.274, 'lng': 120.155});
    });

    test('getWeatherDescription - 应该返回天气描述', () async {
      final weather = await AmapService.getWeatherDescription(
        '北京',
        get: (uri) async {
          if (uri.path == '/v3/geocode/geo') {
            return http.Response.bytes(
              utf8.encode('{"status":"1","geocodes":[{"adcode":"110000"}]}'),
              200,
            );
          }
          expect(uri.path, '/v3/weather/weatherInfo');
          expect(uri.queryParameters['city'], '110000');
          return http.Response.bytes(
            utf8.encode(
              '{"status":"1","lives":[{"city":"北京","weather":"晴","temperature":"26","winddirection":"东","windpower":"3","humidity":"40"}]}',
            ),
            200,
          );
        },
      );

      expect(weather, '【实时天气数据】城市：北京，天气：晴，气温：26℃，风向：东风3级，湿度：40%');
    });

    test('getWeatherDescription - 应该支持非标准地名', () async {
      final requestedPaths = <String>[];
      final weather = await AmapService.getWeatherDescription(
        '朝阳区',
        get: (uri) async {
          requestedPaths.add(uri.path);
          if (uri.path == '/v3/geocode/geo') {
            expect(uri.queryParameters['address'], '朝阳区');
            return http.Response.bytes(
              utf8.encode('{"status":"1","geocodes":[{"adcode":"110105"}]}'),
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode(
              '{"status":"1","lives":[{"city":"朝阳区","weather":"多云","temperature":"24","winddirection":"南","windpower":"2","humidity":"45"}]}',
            ),
            200,
          );
        },
      );

      expect(requestedPaths, ['/v3/geocode/geo', '/v3/weather/weatherInfo']);
      expect(weather, contains('城市：朝阳区'));
    });

    test('geocode - 空字符串应该返回 null', () async {
      final coords = await AmapService.geocode('');
      expect(coords, null);
    });

    test('geocode - 纯空格应该返回 null', () async {
      final coords = await AmapService.geocode('   ');
      expect(coords, null);
    });
  });
}
