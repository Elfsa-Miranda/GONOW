import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:gonow/core/providers/travel_provider.dart';
import 'package:gonow/features/auth/data/auth_provider.dart';
import 'package:gonow/features/auth/presentation/auth_screen.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:gonow/features/ledger/data/ledger_provider.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:gonow/features/profile/data/profile_provider.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/theme/app_theme.dart';
import 'features/main_nav/presentation/screens/main_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://axoewadtumvbxzsxpsuc.supabase.co',
    anonKey: 'sb_publishable_Yrg6dWTx3cB5S3OIJafkYA_7uweoExy',
  );

  runApp(
    MultiProvider(
      providers: <ChangeNotifierProvider<dynamic>>[
        ChangeNotifierProvider<MainNavProvider>(
          create: (_) => MainNavProvider(),
        ),
        ChangeNotifierProvider<TravelProvider>(
          create: (_) {
            final TravelProvider provider = TravelProvider();
            provider.fetchCulturalCustoms();
            return provider;
          },
        ),
        ChangeNotifierProvider<ItineraryProvider>(
          create: (_) {
            final ItineraryProvider provider = ItineraryProvider();
            provider.fetchActiveItinerary();
            return provider;
          },
        ),
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(),
        ),
        ChangeNotifierProvider<ProfileProvider>(
          create: (_) {
            final ProfileProvider p = ProfileProvider();
            p.fetchProfile();
            return p;
          },
        ),
        ChangeNotifierProvider<DiaryProvider>(
          create: (_) => DiaryProvider(),
        ),
        ChangeNotifierProvider<LedgerProvider>(
          create: (_) => LedgerProvider(),
        ),
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
      supportedLocales: const <Locale>[
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      home: const AuthGate(),
    );
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

  @override
  void initState() {
    super.initState();
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((AuthState data) {
      final Session? session = data.session;
      if (session != null) {
        final String currentUserId = session.user.id;
        if (_diarySyncedForUserId != currentUserId) {
          _diarySyncedForUserId = currentUserId;
          if (kDebugMode) {
            debugPrint(
              '🔐 [AuthGate] 监听到用户切换 ($currentUserId)，开始全局数据同步...',
            );
          }
          if (!mounted) return;
          final DiaryProvider diaryProvider = context.read<DiaryProvider>();
          diaryProvider.fetchMyData();
          diaryProvider.fetchCommunityDiaries();
        }
      } else {
        if (_diarySyncedForUserId != null) {
          if (kDebugMode) {
            debugPrint('🔐 [AuthGate] 监听到用户登出，清理同步标记');
          }
          _diarySyncedForUserId = null;
        }
      }
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
            body: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          );
        }
        final Session? session =
            snapshot.hasData ? snapshot.data!.session : null;
        if (session != null) {
          return const MainScreen();
        }
        return const AuthScreen();
      },
    );
  }
}
