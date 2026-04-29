import 'package:flutter/foundation.dart';

class MainNavProvider extends ChangeNotifier {
  int _currentIndex = 0;
  int _openAiRequestToken = 0;
  String? pendingAiPrompt;
  bool shouldAutoSendAi = false;

  int get currentIndex => _currentIndex;
  int get openAiRequestToken => _openAiRequestToken;

  void setTab(int index) {
    if (_currentIndex == index) {
      return;
    }
    _currentIndex = index;
    notifyListeners();
  }

  void goToItineraryTab() {
    setTab(1);
  }

  void goToOotdTab() {
    setTab(2);
  }

  void requestOpenAiSheet() {
    _openAiRequestToken++;
    notifyListeners();
  }

  void triggerAiPlanning(String prompt) {
    pendingAiPrompt = prompt;
    shouldAutoSendAi = true;
    _openAiRequestToken++;
    notifyListeners();
  }

  void clearAiPendingState() {
    pendingAiPrompt = null;
    shouldAutoSendAi = false;
    notifyListeners();
  }
}
