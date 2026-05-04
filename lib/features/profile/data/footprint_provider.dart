import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 足迹地图：本地状态 + `user_footprints` 云端同步。
class FootprintProvider extends ChangeNotifier {
  FootprintProvider({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  List<String> visitedChina = <String>[];
  List<String> visitedWorld = <String>[];

  Future<void> updateFootprints(List<String> china, List<String> world) async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    visitedChina = china;
    visitedWorld = world;
    notifyListeners();

    try {
      await _supabase.from('user_footprints').upsert(
        <String, dynamic>{
          'user_id': userId,
          'visited_china': china,
          'visited_world': world,
          'updated_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id',
      );

      debugPrint('✅ 足迹同步云端成功！');
    } catch (e, st) {
      debugPrint('❌ 足迹同步云端失败: $e\n$st');
    }
  }
}
