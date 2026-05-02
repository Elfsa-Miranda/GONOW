import 'package:flutter/foundation.dart';

class MainNavProvider extends ChangeNotifier {
  int _currentIndex = 0;
  int _openAiRequestToken = 0;
  String? pendingAiPrompt;
  String? pendingAiSource;
  bool shouldAutoSendAi = false;
  bool isAiPlanning = false;

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

  void goToDiaryTab() {
    setTab(2);
  }

  @Deprecated('OOTD 已降级为二级页，请改用 goToDiaryTab')
  void goToOotdTab() {
    goToDiaryTab();
  }

  void requestOpenAiSheet({
    String? source,
    String? initialPrompt,
    bool? autoSend,
  }) {
    if (source != null) {
      pendingAiSource = source;
    }
    if (initialPrompt != null) {
      pendingAiPrompt = initialPrompt;
    }
    if (autoSend != null) {
      shouldAutoSendAi = autoSend;
    }
    _openAiRequestToken++;
    notifyListeners();
  }

  void triggerAiPlanning(
    String prompt, {
    String? source,
    bool autoSend = true,
  }) {
    pendingAiPrompt = prompt;
    pendingAiSource = source;
    shouldAutoSendAi = autoSend;
    _openAiRequestToken++;
    notifyListeners();
  }

  void clearAiPendingState() {
    pendingAiPrompt = null;
    pendingAiSource = null;
    shouldAutoSendAi = false;
    notifyListeners();
  }

  void setAiPlanning(bool value) {
    if (isAiPlanning == value) {
      return;
    }
    isAiPlanning = value;
    notifyListeners();
  }
}
