import 'package:flutter/material.dart';
import 'package:gonow/core/providers/travel_provider.dart';
import 'package:gonow/features/auth/data/auth_provider.dart';
import 'package:gonow/features/auth/presentation/auth_screen.dart';
import 'package:gonow/features/diary/data/diary_provider.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
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
        ChangeNotifierProvider<DiaryProvider>(
          create: (_) => DiaryProvider(),
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
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

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
        final Session? session = snapshot.data?.session;
        if (session != null) {
          return const MainScreen();
        }
        return const AuthScreen();
      },
    );
  }
}
