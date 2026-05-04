import 'package:flutter/material.dart';
import 'package:gonow/features/auth/data/auth_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地存储键：记住邮箱（不保存密码）。
const String _kAuthRememberMe = 'auth_remember_me';
const String _kAuthSavedEmail = 'auth_saved_email';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isLoginMode = true;
  bool _rememberMe = false;
  bool _obscurePassword = true;
  bool _prefsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSavedLoginPrefs();
  }

  Future<void> _loadSavedLoginPrefs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool remember = prefs.getBool(_kAuthRememberMe) ?? false;
    final String email = prefs.getString(_kAuthSavedEmail) ?? '';
    if (!mounted) return;
    setState(() {
      _prefsLoaded = true;
      _rememberMe = remember;
      if (email.isNotEmpty) {
        _emailController.text = email;
      }
    });
  }

  Future<void> _persistRememberMe(String email) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAuthRememberMe, true);
    await prefs.setString(_kAuthSavedEmail, email);
  }

  Future<void> _clearRememberMe() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAuthRememberMe, false);
    await prefs.remove(_kAuthSavedEmail);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final AuthProvider auth = context.read<AuthProvider>();
    final String email = _emailController.text.trim();
    final String password = _passwordController.text.trim();

    if (_isLoginMode) {
      final bool ok = await auth.signIn(email, password, context);
      if (!mounted) return;
      if (ok) {
        if (_rememberMe) {
          await _persistRememberMe(email);
        } else {
          await _clearRememberMe();
        }
      }
    } else {
      final bool ok = await auth.signUp(email, password, context);
      if (!mounted) return;
      if (ok) {
        if (_rememberMe) {
          await _persistRememberMe(email);
        } else {
          await _clearRememberMe();
        }
      }
    }
  }

  void _showForgotPasswordDialog() {
    final TextEditingController controller = TextEditingController(text: _emailController.text.trim());
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重置密码'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: '邮箱',
            hintText: 'your@email.com',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final String email = controller.text.trim();
              if (email.isEmpty || !email.contains('@')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效邮箱')),
                );
                return;
              }
              await context.read<AuthProvider>().sendPasswordResetEmail(email, context);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('发送重置邮件'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();

    if (!_prefsLoaded) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          // 常规屏高下列表总高度小于视口，无可感知滚动；键盘弹出时仍可滚动避免遮挡输入框
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Transform.translate(
            offset: const Offset(0, 6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Form(
                key: _formKey,
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: 50),
                    Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[Color(0xFF6B8DFF), Color(0xFF8E44FF)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: const Color(0xFF6B8DFF).withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.location_on, color: Colors.white, size: 32),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'GONOW',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF2D3142),
                          letterSpacing: -1.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 31),
                  Text(
                    _isLoginMode ? '欢迎回来' : '创建账号',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    _isLoginMode ? '登录继续您的旅行计划' : '注册以同步您的旅行数据',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 24),
                  _buildLabel('邮箱'),
                  _buildEmailField(),
                  const SizedBox(height: 18),
                  _buildLabel('密码'),
                  _buildPasswordField(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Checkbox(
                            value: _rememberMe,
                            activeColor: const Color(0xFF8E44FF),
                            onChanged: (bool? v) {
                              if (v != null) setState(() => _rememberMe = v);
                            },
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                          const Text(
                            '记住我',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF2D3142),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (_isLoginMode)
                        TextButton(
                          onPressed: auth.isLoading ? null : _showForgotPasswordDialog,
                          child: const Text(
                            '忘记密码？',
                            style: TextStyle(
                              color: Color(0xFF8E44FF),
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: <Color>[Color(0xFF4A80FF), Color(0xFF9E36FF)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: const Color(0xFF4A80FF).withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: auth.isLoading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: auth.isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : Text(
                                _isLoginMode ? '登录' : '立即注册',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Row(
                    children: <Widget>[
                      Expanded(child: Divider(color: Colors.grey.shade200)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('或', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ),
                      Expanded(child: Divider(color: Colors.grey.shade200)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: auth.isLoading ? null : () => auth.signInAsGuest(context),
                    icon: const Icon(Icons.person_outline, color: Color(0xFF2D3142), size: 20),
                    label: const Text(
                      '游客登录',
                      style: TextStyle(color: Color(0xFF2D3142), fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 11),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        _isLoginMode ? '还没有账号？' : '已有账号？',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                      ),
                      TextButton(
                        onPressed: auth.isLoading
                            ? null
                            : () {
                                setState(() => _isLoginMode = !_isLoginMode);
                              },
                        child: Text(
                          _isLoginMode ? '立即注册' : '直接登录',
                          style: const TextStyle(
                            color: Color(0xFF8E44FF),
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildLabel(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2D3142)),
        ),
      ),
    );
  }

  Widget _buildEmailField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextFormField(
        controller: _emailController,
        keyboardType: TextInputType.emailAddress,
        decoration: InputDecoration(
          hintText: 'your@email.com',
          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
          prefixIcon: Icon(Icons.email_outlined, color: Colors.grey.shade500, size: 20),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
        validator: (String? v) {
          final String s = v?.trim() ?? '';
          if (s.isEmpty) return '请输入邮箱';
          if (!s.contains('@')) return '邮箱格式不正确';
          return null;
        },
      ),
    );
  }

  Widget _buildPasswordField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextFormField(
        controller: _passwordController,
        obscureText: _obscurePassword,
        keyboardType: TextInputType.visiblePassword,
        decoration: InputDecoration(
          hintText: '••••••••',
          hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
          prefixIcon: Icon(Icons.lock_outline, color: Colors.grey.shade500, size: 20),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: Colors.grey,
              size: 20,
            ),
            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
        validator: (String? v) {
          final String s = v ?? '';
          if (s.isEmpty) return '请输入密码';
          if (s.length < 6) return '密码至少 6 位';
          return null;
        },
      ),
    );
  }
}
