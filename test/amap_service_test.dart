import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/services/amap_service.dart';

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

    // 注意：以下测试需要网络连接和有效的 API Key
    test('geocode - 应该返回有效的经纬度', () async {
      final coords = await AmapService.geocode('天安门', city: '北京');
      
      if (coords != null) {
        expect(coords['lat'], isNotNull);
        expect(coords['lng'], isNotNull);
        expect(coords['lat'], greaterThan(0));
        expect(coords['lng'], greaterThan(0));
        
        // 天安门大致坐标范围验证
        expect(coords['lat'], closeTo(39.9, 1.0));
        expect(coords['lng'], closeTo(116.4, 1.0));
      }
    }, skip: '需要网络连接');

    test('geocode - 应该支持非标准地名（区县/景区）', () async {
      final coords1 = await AmapService.geocode('朝阳区');
      final coords2 = await AmapService.geocode('西湖');
      
      if (coords1 != null) {
        expect(coords1['lat'], isNotNull);
        expect(coords1['lng'], isNotNull);
      }
      
      if (coords2 != null) {
        expect(coords2['lat'], isNotNull);
        expect(coords2['lng'], isNotNull);
      }
    }, skip: '需要网络连接');

    test('getWeatherDescription - 应该返回天气描述', () async {
      final weather = await AmapService.getWeatherDescription('北京');
      
      if (weather != null) {
        expect(weather, contains('【实时天气数据】'));
        expect(weather, contains('城市：'));
        expect(weather, contains('天气：'));
        expect(weather, contains('气温：'));
        expect(weather, contains('℃'));
      }
    }, skip: '需要网络连接');

    test('getWeatherDescription - 应该支持非标准地名', () async {
      final weather = await AmapService.getWeatherDescription('朝阳区');
      
      if (weather != null) {
        expect(weather, contains('【实时天气数据】'));
      }
    }, skip: '需要网络连接');

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
