import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/services/amap_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() {
    AmapService.debugSetHttpClientForTesting(null);
  });

  group('AmapService tool extensions', () {
    test('searchPoi returns normalized POI JSON', () async {
      AmapService.debugSetHttpClientForTesting(
        MockClient((http.Request request) async {
          expect(request.url.path, '/v3/place/text');
          expect(request.url.queryParameters['city'], '西安');
          expect(request.url.queryParameters['types'], '110000');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'status': '1',
                'pois': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': '大雁塔',
                    'address': '雁塔区',
                    'opentime': '09:00-18:00',
                    'location': '108.959,34.219',
                  },
                ],
              }),
            ),
            200,
          );
        }),
      );

      final String result = await AmapService.searchPoi(
        city: '西安',
        category: '景点',
        limit: 1,
      );
      final List<dynamic> pois = jsonDecode(result) as List<dynamic>;

      expect(pois, hasLength(1));
      expect(pois.first['name'], '大雁塔');
      expect(pois.first['address'], '雁塔区');
      expect(pois.first['opentime'], '09:00-18:00');
      expect(pois.first['lat'], 34.219);
      expect(pois.first['lng'], 108.959);
    });

    test('searchPoi degrades to an empty JSON list on failure', () async {
      AmapService.debugSetHttpClientForTesting(
        MockClient((http.Request request) async {
          return http.Response('server error', 500);
        }),
      );

      final String result = await AmapService.searchPoi(
        city: '西安',
        category: '景点',
      );

      expect(result, '[]');
    });

    test('estimateRouteMinutes parses driving paths duration', () async {
      AmapService.debugSetHttpClientForTesting(
        MockClient((http.Request request) async {
          expect(request.url.path, '/v5/direction/driving');
          expect(request.url.queryParameters['origin'], '108.959,34.219');
          expect(request.url.queryParameters['destination'], '108.946,34.265');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'status': '1',
                'route': <String, dynamic>{
                  'paths': <Map<String, dynamic>>[
                    <String, dynamic>{'duration': '3600'},
                  ],
                },
              }),
            ),
            200,
          );
        }),
      );

      final int? minutes = await AmapService.estimateRouteMinutes(
        originLngLat: '108.959,34.219',
        destLngLat: '108.946,34.265',
      );

      expect(minutes, 60);
    });

    test('estimateRouteMinutes parses transit transits duration', () async {
      AmapService.debugSetHttpClientForTesting(
        MockClient((http.Request request) async {
          expect(request.url.path, '/v5/direction/transit/integrated');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'status': '1',
                'route': <String, dynamic>{
                  'transits': <Map<String, dynamic>>[
                    <String, dynamic>{'duration': '1800'},
                  ],
                },
              }),
            ),
            200,
          );
        }),
      );

      final int? minutes = await AmapService.estimateRouteMinutes(
        originLngLat: '108.959,34.219',
        destLngLat: '108.946,34.265',
        mode: 'transit',
      );

      expect(minutes, 30);
    });

    test('estimateRouteMinutes degrades to null on failure', () async {
      AmapService.debugSetHttpClientForTesting(
        MockClient((http.Request request) async {
          return http.Response('server error', 500);
        }),
      );

      final int? minutes = await AmapService.estimateRouteMinutes(
        originLngLat: '108.959,34.219',
        destLngLat: '108.946,34.265',
      );

      expect(minutes, isNull);
    });

    test('executeTool returns safe JSON for unknown tools', () async {
      final String result = await AmapService.executeTool(
        'delete_everything',
        <String, dynamic>{},
      );

      expect(jsonDecode(result), <String, dynamic>{
        'error': 'unknown tool: delete_everything',
      });
    });

    test(
      'executeTool estimate_route fails safely when geocode cannot resolve',
      () async {
        final String result = await AmapService.executeTool(
          'estimate_route',
          <String, dynamic>{'from': '', 'to': '', 'mode': 'driving'},
        );

        final Map<String, dynamic> data =
            jsonDecode(result) as Map<String, dynamic>;
        expect(data['error'], 'location resolve failed');
        expect(data['from'], '');
        expect(data['to'], '');
      },
    );
  });
}
