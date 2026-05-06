import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileProvider extends ChangeNotifier {
  ProfileProvider() {
    _authSub = _supabase.auth.onAuthStateChange.listen((_) {
      notifyListeners();
    });
  }

  final SupabaseClient _supabase = Supabase.instance.client;
  late final StreamSubscription<AuthState> _authSub;

  String nickname = '旅行者';
  String? avatarUrl;       // ← 存纯净 URL，不带任何 query 参数
  bool isUploadingAvatar = false;

  /// 每次上传成功后更新为新时间戳。
  /// UI 用 ValueKey(avatarCacheKey) 驱动 _AvatarImage 完全重建，
  /// 不需要在 URL 上加参数。
  String avatarCacheKey = 'init';

  bool get isAnonymous => _supabase.auth.currentUser?.isAnonymous ?? false;

  String get currentUserEmail => _supabase.auth.currentUser?.email ?? '';

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

  Future<void> fetchProfile() async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final Map<String, dynamic>? data = await _supabase
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();
      if (data != null) {
        nickname = data['nickname'] as String? ?? '旅行者';
        final String? dbUrl = data['avatar_url'] as String?;
        // 只在 URL 真正变化时才更新，防止覆盖刚上传的内存状态
        if (dbUrl != null && dbUrl.isNotEmpty && dbUrl != avatarUrl) {
          avatarUrl = dbUrl;  // 纯净 URL，不加任何参数
          avatarCacheKey = DateTime.now().millisecondsSinceEpoch.toString();
        } else if (dbUrl == null || dbUrl.isEmpty) {
          avatarUrl = null;
          avatarCacheKey = 'init';
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('获取个人资料失败: $e');
    }
  }

  Future<void> updateNickname(String newName) async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    nickname = newName;
    notifyListeners();

    try {
      await _supabase.from('profiles').upsert(<String, dynamic>{
        'id': userId,
        'nickname': newName,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'id');
    } catch (e) {
      debugPrint('更新昵称失败: $e');
    }
  }

  Future<void> pickAndUploadAvatar() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );
    if (image == null) return;

    isUploadingAvatar = true;
    notifyListeners();

    try {
      final String userId = _supabase.auth.currentUser!.id;
      final File file = File(image.path);
      final String fileExt = image.path.split('.').last.toLowerCase();
      final String ts = DateTime.now().millisecondsSinceEpoch.toString();
      final String filePath = '$userId/$ts.$fileExt';

      // 删除旧头像文件（如有），保持 Storage 只存一个文件
      if (avatarUrl != null && avatarUrl!.isNotEmpty) {
        try {
          // 从 URL 中提取 Storage 内的相对路径，例如 userId/旧时间戳.jpg
          final Uri oldUri = Uri.parse(avatarUrl!);
          // URL 格式：/storage/v1/object/public/avatars/{userId}/{filename}
          // pathSegments: ['storage','v1','object','public','avatars', userId, filename]
          final List<String> segments = oldUri.pathSegments;
          final int bucketIndex = segments.indexOf('avatars');
          if (bucketIndex != -1 && bucketIndex + 1 < segments.length) {
            final String oldFilePath = segments.sublist(bucketIndex + 1).join('/');
            await _supabase.storage.from('avatars').remove(<String>[oldFilePath]);
            debugPrint('🗑️ 旧头像已删除: $oldFilePath');
          }
        } catch (e) {
          debugPrint('⚠️ 旧头像删除失败（不影响上传）: $e');
        }
      }

      // 上传（最多重试 3 次）
      await _uploadWithRetry(filePath, file);

      // ✅ 使用纯净 URL，不追加任何 query 参数
      // Supabase 公开 bucket 的 URL 不支持额外参数，加了会返回 400
      final String publicUrl = _supabase.storage.from('avatars').getPublicUrl(filePath);

      // 写入数据库
      await _supabase.from('profiles').upsert(<String, dynamic>{
        'id': userId,
        'avatar_url': publicUrl,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'id');

      // 更新内存状态：
      // - avatarUrl 存纯净 URL（让网络请求正常）
      // - avatarCacheKey 用新时间戳（驱动 ValueKey 强制重建 _AvatarImage）
      avatarUrl = publicUrl;
      avatarCacheKey = ts;
      debugPrint('✅ 头像更新成功: $publicUrl  cacheKey: $avatarCacheKey');
    } catch (e) {
      debugPrint('❌ 头像上传失败: $e');
    } finally {
      isUploadingAvatar = false;
      notifyListeners();
    }
  }

  Future<void> _uploadWithRetry(String filePath, File file, {int maxRetries = 3}) async {
    for (int i = 1; i <= maxRetries; i++) {
      try {
        await _supabase.storage.from('avatars').upload(filePath, file);
        return;
      } catch (e) {
        debugPrint('上传第 $i 次失败: $e');
        if (i == maxRetries) rethrow;
        await Future<void>.delayed(Duration(seconds: i * i));
      }
    }
  }

  Future<bool> sendBindEmailCode(String email) async {
    try {
      await _supabase.auth.updateUser(UserAttributes(email: email));
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> verifyAndBindEmail(String email, String code, String password) async {
    try {
      await _supabase.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.emailChange,
      );
      await _supabase.auth.updateUser(UserAttributes(password: password));
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> deleteAccount() async {
    try {
      final String? userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        await _supabase.from('profiles').delete().eq('id', userId);
      }
      await _supabase.auth.signOut();
      nickname = '旅行者';
      avatarUrl = null;
      avatarCacheKey = 'init';
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('注销失败: $e');
      return false;
    }
  }
}