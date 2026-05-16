import 'package:flutter/material.dart';
import 'package:gonow/core/services/notification_service.dart';
import 'package:gonow/features/profile/data/profile_provider.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 全屏个人档案与设置中心。
class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _pwdController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ProfileProvider>().fetchProfile();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _pwdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProfileProvider>(
      builder: (BuildContext context, ProfileProvider provider, _) {
        return Scaffold(
          backgroundColor: Colors.grey.shade50,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.black87, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            title: const Text(
              '个人档案与设置',
              style: TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              children: <Widget>[
                _buildHeroSection(context, provider),
                const SizedBox(height: 40),
                _buildSectionTitle('账号安全'),
                _buildCard(
                  children: <Widget>[
                    _buildSettingsTile(
                      icon: provider.isAnonymous ? Icons.mark_email_unread_rounded : Icons.verified_user_rounded,
                      iconColor: provider.isAnonymous ? Colors.orange.shade600 : Colors.green.shade600,
                      title: provider.isAnonymous ? '绑定邮箱' : '已绑定邮箱',
                      subtitle: provider.isAnonymous ? '绑定后可跨设备同步数据' : _maskEmail(provider.currentUserEmail),
                      onTap: provider.isAnonymous ? () => _showBindEmailSheet(context) : null,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionTitle('通知设置'),
                _buildCard(
                  children: <Widget>[
                    _buildSettingsTile(
                      icon: Icons.notifications_active_rounded,
                      iconColor: Colors.amber.shade600,
                      title: '出行提醒',
                      subtitle: '航班/高铁出发前6小时、酒店入住当天早8点推送',
                      onTap: () => _showNotificationSettingsSheet(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSectionTitle('系统管理'),
                _buildCard(
                  children: <Widget>[
                    _buildSettingsTile(
                      icon: Icons.logout_rounded,
                      iconColor: Colors.red.shade400,
                      title: '退出登录',
                      titleColor: Colors.red.shade500,
                      onTap: () => _confirmSignOut(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(height: 1, color: Colors.grey.shade100),
                    ),
                    _buildSettingsTile(
                      icon: Icons.person_off_rounded,
                      iconColor: Colors.red.shade400,
                      title: '永久注销账号',
                      titleColor: Colors.red.shade500,
                      subtitle: '数据将不可恢复',
                      onTap: () => _confirmDeleteAccount(context),
                    ),
                  ],
                ),
                const SizedBox(height: 48),
                Text(
                  'GoNow v1.0.0',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade400,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  String _maskEmail(String email) {
    if (email.isEmpty) return '—';
    final int at = email.indexOf('@');
    if (at <= 0) return email;
    final String local = email.substring(0, at);
    final String domain = email.substring(at);
    if (local.length <= 2) return '**$domain';
    return '${local.substring(0, 2)}***$domain';
  }

  Widget _buildHeroSection(BuildContext context, ProfileProvider provider) {
    final String avatarStr = provider.avatarUrl ?? '';
    final bool hasUrl = avatarStr.isNotEmpty;

    return Column(
      children: <Widget>[
        GestureDetector(
          onTap: provider.isUploadingAvatar
              ? null
              : () async {
                  await provider.pickAndUploadAvatar();
                },
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                width: 100,
                height: 100,
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: Color(0x1F000000), blurRadius: 10),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(50),
                  // ✅ 终极修复：
                  // 1. ValueKey(avatarCacheKey) — key 变化时 Flutter 完全销毁
                  //    旧 element，创建全新 _AvatarImage 实例，不存在 State 复用
                  // 2. _AvatarImage 用 Image.network，完全绕开
                  //    CachedNetworkImage 的多层缓存
                  // 3. avatarUrl 存纯净 URL（不加 ?t= 参数），避免 Supabase 400
                  child: hasUrl
                      ? _AvatarImage(
                          key: ValueKey<String>(provider.avatarCacheKey),
                          url: avatarStr,
                          size: 50,
                        )
                      : ColoredBox(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.person, size: 50, color: Colors.grey),
                        ),
                ),
              ),
              if (provider.isUploadingAvatar)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(50),
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.7),
                      child: const Center(
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(color: Colors.indigo, strokeWidth: 2.5),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(color: Colors.indigo, shape: BoxShape.circle),
                  child: const Icon(Icons.camera_alt_rounded, size: 14, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => _showEditNameDialog(context, provider),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(provider.nickname, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(width: 8),
              Icon(Icons.edit_rounded, size: 18, color: Colors.grey.shade400),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade500,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    Color? titleColor,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        title,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: titleColor ?? Colors.black87),
      ),
      subtitle: subtitle != null
          ? Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600))
          : null,
      trailing: onTap != null ? Icon(Icons.chevron_right_rounded, color: Colors.grey.shade300, size: 22) : null,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dCtx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后将需要重新验证邮箱登录，确定要退出吗？'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('退出', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await Supabase.instance.client.auth.signOut();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).popUntil((Route<dynamic> route) => route.isFirst);
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dCtx) => AlertDialog(
        title: const Text(
          '永久注销账号',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '警告：注销后，您的所有旅行账本、足迹地图和偏好设置将被永久删除且无法恢复！\n\n确定要继续吗？',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('我再想想')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('确认销毁', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final bool success = await context.read<ProfileProvider>().deleteAccount();
    if (!context.mounted) return;
    if (success) {
      Navigator.of(context, rootNavigator: true).popUntil((Route<dynamic> route) => route.isFirst);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('注销失败，请稍后重试')),
      );
    }
  }

  void _showEditNameDialog(BuildContext context, ProfileProvider provider) {
    final TextEditingController controller = TextEditingController(text: provider.nickname);
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              FocusScope.of(ctx).unfocus();
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black87),
            onPressed: () async {
              FocusManager.instance.primaryFocus?.unfocus();
              await Future<void>.delayed(const Duration(milliseconds: 100));
              if (!ctx.mounted) return;
              provider.updateNickname(controller.text.trim());
              if (ctx.mounted) {
                await Navigator.maybePop(ctx);
              }
            },
            child: const Text('保存', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showNotificationSettingsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetCtx) {
        return _NotificationSettingsSheet();
      },
    );
  }

  /// 大气宽敞的邮箱绑定底部面板（OTP + 密码）。
  void _showBindEmailSheet(BuildContext context) {
    final BuildContext pageContext = context;

    _emailController.clear();
    _codeController.clear();
    _pwdController.clear();

    bool codeSent = false;
    bool isSending = false;
    String? localError;

    showModalBottomSheet<void>(
      context: pageContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetCtx) => StatefulBuilder(
        builder: (BuildContext ctx, void Function(void Function()) setModalState) => AnimatedPadding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 24),
                  const Text("绑定安全邮箱", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.black87)),
                  const SizedBox(height: 8),
                  const Text("为保障数据安全，我们需要验证您的邮箱地址。", style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 32),
                  
                  // --- 邮箱输入框 ---
                  const Text("邮箱地址", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50, 
                      borderRadius: BorderRadius.circular(16), 
                      border: Border.all(color: localError != null ? Colors.red.shade200 : Colors.grey.shade200),
                    ),
                    child: TextField(
                      controller: _emailController,
                      enabled: !codeSent,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(hintText: "example@gmail.com", border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
                      onChanged: (_) {
                        // 🚨 交互：用户一旦开始重新输入，就自动消除红字提示
                        if (localError != null) setModalState(() => localError = null);
                      },
                    ),
                  ),

                  // 🚨 核心修复：内联错误提示组件
                  if (localError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.redAccent, size: 14),
                          const SizedBox(width: 4),
                          Text(localError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),

                  const SizedBox(height: 20),

                  if (!codeSent)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        onPressed: isSending ? null : () async {
                          // 前置校验
                          if (_emailController.text.isEmpty || !_emailController.text.contains('@')) {
                            setModalState(() => localError = '请输入有效的邮箱地址');
                            return;
                          }
                          
                          setModalState(() {
                            isSending = true;
                            localError = null;
                          });
                          final bool ok =
                              await pageContext.read<ProfileProvider>().sendBindEmailCode(_emailController.text.trim());

                          if (ok) {
                            setModalState(() {
                              isSending = false;
                              codeSent = true;
                            });
                          } else {
                            setModalState(() {
                              isSending = false;
                              localError = '验证码发送失败，请检查网络或邮箱格式';
                            });
                          }
                        },
                        child: isSending
                            ? const SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                              )
                            : const Text(
                                '获取验证码',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                      ),
                    ),

                  if (codeSent) ...<Widget>[
                    Text(
                      '6位验证码',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo.shade700),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: TextField(
                        controller: _codeController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 16, letterSpacing: 4, fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(
                          hintText: '******',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '设置登录密码',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo.shade700),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: TextField(
                        controller: _pwdController,
                        obscureText: true,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(
                          hintText: '至少6位',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black87,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: () async {
                          if (_codeController.text.trim().isEmpty || _pwdController.text.length < 6) {
                            setModalState(() => localError = '请填写验证码及至少6位密码');
                            return;
                          }
                          setModalState(() => localError = null);

                          final ProfileProvider profile = pageContext.read<ProfileProvider>();

                          FocusManager.instance.primaryFocus?.unfocus();
                          await Future<void>.delayed(const Duration(milliseconds: 100));

                          if (!sheetCtx.mounted || !ctx.mounted) return;

                          final bool bindOk = await profile.verifyAndBindEmail(
                            _emailController.text.trim(),
                            _codeController.text.trim(),
                            _pwdController.text.trim(),
                          );
                          if (!sheetCtx.mounted || !ctx.mounted) return;
                          if (bindOk) {
                            await profile.fetchProfile();
                            if (!sheetCtx.mounted) return;
                            await Navigator.maybePop(sheetCtx);
                            if (!mounted || !pageContext.mounted) return;
                            ScaffoldMessenger.of(pageContext).showSnackBar(
                              const SnackBar(content: Text('邮箱绑定成功！')),
                            );
                          } else if (ctx.mounted) {
                            setModalState(() => localError = '验证码错误或绑定失败，请重试');
                          }
                        },
                        child: const Text(
                          '确认并绑定',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// ✅ 核心：用 Image.network 替代 CachedNetworkImage，配合外部 ValueKey 使用。
//
// 使用方式：
//   _AvatarImage(key: ValueKey<String>(provider.avatarCacheKey), url: avatarUrl)
//
// 原理：
//   - ValueKey 变化 → Flutter 销毁旧 element，创建全新实例
//   - initState 重新执行，ImageProvider 重新创建
//   - Image.network 不走 flutter_cache_manager 磁盘缓存
//   - avatarUrl 是纯净 Supabase URL（不加 ?t= 参数），避免 HTTP 400
// =============================================================================
class _AvatarImage extends StatefulWidget {
  const _AvatarImage({super.key, required this.url, this.size = 50});
  final String url;
  final double size;

  @override
  State<_AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends State<_AvatarImage> {
  @override
  void initState() {
    super.initState();
    debugPrint('🖼️ _AvatarImage initState url=${widget.url}');
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      widget.url,
      fit: BoxFit.cover,
      loadingBuilder: (BuildContext ctx, Widget child, ImageChunkEvent? progress) {
        if (progress == null) return child;
        return ColoredBox(
          color: Colors.grey.shade100,
          child: Center(
            child: SizedBox(
              width: widget.size * 0.5,
              height: widget.size * 0.5,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                    : null,
              ),
            ),
          ),
        );
      },
      errorBuilder: (BuildContext ctx, Object error, StackTrace? stack) {
        debugPrint('❌ _AvatarImage error: $error');
        return ColoredBox(
          color: Colors.grey.shade200,
          child: Icon(Icons.person, size: widget.size, color: Colors.grey.shade400),
        );
      },
    );
  }
}


// =============================================================================
// 通知设置 Sheet
// =============================================================================
class _NotificationSettingsSheet extends StatefulWidget {
  @override
  State<_NotificationSettingsSheet> createState() =>
      _NotificationSettingsSheetState();
}

class _NotificationSettingsSheetState
    extends State<_NotificationSettingsSheet> {
  int _hoursAhead = 6;
  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    _checkAndRequest();
  }

  Future<void> _checkAndRequest() async {
    final bool granted =
        await NotificationService.instance.requestPermission();
    if (mounted) setState(() => _permissionGranted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final double bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                Icon(Icons.notifications_active_rounded,
                    color: Colors.amber.shade600),
                const SizedBox(width: 8),
                const Text(
                  '出行提醒设置',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // 权限状态卡
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _permissionGranted
                    ? Colors.green.shade50
                    : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _permissionGranted
                      ? Colors.green.shade200
                      : Colors.orange.shade200,
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    _permissionGranted
                        ? Icons.check_circle_rounded
                        : Icons.warning_amber_rounded,
                    color: _permissionGranted
                        ? Colors.green.shade600
                        : Colors.orange.shade600,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _permissionGranted
                          ? '通知权限已开启，提醒功能正常运行'
                          : '通知权限未授予，请前往系统设置手动开启',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _permissionGranted
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                      ),
                    ),
                  ),
                  if (!_permissionGranted)
                    TextButton(
                      onPressed: _checkAndRequest,
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '提前提醒时间（航班 / 高铁）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54),
            ),
            const SizedBox(height: 12),
            // 提前时间选择
            Row(
              children: <int>[1, 2, 3, 6].map((int h) {
                final bool selected = _hoursAhead == h;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _hoursAhead = h),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.indigo.shade600
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '$h 小时',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: selected
                                ? Colors.white
                                : Colors.black54,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Text(
              '酒店提醒将固定在入住当天早上 8:00 推送',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '完成',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
