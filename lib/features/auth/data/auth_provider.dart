import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  bool _isLoading = false;
  bool _guestLoading = false;

  /// 邮箱密码登录 / 注册 / 发重置邮件等。
  bool get isLoading => _isLoading;

  /// 仅游客登录进行中（与 [isLoading] 互斥路由场景）。
  bool get isGuestLoading => _guestLoading;

  Future<bool> signUp(
    String email,
    String password,
    BuildContext context,
  ) async {
    _setLoading(true);
    try {
      final AuthResponse response = await _supabase.auth.signUp(
        email: email,
        password: password,
      );
      if (response.user != null) {
        try {
          await _supabase.from('profiles').upsert(<String, dynamic>{
            'id': response.user!.id,
            'nickname': '旅行者_${response.user!.id.substring(0, 4)}',
          });
        } catch (_) {}
        if (context.mounted) {
          _showToast(context, '注册成功！欢迎开启探索之旅。', duration: 3);
        }
        return true;
      }
    } on AuthException catch (e) {
      if (context.mounted) {
        _showToast(context, '注册失败：${e.message}');
      }
    } catch (e) {
      if (context.mounted) {
        _showToast(context, '发生未知错误: $e');
      }
    } finally {
      _setLoading(false);
    }
    return false;
  }

  Future<bool> signIn(
    String email,
    String password,
    BuildContext context,
  ) async {
    _setLoading(true);
    try {
      final AuthResponse response = await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
      if (response.user == null) {
        if (context.mounted) {
          _showToast(context, '登录失败，请检查邮箱与密码');
        }
        return false;
      }
      await _supabase.from('profiles').upsert(<String, dynamic>{
        'id': response.user!.id,
        'nickname': '旅行者_${response.user!.id.substring(0, 4)}',
      });
      if (context.mounted) {
        _showToast(context, '欢迎回来！');
      }
      return true;
    } on AuthException catch (e) {
      if (context.mounted) {
        if (e.message.contains('Email not confirmed')) {
          _showToast(context, '您的邮箱尚未激活，请前往邮箱点击确认链接。');
        } else {
          _showToast(context, '登录失败：${e.message}');
        }
      }
    } catch (e) {
      if (context.mounted) {
        _showToast(context, '发生未知错误: $e');
      }
    } finally {
      _setLoading(false);
    }
    return false;
  }

  Future<bool> signInAsGuest(BuildContext context) async {
    _setGuestLoading(true);
    try {
      final AuthResponse response = await _supabase.auth.signInAnonymously();
      if (response.user != null) {
        await _supabase.from('profiles').upsert(<String, dynamic>{
          'id': response.user!.id,
          'nickname': '游客_${response.user!.id.substring(0, 5)}',
        });
        if (context.mounted) {
          _showToast(context, '已进入游客免登录试用模式！');
        }
        return true;
      }
    } on AuthException catch (e) {
      if (context.mounted) {
        _showToast(context, '游客登录失败：${e.message}');
      }
    } catch (e) {
      if (context.mounted) {
        _showToast(context, '发生未知错误: $e');
      }
    } finally {
      _setGuestLoading(false);
    }
    return false;
  }

  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  /// 发送重置密码邮件（redirectTo 须与 Supabase 控制台 Redirect URLs、Android/iOS 深度链接一致）。
  Future<bool> sendPasswordResetEmail(String email, BuildContext context) async {
    _setLoading(true);
    try {
      await _supabase.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: 'io.supabase.gonow://login-callback',
      );
      if (context.mounted) {
        _showToast(context, '重置链接已发送至邮箱，请查收！', duration: 4);
      }
      return true;
    } on AuthException catch (e) {
      if (context.mounted) {
        _showToast(context, '发送失败：${e.message}');
      }
      return false;
    } catch (e) {
      if (context.mounted) {
        _showToast(context, '发生未知错误: $e');
      }
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// 邮件跳转回 App 后，用户在此处提交新密码。
  Future<bool> updateNewPassword(String newPassword, BuildContext context) async {
    _setLoading(true);
    try {
      await _supabase.auth.updateUser(
        UserAttributes(password: newPassword),
      );
      if (context.mounted) {
        _showToast(context, '✅ 密码重置成功，请重新登录');
      }
      return true;
    } on AuthException catch (e) {
      if (context.mounted) {
        _showToast(context, '更新失败：${e.message}');
      }
      return false;
    } catch (e) {
      if (context.mounted) {
        _showToast(context, '发生未知错误: $e');
      }
      return false;
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _setGuestLoading(bool value) {
    _guestLoading = value;
    notifyListeners();
  }

  void _showToast(BuildContext context, String message, {int duration = 2}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: Duration(seconds: duration),
      ),
    );
  }
}
