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
    final String source = _sourceLabelForIndex(provider.currentIndex);
    // 用户主动点击 FAB 打开面板：只传入 source，不设置 autoSend=true。
    // 让用户自己决定是否发送，而非自动触发。
    // 若此时恰好有外部注入的 pendingAiPrompt，它会作为输入框 hint 显示，
    // 但不会被自动发送。
    provider.requestOpenAiSheet(source: source);
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
    // 在打开 sheet 前读取 autoSend 意图，然后立即清除 provider 状态。
    // 这样 AiCustomScreen 内部不再需要监听全局 shouldAutoSendAi，
    // 避免 sheet rebuild 时重复触发或状态残留导致误触发。
    final bool autoSend = provider.shouldAutoSendAi &&
        initialPrompt != null &&
        initialPrompt.isNotEmpty;
    provider.clearAiPendingState();

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
          child: AiCustomScreen(
            source: source,
            initialPrompt: initialPrompt,
            autoSend: autoSend,
          ),
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