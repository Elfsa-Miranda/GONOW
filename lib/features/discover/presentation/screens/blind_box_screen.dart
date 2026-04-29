import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gonow/core/models/city_model.dart';
import 'package:gonow/core/providers/travel_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:provider/provider.dart';

class BlindBoxScreen extends StatefulWidget {
  const BlindBoxScreen({super.key, this.isInternational = false});

  final bool isInternational;

  @override
  State<BlindBoxScreen> createState() => _BlindBoxScreenState();
}

class _BlindBoxScreenState extends State<BlindBoxScreen>
    with TickerProviderStateMixin {
  static const Map<String, String> _defenseHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };
  // 产品固定规格：周末盲盒主图区域始终占 60%，禁止后续随意改动。
  static const int _heroTopFlex = 6;
  static const int _heroBottomFlex = 4;

  bool _isCustomizingDays = false;
  String _finalDaysText = '听AI安排';
  int _currentIndex = 0;
  bool _isShaking = false;

  int _tempDay = 3;
  int _tempNight = 2;
  int _pickedDay = 3;
  int _pickedNight = 2;
  late final FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _nightController;

  late final AnimationController _shakeController;
  late final AnimationController _panelSlideController;
  late final Animation<Offset> _panelSlideAnimation;
  late final Animation<double> _shakeRotationAnimation;
  late final Animation<double> _shakeScaleAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _dayController = FixedExtentScrollController(initialItem: _tempDay - 1);
    _nightController = FixedExtentScrollController(initialItem: _tempNight);
    _shakeRotationAnimation =
        TweenSequence<double>(<TweenSequenceItem<double>>[
          TweenSequenceItem<double>(
            tween: Tween<double>(begin: -0.06, end: 0.06),
            weight: 1,
          ),
          TweenSequenceItem<double>(
            tween: Tween<double>(begin: 0.06, end: -0.06),
            weight: 1,
          ),
          TweenSequenceItem<double>(
            tween: Tween<double>(begin: -0.06, end: 0.06),
            weight: 1,
          ),
          TweenSequenceItem<double>(
            tween: Tween<double>(begin: 0.06, end: -0.04),
            weight: 1,
          ),
          TweenSequenceItem<double>(
            tween: Tween<double>(begin: -0.04, end: 0.0),
            weight: 1,
          ),
        ]).animate(
          CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut),
        );
    _shakeScaleAnimation = TweenSequence<double>(
      <TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 0.94, end: 1.08),
          weight: 2,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 1.08, end: 0.96),
          weight: 2,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 0.96, end: 1.02),
          weight: 1,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 1.02, end: 1.0),
          weight: 1,
        ),
      ],
    ).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeOut));
    _panelSlideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _panelSlideAnimation =
        Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _panelSlideController,
            curve: Curves.easeOutCubic,
          ),
        );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final TravelProvider provider = Provider.of<TravelProvider>(
        context,
        listen: false,
      );
      if (widget.isInternational) {
        if (provider.internationalCountries.isEmpty) {
          provider.fetchInternationalCountries();
        }
      } else {
        if (provider.cities.isEmpty) {
          provider.refreshBlindBox();
        }
      }
      final bool hasData = widget.isInternational
          ? provider.internationalCountries.isNotEmpty
          : provider.cities.isNotEmpty;
      if (hasData) {
        _panelSlideController.forward(from: 0);
      }
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _panelSlideController.dispose();
    _dayController.dispose();
    _nightController.dispose();
    super.dispose();
  }

  Future<void> _reRoll(int poolLength) async {
    if (_isShaking || poolLength <= 0) return;
    setState(() => _isShaking = true);

    await HapticFeedback.vibrate();
    await _shakeController.forward(from: 0);
    if (!mounted) return;

    final int oldIndex = _currentIndex;
    int newIndex = oldIndex;
    if (poolLength > 1) {
      do {
        newIndex = math.Random().nextInt(poolLength);
      } while (newIndex == oldIndex);
    }
    setState(() {
      _currentIndex = newIndex;
      _isShaking = false;
      _isCustomizingDays = false;
    });
    _panelSlideController.forward(from: 0);
  }

  void _confirmCustomDays() {
    final int day = _tempDay;
    int night = _tempNight;
    if (night != day && night != day - 1) {
      night = day - 1;
    }
    if (night < 0) {
      night = 0;
    }
    setState(() {
      _pickedDay = day;
      _pickedNight = night;
      _finalDaysText = '${_pickedDay}天${_pickedNight}夜';
      _isCustomizingDays = false;
    });
    if (_nightController.hasClients) {
      _nightController.animateToItem(
        _pickedNight,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

// 极度鲁棒的数据提取（完全匹配你的 CityModel 强类型）
  Map<String, dynamic> _mapCurrentData(TravelProvider provider) {
    if (widget.isInternational) {
      final country = provider.internationalCountries[_currentIndex];
      return {
        'name': '${country['flag_emoji'] ?? '🌍'} ${country['name'] ?? ''}',
        'imageUrl': country['image_url']?.toString() ?? '',
        'subtitle': '🌍 环球旅行，精选热门目的地',
        'tags': ['🌍 ${country['continent'] ?? '全球'}', ...List<String>.from(country['tags'] ?? [])],
      };
    } else {
      final city = provider.cities[_currentIndex];
      // 你的 cities 是标准的 CityModel 类，直接点属性取值，不需要兼容 Map！
      return {
        'name': city.name,
        'imageUrl': city.imageUrl,
        'subtitle': city.subtitle,
        'tags': city.tags,
      };
    }
  }
  void _generatePlan(Map<String, dynamic> data) {
    final String prompt =
        '我刚刚抽中了旅行盲盒：${data['name']}！请帮我规划一趟完美的旅行攻略。游玩时长：$_finalDaysText。请你根据这个时长和城市的特色，为我定制每日的详细路线，并包含必吃美食和防坑指南。';
    final MainNavProvider navProvider = Provider.of<MainNavProvider>(
      context,
      listen: false,
    );
    navProvider.triggerAiPlanning(prompt);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TravelProvider>(
      builder: (BuildContext context, TravelProvider provider, _) {
        final bool isLoading = widget.isInternational
            ? provider.isIntlLoading
            : provider.isBlindBoxLoading;
        final String? errorMessage = widget.isInternational
            ? provider.intlError
            : provider.blindBoxError;
        final int poolLength = widget.isInternational
            ? provider.internationalCountries.length
            : provider.cities.length;

        if (isLoading && poolLength == 0) {
          return _buildFullLoading();
        }
        if (errorMessage != null && poolLength == 0) {
          return _buildError(errorMessage);
        }
        if (poolLength == 0) {
          return _buildEmpty();
        }

        if (_currentIndex >= poolLength) {
          _currentIndex = 0;
        }
        final Map<String, dynamic> currentData = _mapCurrentData(provider);
        final int topFlex = _heroTopFlex;
        final int bottomFlex = _heroBottomFlex;

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  Expanded(flex: topFlex, child: _buildTopHero(currentData)),
                  Expanded(
                    flex: bottomFlex,
                    child: SlideTransition(
                      position: _panelSlideAnimation,
                      child: _buildBottomPanel(currentData, poolLength),
                    ),
                  ),
                ],
              ),
              if (_isShaking) _buildShakeOverlay(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopHero(Map<String, dynamic> data) {
    final String name = data['name']?.toString() ?? '';
    final String subtitle = data['subtitle']?.toString() ?? '';
    final List<String> tags = List<String>.from(data['tags'] ?? <dynamic>[]);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        CachedNetworkImage(
          imageUrl: data['imageUrl']?.toString() ?? '',
          fit: BoxFit.cover,
          httpHeaders: _defenseHeaders,
          placeholder: (context, url) => _buildSkeletonLoader(),
          errorWidget: (context, url, error) => _buildBackupImageFallback(name),
        ),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.transparent,
                Colors.transparent,
                Colors.black87,
              ],
              stops: <double>[0.0, 0.45, 1.0],
            ),
          ),
        ),
        SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: tags
                            .map(
                              (String tag) => Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.14),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  tag,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomPanel(Map<String, dynamic> data, int poolLength) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 8),
            !_isCustomizingDays
                ? _buildDecisionPanel(data)
                : _buildCustomizePanel(),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: OutlinedButton(
                    onPressed: () => _reRoll(poolLength),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: const StadiumBorder(),
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 12,
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const <Widget>[
                          Icon(Icons.casino_rounded, size: 16),
                          SizedBox(width: 4),
                          Text(
                            '再抽一次',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: FilledButton(
                    onPressed: () => _generatePlan(data),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('🚀 生成专属行程'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDecisionPanel(Map<String, dynamic> data) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            setState(() => _finalDaysText = '听AI安排');
            _generatePlan(data);
          },
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('✨ 听 AI 安排'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: const StadiumBorder(),
            foregroundColor: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () => setState(() => _isCustomizingDays = true),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: const StadiumBorder(),
            foregroundColor: Colors.grey.shade700,
            side: BorderSide(color: Colors.grey.shade300),
          ),
          child: const Text('🗓️ 自己决定游玩时长'),
        ),
        const SizedBox(height: 16),
        Text(
          '当前选择：$_finalDaysText',
          style: TextStyle(
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildCustomizePanel() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 4),
        const Text(
          '滑动选择您的游玩天数',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: Row(
            children: <Widget>[
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 32,
                  magnification: 1.1,
                  useMagnifier: true,
                  scrollController: _dayController,
                  onSelectedItemChanged: (int value) {
                    _tempDay = value + 1;
                    final int nextNight = (_tempDay - 1).clamp(0, 14);
                    _tempNight = nextNight;
                    if (_nightController.hasClients) {
                      _nightController.animateToItem(
                        nextNight,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                      );
                    }
                  },
                  children: List<Widget>.generate(
                    15,
                    (int i) => Center(child: Text('${i + 1}天')),
                  ),
                ),
              ),
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 32,
                  magnification: 1.1,
                  useMagnifier: true,
                  scrollController: _nightController,
                  onSelectedItemChanged: (int value) => _tempNight = value,
                  children: List<Widget>.generate(
                    15,
                    (int i) => Center(child: Text('${i}夜')),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 52,
          child: Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _isCustomizingDays = false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _confirmCustomDays,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildShakeOverlay() {
    return Positioned.fill(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: AnimatedBuilder(
          animation: _shakeController,
          builder: (BuildContext context, _) {
            return Container(
              color: Colors.black.withOpacity(0.38),
              child: Center(
                child: RotationTransition(
                  turns: _shakeRotationAnimation,
                  child: ScaleTransition(
                    scale: _shakeScaleAnimation,
                    child: Container(
                      width: 118,
                      height: 118,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.deepPurple.withOpacity(0.25),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.purpleAccent.withOpacity(0.58),
                            blurRadius: 30,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.card_giftcard_rounded,
                        color: Colors.white,
                        size: 62,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSkeletonLoader() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF2B2F38),
            Color(0xFF1A1E27),
            Color(0xFF2B2F38),
          ],
        ),
      ),
    );
  }

  Widget _buildBackupImageFallback(String cityName) {
    return Image.network(
      'https://api.dujin.org/bing/m.php',
      fit: BoxFit.cover,
      headers: _defenseHeaders,
      errorBuilder:
          (BuildContext context, Object error, StackTrace? stackTrace) {
            return _buildDefenseFallback(cityName);
          },
    );
  }

  Widget _buildDefenseFallback(String cityName) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF272B35), Color(0xFF10141C)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(
            child: Opacity(
              opacity: 0.1,
              child: Text(
                cityName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 88,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const Center(
            child: Icon(
              Icons.bubble_chart_rounded,
              size: 64,
              color: Colors.white24,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullLoading() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0xFF151922), Color(0xFF080B12)],
              ),
            ),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(color: Colors.black.withOpacity(0.2)),
          ),
          const Center(child: CircularProgressIndicator(strokeWidth: 3)),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_rounded,
              color: Colors.grey.shade500,
              size: 40,
            ),
            const SizedBox(height: 10),
            Text(message, style: TextStyle(color: Colors.grey.shade300)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                final TravelProvider provider = Provider.of<TravelProvider>(
                  context,
                  listen: false,
                );
                provider.refreshBlindBox(force: true);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          '目的地正在扩容中...',
          style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
        ),
      ),
    );
  }
}
