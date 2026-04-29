import 'package:flutter/material.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:provider/provider.dart';

import '../../../ai_custom/presentation/screens/ai_custom_screen.dart';
import '../../../discover/presentation/screens/discover_screen.dart';
import '../../../itinerary/presentation/screens/itinerary_screen.dart';
import '../../../ootd/presentation/screens/ootd_screen.dart';
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
    const OotdScreen(),
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

  Future<void> _showAiCustomSheet() async {
    final bool? shouldOpenItinerary = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext context) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: const FractionallySizedBox(
            heightFactor: 0.72,
            child: AiCustomScreen(),
          ),
        );
      },
    );
    if (shouldOpenItinerary == true) {
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
