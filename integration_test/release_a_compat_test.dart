import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('ordinary chat is bound to the authenticated Release A gateway', () {
    final String service = _read('lib/core/services/ai_gateway_service.dart');
    final String contract = _read(
      'contracts/release-a-chat-gateway.openapi.yaml',
    );

    expect(service, contains("_chatPath = '/v1/release-a/chat'"));
    expect(service, contains("'Authorization': 'Bearer \$normalizedToken'"));
    expect(service, contains("AiGatewayException('gateway_disabled')"));
    expect(contract, contains('/v1/release-a/chat:'));
    expect(contract, contains('userBearer:'));
    expect(contract, contains("'429':"));
  });

  test(
    'chat UI keeps history and import flow while removing direct provider calls',
    () {
      final String screen = _read(
        'lib/features/ai_custom/presentation/screens/ai_custom_screen.dart',
      );

      expect(screen, contains('AiGatewayService(client: client)'));
      expect(screen, contains("AiGatewayException('authentication_required')"));
      expect(screen, contains('Future<void> _importPlan('));
      expect(screen, contains('ItineraryModel.fromJson(itineraryData)'));
      expect(screen, isNot(contains('ApiKeys.')));
      expect(screen.toLowerCase(), isNot(contains('deepseek')));
    },
  );

  test('auth entry points remain available', () {
    final String provider = _read('lib/features/auth/data/auth_provider.dart');
    final String screen = _read(
      'lib/features/auth/presentation/auth_screen.dart',
    );

    expect(provider, contains('Future<bool> signUp('));
    expect(provider, contains('Future<bool> signIn('));
    expect(provider, contains('Future<bool> signInAsGuest('));
    expect(provider, contains('Future<void> signOut()'));
    expect(screen, contains('context.read<AuthProvider>()'));
  });

  test('itinerary local fallback and cloud compatibility markers remain', () {
    final String provider = _read(
      'lib/features/itinerary/data/itinerary_provider.dart',
    );

    expect(provider, contains("_prefsKey = 'current_itinerary_json'"));
    expect(provider, contains("_tableName = 'user_itineraries'"));
    expect(provider, contains('SharedPreferences.getInstance()'));
    expect(provider, contains("'my_itineraries_cache_\$fallbackUserId'"));
  });

  test('diary local fallback and cloud compatibility markers remain', () {
    final String provider = _read(
      'lib/features/diary/data/diary_provider.dart',
    );

    expect(provider, contains("_tableName = 'public_diaries'"));
    expect(provider, contains('SharedPreferences.getInstance()'));
    expect(provider, contains('.upsert(toSave.toSupabaseJson())'));
  });

  test('safe rollback can disable models without restoring a client key', () {
    final String config = _read('lib/core/constants/ai_config.dart');
    final String gateway = _read('lib/core/services/ai_gateway_service.dart');

    expect(config, contains("'GONOW_RELEASE_A_GATEWAY_ENABLED'"));
    expect(
      RegExp(
        r'releaseAGatewayEnabled[\s\S]+defaultValue:\s*false',
      ).hasMatch(config),
      isTrue,
    );
    expect(config, contains("static const String deepseekApiKey = '';"));
    expect(config, contains("static const String deepseekEndpoint = '';"));
    expect(gateway, contains('no direct-provider fallback'));
  });
}
