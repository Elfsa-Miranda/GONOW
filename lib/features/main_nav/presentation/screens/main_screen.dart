import 'package:flutter/material.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:provider/provider.dart';

import '../../../ai_custom/presentation/screens/ai_custom_screen.dart';
import '../../../diary/presentation/screens/diary_center_screen.dart';
import '../../../discover/presentation/screens/discover_screen.dart';
import '../../../itinerary/presentation/screens/itinerary_screen.dart';
import '../../../profile/presentation/screens/profile_screen.dart';
import '../widgets/custom_bottom_bar.dart';
import '../widgets/custom_fab.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _handledAiRequestToken = 0;

  late final List<Widget> _pages = <Widget>[
    const DiscoverScreen(),
    const ItineraryScreen(),
    const DiaryCenterScreen(),
    const ProfileScreen(),
  ];

  void _onTabChanged(int index) {
    context.read<MainNavProvider>().setTab(index);
  }

  void _onAiFabPressed() {
    final MainNavProvider provider = context.read<MainNavProvider>();
    if (provider.pendingAiPrompt == null || provider.pendingAiPrompt!.isEmpty) {
      provider.pendingAiPrompt = '带父母去北京玩五天经典路线';
      provider.shouldAutoSendAi = true;
    }
    provider.requestOpenAiSheet();
  }

  String _sourceLabelForIndex(int index) {
    return switch (index) {
      0 => '发现页',
      1 => '行程页',
      2 => '手账页',
      3 => '我的页',
      _ => '底部导航栏',
    };
  }

  Future<void> _showAiCustomSheet() async {
    final MainNavProvider provider = context.read<MainNavProvider>();
    final String? pendingPrompt = provider.pendingAiPrompt?.trim();
    final String? initialPrompt =
        pendingPrompt != null && pendingPrompt.isNotEmpty
        ? pendingPrompt
        : null;
    final String source =
        provider.pendingAiSource ?? _sourceLabelForIndex(provider.currentIndex);
    final bool? shouldOpenItinerary = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      showDragHandle: true,
      builder: (BuildContext context) {
        final double screenHeight = MediaQuery.of(context).size.height;
        final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
        final double keyboardRatio = (bottomInset / screenHeight).clamp(
          0.0,
          0.35,
        );
        final double heightFactor = (0.72 + (keyboardRatio / 0.35) * 0.23)
            .clamp(0.72, 0.95);
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.72, end: heightFactor),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutQuart,
          child: AiCustomScreen(source: source, initialPrompt: initialPrompt),
          builder: (BuildContext context, double value, Widget? child) {
            return FractionallySizedBox(heightFactor: value, child: child);
          },
        );
      },
    );
    if (shouldOpenItinerary == true && mounted) {
      context.read<MainNavProvider>().goToItineraryTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    final MainNavProvider navProvider = context.watch<MainNavProvider>();
    if (navProvider.openAiRequestToken > _handledAiRequestToken) {
      _handledAiRequestToken = navProvider.openAiRequestToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showAiCustomSheet();
        }
      });
    }

    return Scaffold(
      body: IndexedStack(index: navProvider.currentIndex, children: _pages),
      bottomNavigationBar: CustomBottomBar(
        currentIndex: navProvider.currentIndex,
        onDestinationSelected: _onTabChanged,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: CustomFab(onPressed: _onAiFabPressed),
    );
  }
}
