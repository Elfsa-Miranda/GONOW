import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 足迹地图状态：Supabase 云端持久化 + 乐观更新。
///
/// 修复清单：
///  BUG-7  updateFootprints 全量覆盖 upsert，若本地为空会清除历史数据
///  BUG-8  缺少 fetchFootprint，历史足迹永远不从数据库加载
///  BUG-9  upsert await 阻塞 UI，弱网时会卡住
class FootprintProvider extends ChangeNotifier {
  FootprintProvider({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  // 私有可变列表，外部通过不可变视图访问。
  List<String> _visitedChina = <String>[];
  List<String> _visitedWorld = <String>[];

  List<String> get visitedChina => List<String>.unmodifiable(_visitedChina);
  List<String> get visitedWorld => List<String>.unmodifiable(_visitedWorld);

  String? get _uid => _supabase.auth.currentUser?.id;

  // ──────────────────────────────────────────────────────────────
  // BUG-8 FIX：补回 fetchFootprint。
  // UI 层必须在初始化时调用（如 initState 或 ChangeNotifierProvider 创建后）。
  // 未调用此方法则本地状态始终为空，写入时会把历史数据全部清空！
  // ──────────────────────────────────────────────────────────────
  Future<void> fetchFootprint() async {
    final String? uid = _uid;
    if (uid == null) {
      debugPrint('[FootprintProvider] fetchFootprint: 用户未登录，跳过');
      return;
    }

    try {
      final Map<String, dynamic>? row = await _supabase
          .from('user_footprints')
          .select()
          .eq('user_id', uid)
          .maybeSingle();

      if (row == null) {
        debugPrint('[FootprintProvider] 新用户，无历史足迹数据');
        return;
      }

      _visitedChina = List<String>.from(
        (row['visited_china'] as List<dynamic>?) ?? <dynamic>[],
      );
      _visitedWorld = List<String>.from(
        (row['visited_world'] as List<dynamic>?) ?? <dynamic>[],
      );
      notifyListeners();
      debugPrint(
        '[FootprintProvider] 历史足迹加载成功: '
        'china=${_visitedChina.length}, world=${_visitedWorld.length}',
      );
    } catch (e, st) {
      debugPrint('[FootprintProvider] fetchFootprint error: $e\n$st');
    }
  }

  // ──────────────────────────────────────────────────────────────
  // BUG-7 + BUG-9 FIX：
  //   toggleChina / toggleWorld 替代原来的 updateFootprints 全量覆盖。
  //   ① 先更新本地状态 + notifyListeners（UI 即时响应）
  //   ② 后台静默 upsert（不 await，不阻塞 UI）
  // ──────────────────────────────────────────────────────────────

  /// 点亮或取消一个省份。
  void toggleChina(String province) {
    if (_visitedChina.contains(province)) {
      _visitedChina = _visitedChina.where((String p) => p != province).toList();
    } else {
      _visitedChina = <String>[..._visitedChina, province];
    }
    notifyListeners();
    _upsertFootprint();
  }

  /// 点亮或取消一个国家/地区。
  void toggleWorld(String country) {
    if (_visitedWorld.contains(country)) {
      _visitedWorld = _visitedWorld.where((String c) => c != country).toList();
    } else {
      _visitedWorld = <String>[..._visitedWorld, country];
    }
    notifyListeners();
    _upsertFootprint();
  }

  /// 批量设置（外部传入完整列表时使用）。
  void updateFootprints(List<String> china, List<String> world) {
    _visitedChina = List<String>.from(china);
    _visitedWorld = List<String>.from(world);
    notifyListeners();
    _upsertFootprint();
  }

  // ──────────────────────────────────────────────────────────────
  // 内部：后台静默 upsert（非 async，彻底不阻塞调用方）
  // ──────────────────────────────────────────────────────────────
  void _upsertFootprint() {
    final String? uid = _uid;
    if (uid == null) return;

    // 快照当前状态，防止异步期间列表被修改。
    final List<String> chinaSnapshot = List<String>.from(_visitedChina);
    final List<String> worldSnapshot = List<String>.from(_visitedWorld);

    _supabase
        .from('user_footprints')
        .upsert(
          <String, dynamic>{
            'user_id': uid,
            'visited_china': chinaSnapshot,
            'visited_world': worldSnapshot,
            'updated_at': DateTime.now().toIso8601String(),
          },
          onConflict: 'user_id',
        )
        .then((_) {
      debugPrint('[FootprintProvider] 足迹同步云端成功');
    }).catchError((Object e, StackTrace st) {
      debugPrint('[FootprintProvider] 足迹同步云端失败: $e\n$st');
    });
  }
}