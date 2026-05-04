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
  String? avatarUrl;
  bool isUploadingAvatar = false;

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
        avatarUrl = data['avatar_url'] as String?;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('获取个人资料失败: $e');
    }
  }

  // 修改昵称
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

  // 上传头像并更新地址；路径规范：userId/时间戳.扩展名（符合 Storage RLS）
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
      final String fileExt = image.path.split('.').last;

      final String fileName = '${DateTime.now().millisecondsSinceEpoch}.$fileExt';
      final String filePath = '$userId/$fileName';

      // 1. 上传到存储桶
      await _supabase.storage.from('avatars').upload(filePath, file);

      // 2. 获取公开访问链接
      final String publicUrl = _supabase.storage.from('avatars').getPublicUrl(filePath);

      // 3. 更新到 profiles 表
      await _supabase.from('profiles').upsert(<String, dynamic>{
        'id': userId,
        'avatar_url': publicUrl,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'id');

      // 4. 更新本地内存状态
      avatarUrl = publicUrl;
      debugPrint('✅ 头像更新成功: $publicUrl');
    } catch (e) {
      debugPrint('❌ 头像上传失败: $e');
    } finally {
      isUploadingAvatar = false;
      notifyListeners();
    }
  }

  // 绑定邮箱两步走（OTP 类型 emailChange）
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

  /// 永久注销（设置页使用）：删除 profiles 行并登出。
  Future<bool> deleteAccount() async {
    try {
      final String? userId = _supabase.auth.currentUser?.id;
      if (userId != null) {
        await _supabase.from('profiles').delete().eq('id', userId);
      }
      await _supabase.auth.signOut();
      nickname = '旅行者';
      avatarUrl = null;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('注销失败: $e');
      return false;
    }
  }
}
