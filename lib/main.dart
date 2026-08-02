import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:gonow/core/providers/travel_provider.dart';
import 'package:gonow/core/config/agent_service_config.dart';
import 'package:gonow/core/services/notification_service.dart';
import 'package:gonow/features/auth/data/auth_provider.dart';
import 'package:gonow/features/auth/presentation/auth_screen.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:gonow/features/ledger/data/ledger_provider.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:gonow/features/profile/data/footprint_provider.dart';
import 'package:gonow/features/profile/data/profile_provider.dart';
import 'package:gonow/features/splash/presentation/screens/splash_screen.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/theme/app_theme.dart';
import 'features/main_nav/presentation/screens/main_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ 只做必须的初始化（Supabase 必须在 runApp 前完成）
  await Supabase.initialize(
    url: 'https://axoewadtumvbxzsxpsuc.supabase.co',
    anonKey: 'sb_publishable_Yrg6dWTx3cB5S3OIJafkYA_7uweoExy',
  );

  // ✅ 初始化本地通知服务
  await NotificationService.instance.init();

  // ✅ 立即启动 UI，不阻塞任何数据加载
  runApp(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<MainNavProvider>(
          create: (_) => MainNavProvider(),
        ),
        // ❌ 移除了 create 时的 fetchCulturalCustoms() 调用
        // ✅ 改为在需要时懒加载（在对应页面的 initState 中调用）
        ChangeNotifierProvider<TravelProvider>(create: (_) => TravelProvider()),
        // ❌ 移除了 create 时的 fetchActiveItinerary() 调用
        ChangeNotifierProvider<ItineraryProvider>(
          create: (_) => ItineraryProvider(
            agentFeatureFlags: AgentServiceConfig.environment.featureFlags,
          ),
        ),
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        // ❌ 移除了 create 时的 fetchProfile() 调用
        ChangeNotifierProvider<ProfileProvider>(
          create: (_) => ProfileProvider(),
        ),
        ChangeNotifierProvider<FootprintProvider>(
          create: (_) => FootprintProvider(),
        ),
        ChangeNotifierProvider<DiaryProvider>(create: (_) => DiaryProvider()),
        ChangeNotifierProvider<LedgerProvider>(create: (_) => LedgerProvider()),
      ],
      child: const GoNowApp(),
    ),
  );
}

class GoNowApp extends StatelessWidget {
  const GoNowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoNow',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en', 'US')],
      home: const SplashWrapper(),
    );
  }
}

/// 启动页包装器：显示启动页 1.5 秒后进入 AuthGate
class SplashWrapper extends StatefulWidget {
  const SplashWrapper({super.key});

  @override
  State<SplashWrapper> createState() => _SplashWrapperState();
}

class _SplashWrapperState extends State<SplashWrapper> {
  @override
  void initState() {
    super.initState();
    // 显示启动页 500 毫秒后进入 AuthGate（缩短时间，因为 Logo 已包含动画）
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const AuthGate()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const SplashScreen();
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _authSubscription;

  /// 避免同一用户重复拉取；登出后清空，下次登录再拉。
  String? _diarySyncedForUserId;

  /// 来自邮件重置链接，需在设置新密码前进 MainScreen。
  bool _awaitingPasswordReset = false;

  bool _recoveryDialogScheduled = false;

  @override
  void initState() {
    super.initState();
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((
      AuthState data,
    ) {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        setState(() => _awaitingPasswordReset = true);
        if (!_recoveryDialogScheduled) {
          _recoveryDialogScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _showNewPasswordDialog(context);
          });
        }
      }

      final Session? session = data.session;
      if (session != null) {
        if (data.event == AuthChangeEvent.passwordRecovery ||
            _awaitingPasswordReset) {
          return;
        }
        final String currentUserId = session.user.id;
        if (_diarySyncedForUserId != currentUserId) {
          _diarySyncedForUserId = currentUserId;
          if (kDebugMode) {
            debugPrint('🔐 [AuthGate] 监听到用户切换 ($currentUserId)，开始全局数据同步...');
          }
          if (!mounted) return;

          // ✅ 在用户登录后，异步加载所有数据（不阻塞 UI）
          final DiaryProvider diaryProvider = context.read<DiaryProvider>();
          diaryProvider.fetchMyData();
          diaryProvider.fetchCommunityDiaries();

          // ✅ 懒加载其他 Provider 的数据
          final TravelProvider travelProvider = context.read<TravelProvider>();
          travelProvider.fetchCulturalCustoms();

          final ItineraryProvider itineraryProvider = context
              .read<ItineraryProvider>();
          itineraryProvider.fetchActiveItinerary();

          final ProfileProvider profileProvider = context
              .read<ProfileProvider>();
          profileProvider.fetchProfile();

          final FootprintProvider footprintProvider = context
              .read<FootprintProvider>();
          footprintProvider.fetchFootprint();
        }
      } else {
        _recoveryDialogScheduled = false;
        _awaitingPasswordReset = false;
        if (_diarySyncedForUserId != null) {
          if (kDebugMode) {
            debugPrint('🔐 [AuthGate] 监听到用户登出，清理同步标记');
          }
          _diarySyncedForUserId = null;
        }
      }
    });
  }

  Future<void> _showNewPasswordDialog(BuildContext originContext) async {
    final TextEditingController passwordController = TextEditingController();
    final TextEditingController confirmController = TextEditingController();

    await showDialog<void>(
      context: originContext,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('重置密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '新密码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认密码',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                _recoveryDialogScheduled = false;
                await Supabase.instance.client.auth.signOut();
                if (mounted) {
                  setState(() => _awaitingPasswordReset = false);
                }
              },
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final String p = passwordController.text.trim();
                final String c = confirmController.text.trim();
                if (p.length < 6) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(const SnackBar(content: Text('密码至少 6 位')));
                  return;
                }
                if (p != c) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(const SnackBar(content: Text('两次密码不一致')));
                  return;
                }
                final AuthProvider auth = originContext.read<AuthProvider>();
                final bool ok = await auth.updateNewPassword(p, dialogContext);
                if (!dialogContext.mounted) return;
                if (ok) {
                  Navigator.pop(dialogContext);
                  _recoveryDialogScheduled = false;
                  await auth.signOut();
                  if (mounted) {
                    setState(() => _awaitingPasswordReset = false);
                  }
                }
              },
              child: const Text('确认'),
            ),
          ],
        );
      },
    ).whenComplete(() {
      passwordController.dispose();
      confirmController.dispose();
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (BuildContext context, AsyncSnapshot<AuthState> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator(color: Colors.white)),
          );
        }
        final AuthState? authState = snapshot.hasData ? snapshot.data : null;
        final Session? session = authState?.session;
        final bool recoveryGate =
            _awaitingPasswordReset ||
            authState?.event == AuthChangeEvent.passwordRecovery;
        if (session != null && recoveryGate) {
          return Scaffold(
            backgroundColor: Colors.white,
            body: SafeArea(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.lock_reset,
                      size: 48,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '请在新窗口中设置新密码',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (session != null) {
          return const MainScreen();
        }
        return const AuthScreen();
      },
    );
  }
}
