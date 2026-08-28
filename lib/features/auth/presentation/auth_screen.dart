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
  late final TextEditingController _resetEmailController;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isLoginMode = true;
  bool _rememberMe = false;
  bool _obscurePassword = true;
  bool _prefsLoaded = false;
  
  // 添加错误状态
  String? _emailError;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    _resetEmailController = TextEditingController();
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
    _resetEmailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // 手动验证
    setState(() {
      _emailError = null;
      _passwordError = null;
    });
    
    final String email = _emailController.text.trim();
    final String password = _passwordController.text.trim();
    
    bool hasError = false;
    
    if (email.isEmpty) {
      setState(() => _emailError = '请输入邮箱');
      hasError = true;
    } else if (!email.contains('@')) {
      setState(() => _emailError = '邮箱格式不正确');
      hasError = true;
    }
    
    if (password.isEmpty) {
      setState(() => _passwordError = '请输入密码');
      hasError = true;
    } else if (password.length < 6) {
      setState(() => _passwordError = '密码至少 6 位');
      hasError = true;
    }
    
    if (hasError) return;
    
    final AuthProvider auth = context.read<AuthProvider>();

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
      // 🌟 优化：注册成功后自动切换回登录界面
      final bool ok = await auth.signUp(email, password, context);
      if (!mounted) return;
      if (ok) {
        if (_rememberMe) {
          await _persistRememberMe(email);
        } else {
          await _clearRememberMe();
        }
        // 🌟 核心优化：注册成功后自动切换到登录模式
        // 延迟一小段时间，让用户看到成功提示
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        setState(() {
          _isLoginMode = true;
          _passwordController.clear(); // 清空密码，让用户重新输入
        });
      }
    }
  }

  /// 沉浸式底部面板：找回密码（State 持有控制器；pop 前 unfocus + 延迟，避免 dirty/disposed 冲突）。
  void _showResetPasswordSheet(BuildContext screenContext) {
    final BuildContext pageContext = screenContext;
    _resetEmailController
      ..clear()
      ..text = _emailController.text.trim();

    String? localError;
    bool isSending = false;

    showModalBottomSheet<void>(
      context: pageContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setModalState) {
          return AnimatedPadding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '找回密码',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.black87),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '请输入您的注册邮箱，我们将向您发送重置链接。',
                      style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 40),
                    const Text(
                      '电子邮箱',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6B8DFF),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: localError != null ? Colors.red.shade200 : Colors.grey.shade200,
                        ),
                      ),
                      child: TextField(
                        controller: _resetEmailController,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(
                          hintText: 'your@email.com',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                        ),
                        onChanged: (_) {
                          if (localError != null) {
                            setModalState(() => localError = null);
                          }
                        },
                      ),
                    ),
                    if (localError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10, left: 4),
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              localError!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: <Color>[Color(0xFF6B8DFF), Color(0xFF8E44FF)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: const Color(0xFF6B8DFF).withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: isSending
                              ? null
                              : () async {
                                  final String email = _resetEmailController.text.trim();
                                  if (email.isEmpty || !email.contains('@')) {
                                    setModalState(() => localError = '请输入有效的邮箱地址');
                                    return;
                                  }

                                  setModalState(() {
                                    localError = null;
                                    isSending = true;
                                  });
                                  FocusScope.of(ctx).unfocus();
                                  FocusManager.instance.primaryFocus?.unfocus();

                                  final bool success = await pageContext.read<AuthProvider>().sendPasswordResetEmail(
                                        email,
                                        pageContext,
                                      );

                                  if (!ctx.mounted) return;
                                  setModalState(() => isSending = false);

                                  if (!success) return;

                                  FocusManager.instance.primaryFocus?.unfocus();
                                  await Future<void>.delayed(const Duration(milliseconds: 100));
                                  if (!sheetContext.mounted) return;
                                  await Navigator.maybePop(sheetContext);
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: isSending
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : const Text(
                                  '发送重置链接',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final bool authBusy = auth.isLoading || auth.isGuestLoading;

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
                        // 使用新的logo图片替换原来的渐变容器
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.asset(
                            'assets/icon/icon.png',
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                          ),
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
                          onPressed: authBusy ? null : () => _showResetPasswordSheet(context),
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
                        onPressed: authBusy ? null : _submit,
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
                  OutlinedButton(
                    onPressed: authBusy ? null : () => auth.signInAsGuest(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        if (auth.isGuestLoading)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Color(0xFF2D3142),
                              strokeWidth: 2,
                            ),
                          )
                        else
                          const Icon(Icons.person_outline, color: Color(0xFF2D3142), size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          '游客登录',
                          style: TextStyle(
                            color: Color(0xFF2D3142),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
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
                        onPressed: authBusy
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: _emailError != null 
                ? Border.all(color: Colors.red.shade300, width: 1.5)
                : null,
          ),
          child: TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: 'your@email.com',
              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
              prefixIcon: Icon(Icons.email_outlined, color: Colors.grey.shade500, size: 20),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onChanged: (_) {
              if (_emailError != null) {
                setState(() => _emailError = null);
              }
            },
          ),
        ),
        if (_emailError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade600, size: 16),
                const SizedBox(width: 4),
                Text(
                  _emailError!,
                  style: TextStyle(
                    color: Colors.red.shade600,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: _passwordError != null 
                ? Border.all(color: Colors.red.shade300, width: 1.5)
                : null,
          ),
          child: TextField(
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
            onChanged: (_) {
              if (_passwordError != null) {
                setState(() => _passwordError = null);
              }
            },
          ),
        ),
        if (_passwordError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade600, size: 16),
                const SizedBox(width: 4),
                Text(
                  _passwordError!,
                  style: TextStyle(
                    color: Colors.red.shade600,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
