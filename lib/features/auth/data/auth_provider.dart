import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  bool _isLoading = false;
  bool get isLoading => _isLoading;

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
      if (response.user != null) {
        await _supabase.from('profiles').upsert(<String, dynamic>{
          'id': response.user!.id,
          'nickname': '旅行者_${response.user!.id.substring(0, 4)}',
        });
      }
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
    _setLoading(true);
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
      _setLoading(false);
    }
    return false;
  }

  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  void _setLoading(bool value) {
    _isLoading = value;
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
