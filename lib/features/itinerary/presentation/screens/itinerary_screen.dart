import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'package:amap_flutter_base/amap_flutter_base.dart' as amap_base;
import 'package:amap_flutter_map/amap_flutter_map.dart' as amap;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gonow/core/constants/ai_config.dart';
import 'package:gonow/core/constants/amap_config.dart';
import 'package:gonow/features/common/presentation/widgets/full_screen_photo_gallery.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

enum _MapSource { amap, google }

class ItineraryScreen extends StatefulWidget {
  const ItineraryScreen({super.key});

  @override
  State<ItineraryScreen> createState() => _ItineraryScreenState();
}

class _ItineraryScreenState extends State<ItineraryScreen>
    with SingleTickerProviderStateMixin {
  final _MapSource _mapSource = _MapSource.amap;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSub;
  final ScrollController _scrollController = ScrollController();
  gmap.GoogleMapController? _googleController;
  amap.AMapController? _aMapController;
  late final AnimationController _pulseController;

  int _selectedDayIndex = 0; // 0=全览, 1..N=第N天
  ActivityItem? _selectedActivity;
  bool _isMapLoading = true;
  String _markerCachePlanKey = '__pending__';
  bool _isMapCollapsed = false;
  bool _allowAutoFitOnMapCreate = true;
  String? _focusedTimelineKey;
  late final List<Map<String, dynamic>> _mockTimeline;
  final Map<String, bool> _timelineArrivedOverride = <String, bool>{};
  final GlobalKey _timelineListTopKey = GlobalKey();
  final Map<String, GlobalKey> _timelineItemKeys = <String, GlobalKey>{};
  final Map<String, Map<String, dynamic>> _timelineItemByKey =
      <String, Map<String, dynamic>>{};

  final Map<String, gmap.BitmapDescriptor> _googleMarkerCache =
      <String, gmap.BitmapDescriptor>{};
  final Map<String, amap.BitmapDescriptor> _amapMarkerCache =
      <String, amap.BitmapDescriptor>{};

  // 高德真实路网缓存：key = "lat1,lng1|lat2,lng2"
  final Map<String, List<amap_base.LatLng>> _routeCache =
      <String, List<amap_base.LatLng>>{};
  final Map<String, _RouteFetchResult> _routeResultCache =
      <String, _RouteFetchResult>{};
  final Set<String> _routeFallbackKeys = <String>{};
  final Map<int, amap.BitmapDescriptor> _amapArrowTextureByDay =
      <int, amap.BitmapDescriptor>{};
  final Map<String, Map<String, dynamic>> _timelineTransitOverride =
      <String, Map<String, dynamic>>{};
  String _routeSyncPlanKey = '__pending__';
  List<String> _selectedActivityImages = <String>[];
  int? _uploadingDayIdx;
  int? _uploadingActIdx;
  final ImagePicker _imagePicker = ImagePicker();

  // --- 沉浸式编辑态 ---
  bool _isEditing = false;
  Map<String, dynamic>? _editablePlanData;
  /// 编辑前 [planData] 快照（取消时用于回滚云端）
  Map<String, dynamic>? _planDataSnapshot;
  /// 快照对应的乐观锁版本
  int _snapshotVersion = 1;
  /// 编辑态 JSON 变更后的局部版本戳，用于强制依赖 planData 的子组件刷新。
  int _contentVersion = 0;

  /// 保存行程时防连点（完成按钮 Loading）
  bool _isSaving = false;

  /// 保存成功后「完成」按钮短暂展示绿色打勾动画
  bool _saveButtonSuccessMark = false;

  Timer? _autoSaveDebounce;

  /// [dispose] 时用于 [clearRemoteUpdateCallback]，避免在 dispose 使用 [context]
  ItineraryProvider? _collaborationProviderRef;

  @override
  void initState() {
    super.initState();
    _mockTimeline = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 1,
        'day': 1,
        'scheduledTime': '07:30',
        'title': '比雷埃夫斯港',
        'openTime': '全天开放',
        'duration': '预计游玩 7.5 小时',
        'tag': '交通枢纽 · 乘船出海',
        'images': <String>[
          'https://images.unsplash.com/photo-1493976040374-85c8e12f0c0e?w=400',
          'https://images.unsplash.com/photo-1517154421773-0529f29ea451?w=400',
        ],
        'strategy': '建议提前半小时到达港口换取纸质船票。',
        'lat': 37.9421,
        'lng': 23.6465,
        'isArrived': false,
        'transit': <String, dynamic>{
          'mode': 'walk',
          'text': '步行约10分钟',
          'distance': '232.2公里',
        },
      },
      <String, dynamic>{
        'id': 2,
        'day': 1,
        'scheduledTime': '15:00',
        'title': '费拉镇漫步',
        'openTime': '全天开放',
        'duration': '预计游玩 3 小时',
        'tag': '绝美日落 · 悬崖小镇',
        'images': <String>[
          'https://images.unsplash.com/photo-1518002171953-a080ee817e1f?w=400',
          'https://images.unsplash.com/photo-1553603227-2368a5eb7774?w=400',
        ],
        'strategy': '沿着悬崖步道走，可以找到很多出片的蓝顶教堂。',
        'lat': 36.4213,
        'lng': 25.4298,
        'isArrived': false,
        'transit': <String, dynamic>{
          'mode': 'car',
          'text': '驾车约26分钟',
          'distance': '18.4公里',
        },
      },
      <String, dynamic>{
        'id': 3,
        'day': 2,
        'scheduledTime': '09:20',
        'title': '伊亚观景台',
        'openTime': '全天开放',
        'duration': '预计游玩 2.5 小时',
        'tag': '蓝顶教堂 · 经典机位',
        'images': <String>[
          'https://images.unsplash.com/photo-1570077188670-e3a8d69ac5ff?w=400',
          'https://images.unsplash.com/photo-1613395877344-13d4a8e0d49e?w=400',
        ],
        'strategy': '建议上午先去高处机位，逆光更柔和，游客也更少。',
        'lat': 36.4618,
        'lng': 25.3753,
        'isArrived': false,
        'transit': <String, dynamic>{
          'mode': 'walk',
          'text': '步行约12分钟',
          'distance': '760米',
        },
      },
      <String, dynamic>{
        'id': 4,
        'day': 2,
        'scheduledTime': '13:30',
        'title': '阿莫迪湾午餐',
        'openTime': '11:00-22:00 开放',
        'duration': '预计游玩 1.5 小时',
        'tag': '海湾餐厅 · 慢节奏休闲',
        'images': <String>[
          'https://images.unsplash.com/photo-1481833761820-0509d3217039?w=400',
          'https://images.unsplash.com/photo-1414235077428-338989a2e8c0?w=400',
        ],
        'strategy': '建议提前线上订位靠海窗边，餐后可沿海港慢行消食。',
        'lat': 36.3932,
        'lng': 25.4615,
        'isArrived': false,
        'transit': null,
      },
    ];
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _initLocation();
    _loadAmapArrowTexture();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerRouteSyncFromProvider();
      _bindCollaborationChannelsOnEnter();
    });
  }

  void _bindCollaborationChannelsOnEnter() {
    if (!mounted) return;
    final ItineraryProvider provider = context.read<ItineraryProvider>();
    final ItineraryModel? model =
        provider.activeItinerary ?? provider.currentItinerary;
    if (model == null) return;
    provider.subscribeToItinerary(model.id);
    provider.joinPresence(model.id);

    _collaborationProviderRef?.clearRemoteUpdateCallback();
    _collaborationProviderRef = provider;
    provider.setRemoteUpdateCallback(() {
      if (!mounted) return;
      if (_isEditing) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔄 协作者刚刚更新了行程'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  /// 防抖自动保存：编辑操作后 800ms 无新操作则静默提交云端
  void _triggerAutoSave() {
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 800), () async {
      if (!_isEditing || _editablePlanData == null || !mounted) return;
      final ItineraryProvider provider = context.read<ItineraryProvider>();
      await provider.updateItineraryDataWithLock(_editablePlanData!);
    });
  }

  void _triggerRouteSyncFromProvider() {
    if (!mounted) return;
    final ItineraryProvider provider = context.read<ItineraryProvider>();
    final ItineraryModel? model =
        provider.activeItinerary ?? provider.currentItinerary;
    if (model == null) {
      debugPrint('🚨 严重警告：当前无行程数据，无法触发 _fetchAllRoutesAndSync');
      return;
    }
    // ignore: unawaited_futures
    _fetchAllRoutesAndSync(model);
  }

  Future<void> _loadAmapArrowTexture() async {
    try {
      // 预热常见天数的纹理缓存；其余天数按需懒加载。
      for (int day = 1; day <= 7; day++) {
        final Uint8List bytes = await _createArrowTextureBytes(Colors.white);
        _amapArrowTextureByDay[day] = amap.BitmapDescriptor.fromBytes(bytes);
      }
      if (mounted) setState(() {});
    } catch (_) {
      _amapArrowTextureByDay.clear();
    }
  }

  Future<void> _ensureArrowTextureForDay(int day) async {
    if (_amapArrowTextureByDay.containsKey(day)) return;
    try {
      final Uint8List bytes = await _createArrowTextureBytes(Colors.white);
      _amapArrowTextureByDay[day] = amap.BitmapDescriptor.fromBytes(bytes);
    } catch (_) {
      // ignore and fallback to color polyline only
    }
  }

  Future<Uint8List> _createArrowTextureBytes(Color tint) async {
    // 若你希望替换成设计稿纹理：
    // 1) 在 assets 放置 arrow_texture.png（透明底）
    // 2) 在 pubspec.yaml 声明后可改为 fromAssetImage 加载
    const double width = 28;
    const double height = 72;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    final Paint arrowPaint = Paint()
      ..color = tint.withValues(alpha: 0.95)
      ..style = PaintingStyle.fill;

    // 高德纹理按 Y 轴向上拉伸，这里明确绘制“朝上(↑)”箭头。
    Path chevron(double y) => Path()
      ..moveTo(14, y)
      ..lineTo(6, y + 10)
      ..lineTo(9, y + 14)
      ..lineTo(14, y + 8)
      ..lineTo(19, y + 14)
      ..lineTo(22, y + 10)
      ..close();
    canvas.drawPath(chevron(8), arrowPaint);
    canvas.drawPath(chevron(34), arrowPaint);
    canvas.drawPath(chevron(60), arrowPaint);

    final ui.Image img = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _collaborationProviderRef?.clearRemoteUpdateCallback();
    _collaborationProviderRef = null;
    _positionSub?.cancel();
    _scrollController.dispose();
    _googleController?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    try {
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final Position current = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _currentPosition = current);
      _positionSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 20,
            ),
          ).listen((Position position) {
            if (!mounted) return;
            setState(() => _currentPosition = position);
          });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ItineraryProvider>(
      builder: (BuildContext context, ItineraryProvider provider, _) {
        final ItineraryProvider itineraryProvider = provider;
        final ItineraryModel? activeTrip =
            itineraryProvider.activeItinerary ?? itineraryProvider.currentItinerary;
        if (activeTrip == null) {
          return Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.map_outlined, size: 64, color: Colors.grey.shade200),
                  const SizedBox(height: 16),
                  const Text(
                    '当前没有选中的行程',
                    style: TextStyle(color: Colors.grey),
                  ),
                  TextButton(
                    onPressed: () =>
                        Provider.of<MainNavProvider>(context, listen: false).setTab(0),
                    child: const Text('去“发现”页选一个吧'),
                  ),
                ],
              ),
            ),
          );
        }
        final ItineraryModel model = activeTrip;

        // 使用用户手动选择的模式，而不是自动计算的 TripState
        final TripMode currentMode = provider.currentMode;
        // 将 TripMode 转换为 TripState 以兼容现有逻辑
        final TripState effectiveState = currentMode == TripMode.planning 
            ? TripState.preparing 
            : TripState.traveling;
        
        final ItineraryModel routeModel =
            (_isEditing && _editablePlanData != null)
                ? ItineraryModel.fromJson(<String, dynamic>{
                    ...model.toJson(),
                    'planData': _editablePlanData,
                  })
                : model;
        final List<_DayRoute> dayRoutes = _buildDayRoutes(routeModel);
        if (_selectedDayIndex > dayRoutes.length) {
          _selectedDayIndex = 0;
        }
        _maybeInitMarkers(model, dayRoutes);

        return Scaffold(
          backgroundColor: Colors.white,
          // 分屏结构：地图固定可见，列表独立滚动，避免跳转时地图被顶出视野。
          body: Column(
            children: <Widget>[
              if (_isEditing)
                _buildImmersiveEditAppBar(provider, model)
              else
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    MediaQuery.of(context).padding.top + 10,
                    16,
                    10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              model.title,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                height: 1.3,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildCollaboratorStack(context),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          _buildMiniModeToggle(context),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              TextButton(
                                onPressed: () => _startEditMode(model),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.indigo.shade700,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                ),
                                child: const Text(
                                  '编辑行程',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                              ),
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _isMapCollapsed = !_isMapCollapsed;
                                  });
                                },
                                borderRadius: BorderRadius.circular(20),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.indigo.shade50,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Colors.indigo.shade100,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Icon(
                                        _isMapCollapsed
                                            ? Icons.map_outlined
                                            : Icons.unfold_less_rounded,
                                        size: 16,
                                        color: Colors.indigo.shade600,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _isMapCollapsed ? '展开地图' : '收起地图',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.indigo.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (!_isEditing)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  height: _isMapCollapsed
                      ? 0.0
                      : MediaQuery.of(context).size.height * 0.3,
                  margin: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: _isMapCollapsed ? 0 : 12,
                  ),
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      height: MediaQuery.of(context).size.height * 0.3,
                      child: _buildMapOnlyWidget(
                        model: model,
                        state: effectiveState,
                        dayRoutes: dayRoutes,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: _buildDayTabBar(
                  model: model,
                  state: effectiveState,
                  dayRoutes: dayRoutes,
                ),
              ),
              Expanded(
                child: NotificationListener<ScrollUpdateNotification>(
                  onNotification: (ScrollUpdateNotification _) {
                    _syncMapWithVisibleTimelineItem();
                    return false;
                  },
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: <Widget>[
                      if (effectiveState == TripState.preparing)
                        ..._buildPreparingSlivers(model, provider, dayRoutes)
                      else
                        ..._buildTravelingSlivers(model, provider, dayRoutes),
                      const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Map<String, dynamic> _clonePlanData(Map<String, dynamic> source) {
    return Map<String, dynamic>.from(
      jsonDecode(jsonEncode(source)) as Map<dynamic, dynamic>,
    );
  }

  /// 编辑态时间线在写入 [_editablePlanData] 后调用，便于集中扩展同步逻辑。
  void _refreshFromEditableData() {}

  String _planDaysStorageKey(Map<String, dynamic> plan) {
    final List? ds = plan['daily_schedules'] as List?;
    final List? d = plan['days'] as List?;
    if (ds != null && ds.isNotEmpty) {
      return 'daily_schedules';
    }
    if (d != null && d.isNotEmpty) {
      return 'days';
    }
    return ds != null ? 'daily_schedules' : 'days';
  }

  /// 行程目的地城市提示词（高德地理编码 city 参数）
  String _destinationCityHint(ItineraryModel? itinerary) {
    if (itinerary == null) {
      return '北京';
    }
    final Map<String, dynamic> pd =
        Map<String, dynamic>.from(itinerary.planData);
    final Object? dest =
        pd['destination'] ??
        pd['city'] ??
        pd['destination_city'] ??
        pd['destinationCity'];
    final String d = dest?.toString().trim() ?? '';
    if (d.isNotEmpty) {
      return d;
    }
    final String title = itinerary.title;
    if (title.contains('上海')) {
      return '上海';
    }
    if (title.contains('北京')) {
      return '北京';
    }
    return '北京';
  }

  bool _coordsNonZero(double? lat, double? lng) {
    if (lat == null || lng == null) {
      return false;
    }
    if (lat == 0 && lng == 0) {
      return false;
    }
    return true;
  }

  /// 高德 Web 地理编码，将景点名纠偏为真实坐标（经度,纬度）供地图/算路使用。
  Future<gmap.LatLng?> _getRealLocation(String title, String city) async {
    return _geocodeKeywordWithAmap(title, city);
  }

  Future<gmap.LatLng?> _geocodeKeywordWithAmap(
    String keyword,
    String city,
  ) async {
    final String k = keyword.trim();
    if (k.isEmpty) {
      return null;
    }
    try {
      final Uri uri = Uri.https('restapi.amap.com', '/v3/geocode/geo', <String, String>{
        'key': AMapConfig.webApiKey,
        'address': k,
        if (city.trim().isNotEmpty) 'city': city.trim(),
      });
      final http.Response res =
          await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        return null;
      }
      final Object? decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      if (decoded['status']?.toString() != '1') {
        return null;
      }
      final List<dynamic>? geocodes =
          decoded['geocodes'] as List<dynamic>?;
      if (geocodes == null || geocodes.isEmpty) {
        return null;
      }
      final Object? rawGeo = geocodes.first;
      if (rawGeo is! Map) {
        return null;
      }
      final String loc =
          Map<String, dynamic>.from(rawGeo)['location']?.toString() ?? '';
      final List<String> parts = loc.split(',');
      if (parts.length < 2) {
        return null;
      }
      final double? lng = double.tryParse(parts[0].trim());
      final double? lat = double.tryParse(parts[1].trim());
      if (lat == null || lng == null) {
        return null;
      }
      return gmap.LatLng(lat, lng);
    } catch (e) {
      debugPrint('地理编码失败: $e');
      return null;
    }
  }

  void _showAiLoadingDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => const Center(
        child: Card(
          color: Colors.white,
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CircularProgressIndicator(color: Colors.indigo),
                SizedBox(height: 16),
                Text(
                  'AI 正在润色…',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.indigo,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _callLlmForPolish(String originalText) async {
    final http.Response response = await http
        .post(
          Uri.parse(AiConfig.deepseekEndpoint),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${AiConfig.deepseekApiKey}',
          },
          body: jsonEncode(<String, dynamic>{
            'model': AiConfig.deepseekModel,
            'messages': <Map<String, String>>[
              <String, String>{
                'role': 'user',
                'content':
                    '我正在写手账，请帮我把这段旅行日记润色得更有电影感：$originalText\n'
                    '直接返回润色后的文字，不要引号、前言或 Markdown。',
              },
            ],
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic> body =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final String? content =
        (body['choices'] as List<dynamic>?)?.first['message']?['content']
            ?.toString();
    return content?.trim();
  }

  Future<void> _polishNodeDescription(
    int dIdx,
    int aIdx,
    Map<String, dynamic> item,
  ) async {
    if (_editablePlanData == null) {
      return;
    }
    final String title = (item['title'] ?? '未知景点').toString();
    final String originalDesc = (item['description'] ?? '').toString();
    final String existingTime = (item['time'] ?? '').toString().trim();
    final String systemPrompt = '''
你是一个顶级的私人旅行管家。用户刚刚在行程中手动添加了一个新节点：【$title】。
请你发挥专业知识，帮用户把这个节点的信息补全，使其看起来专业详尽。

【原稿参考】：$originalDesc
【当前安排时间】：${existingTime.isNotEmpty ? existingTime : '未设置'}

【绝对红线】：必须且只能返回一个合法的 JSON 对象，不包含任何 Markdown 标记 (如 ```json)！
JSON 必须严格包含以下 5 个字段：
{
  "time": "建议的游览开始时间，格式 HH:mm（如：09:30）。若原时间已合理则原样返回；若为空则根据景点信息和整体行程的时间规划给出合理建议时间安排",
  "openTime": "景点的真实开放时间 (如：09:00-18:00 开放 或 全天开放)",
  "recommended_duration": "建议游玩时长 (如：预计游玩 1.5小时)",
  "tag": "提炼精准的标签 (如：地标 · 必打卡)",
  "description": "用专业的旅游管家口吻撰写简短精要且全面细节的游玩攻略或避坑指南，"
}
''';
    _showAiLoadingDialog();
    try {
      final http.Response response = await http
          .post(
            Uri.parse(AiConfig.deepseekEndpoint),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${AiConfig.deepseekApiKey}',
            },
            body: jsonEncode(<String, dynamic>{
              'model': AiConfig.deepseekModel,
              'messages': <Map<String, String>>[
                <String, String>{'role': 'system', 'content': systemPrompt},
                <String, String>{'role': 'user', 'content': '请只返回 JSON。'},
              ],
            }),
          )
          .timeout(const Duration(seconds: 45));
      if (!mounted) {
        return;
      }
      Navigator.of(context, rootNavigator: true).pop();
      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('润色失败，请稍后重试')),
        );
        return;
      }
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      String content =
          ((data['choices'] as List<dynamic>?)?.first['message']?['content'] ??
                  '')
              .toString()
              .trim();
      if (content.contains('```json')) {
        content = content.split('```json')[1].split('```')[0].trim();
      } else if (content.contains('```')) {
        content = content.split('```')[1].split('```')[0].trim();
      }
      if (content.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI 返回为空，请稍后重试')),
        );
        return;
      }
      final Map<String, dynamic> aiResult =
          jsonDecode(content) as Map<String, dynamic>;

      setState(() {
        final String storageKey = _planDaysStorageKey(_editablePlanData!);
        final List<dynamic> days = List<dynamic>.from(
          (_editablePlanData![storageKey] as List<dynamic>?) ??
              <dynamic>[],
        );
        if (dIdx < 0 || dIdx >= days.length) {
          return;
        }
        final Map<String, dynamic> dayMap =
            Map<String, dynamic>.from(days[dIdx] as Map);
        final List<dynamic> acts = List<dynamic>.from(
          (dayMap['activities'] as List<dynamic>?) ?? <dynamic>[],
        );
        if (aIdx < 0 || aIdx >= acts.length) {
          return;
        }
        final Map<String, dynamic> activity =
            Map<String, dynamic>.from(acts[aIdx] as Map);
        final String aiTime = (aiResult['time'] ?? '').toString().trim();
        final String openTime = (aiResult['openTime'] ?? '').toString().trim();
        final String recommendedDuration =
            (aiResult['recommended_duration'] ?? '').toString().trim();
        final String tag = (aiResult['tag'] ?? '').toString().trim();
        final String description =
            (aiResult['description'] ?? '').toString().trim();
        
        // 新增：回写 AI 建议的时间（仅当 AI 返回了合法时间时）
        final RegExp hhMmStrict = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
        if (aiTime.isNotEmpty && hhMmStrict.hasMatch(aiTime)) {
          activity['time'] = aiTime;
        }
        
        activity['openTime'] = openTime;
        activity['recommended_duration'] = recommendedDuration;
        activity['duration'] = recommendedDuration;
        activity['tag'] = tag;
        activity['description'] = description;
        activity['is_polished'] = true;
        activity['type'] = 'scenic';
        acts[aIdx] = activity;
        dayMap['activities'] = acts;
        days[dIdx] = dayMap;
        _editablePlanData![storageKey] = days;
        
        // 同步更新 item
        if (aiTime.isNotEmpty && hhMmStrict.hasMatch(aiTime)) {
          item['time'] = aiTime;
        }
        
        item['openTime'] = openTime;
        item['recommended_duration'] = recommendedDuration;
        item['duration'] = recommendedDuration;
        item['tag'] = tag;
        item['description'] = description;
        item['is_polished'] = true;
        item['type'] = 'scenic';
        _refreshFromEditableData();
        _contentVersion++;
      });
      _triggerAutoSave();
      // AI 补全后重新排序，确保时间轴顺序正确
      _sortDayActivities(dIdx);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✨ 行程卡片已智能补全！')),
        );
      }
    } catch (e) {
      debugPrint('AI润色失败: $e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('润色失败: $e')),
        );
      }
    }
  }

  Future<void> _persistActivityNoteInPlan(
    ItineraryModel base,
    int dayIdx,
    int activityIdx,
    String note,
  ) async {
    final ItineraryProvider provider =
        Provider.of<ItineraryProvider>(context, listen: false);
    final ItineraryModel fresh =
        provider.activeItinerary ?? provider.currentItinerary ?? base;
    final Map<String, dynamic> planData =
        Map<String, dynamic>.from(fresh.planData);
    final String sk = _planDaysStorageKey(planData);
    final List<dynamic> days =
        List<dynamic>.from((planData[sk] as List<dynamic>?) ?? <dynamic>[]);
    if (dayIdx < 0 || dayIdx >= days.length) {
      return;
    }
    final Map<String, dynamic> dm =
        Map<String, dynamic>.from(days[dayIdx] as Map);
    final List<dynamic> acts = List<dynamic>.from(
      (dm['activities'] as List<dynamic>?) ?? <dynamic>[],
    );
    if (activityIdx < 0 || activityIdx >= acts.length) {
      return;
    }
    final Map<String, dynamic> act =
        Map<String, dynamic>.from(acts[activityIdx] as Map);
    act['description'] = note;
    act['note'] = note;
    acts[activityIdx] = act;
    dm['activities'] = acts;
    days[dayIdx] = dm;
    planData[sk] = days;
    await provider.updateItineraryData(planData);
    if (!mounted) {
      return;
    }
    setState(() {
      _contentVersion++;
    });
  }

  Future<void> _showTravelNoteBottomSheet(
    Map<String, dynamic> item,
    ItineraryModel itineraryModel,
  ) async {
    final TextEditingController noteCtrl = TextEditingController(
      text: (item['note'] ?? item['description'] ?? '').toString(),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        final Size size = MediaQuery.of(ctx).size;
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * 0.85),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '📝 添加随行备注',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: TextField(
                          controller: noteCtrl,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: '记录一下当下的感受，或记录避坑指南...',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () async {
                        FocusManager.instance.primaryFocus?.unfocus();
                        final String trimmed = noteCtrl.text.trim();
                        final int dIdx =
                            (item['dayIndex'] as num?)?.toInt() ?? 0;
                        final int aIdx =
                            (item['activityIndex'] as num?)?.toInt() ?? 0;
                        await _persistActivityNoteInPlan(
                          itineraryModel,
                          dIdx,
                          aIdx,
                          trimmed,
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('✅ 备注已保存'),
                            ),
                          );
                        }
                      },
                      child: const Text(
                        '保存记录',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _startEditMode(ItineraryModel model) {
    setState(() {
      _isEditing = true;
      _editablePlanData = _clonePlanData(model.planData);
      _planDataSnapshot = _clonePlanData(model.planData);
      _snapshotVersion = model.version;
    });
    final ItineraryProvider provider = Provider.of<ItineraryProvider>(
      context,
      listen: false,
    );
    provider.updatePresenceStatus('editing');
  }

  void _showCollaboratorList(BuildContext context) {
    final ItineraryProvider provider = Provider.of<ItineraryProvider>(
      context,
      listen: false,
    );
    final ItineraryModel? active =
        provider.activeItinerary ?? provider.currentItinerary;
    final List<Map<String, dynamic>> members = provider.onlineUsers.isNotEmpty
        ? provider.onlineUsers
        : <Map<String, dynamic>>[
            <String, dynamic>{
              'nickname': '我 (Owner)',
              'avatar': 'https://api.dicebear.com/7.x/avataaars/png?seed=me',
            },
          ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '协作同伴',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 20),
            ...members.map((Map<String, dynamic> m) {
              final String nickname =
                  (m['nickname'] ?? '匿名伙伴').toString().trim().isNotEmpty
                  ? (m['nickname'] ?? '匿名伙伴').toString()
                  : '匿名伙伴';
              final String avatar = (m['avatar'] ?? '').toString().trim();
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: Colors.grey.shade200,
                  backgroundImage: avatar.isNotEmpty
                      ? NetworkImage(avatar)
                      : const NetworkImage(
                          'https://api.dicebear.com/7.x/avataaars/png?seed=unknown',
                        ),
                ),
                title: Text(
                  nickname,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                trailing: Text(
                  nickname.contains('我') ? '房主' : '编辑者',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                ),
              );
            }),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Divider(),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                if (active != null) {
                  provider.copyItineraryCommand(active.id, active.title);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🗝️ 协作口令已复制！去微信粘贴给好友吧~'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('复制口令邀请好友'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildCollaboratorStack(BuildContext context) {
    final ItineraryProvider provider = Provider.of<ItineraryProvider>(context);
    final List<String> avatars = provider.onlineUsers
        .map((Map<String, dynamic> e) => (e['avatar'] ?? '').toString().trim())
        .where((String e) => e.isNotEmpty)
        .toList(growable: false);
    final String firstAvatar = avatars.isNotEmpty
        ? avatars.first
        : 'https://api.dicebear.com/7.x/avataaars/png?seed=me';
    final String? secondAvatar = avatars.length > 1 ? avatars[1] : null;
    final int extraCount = avatars.length > 2 ? avatars.length - 2 : 0;

    return GestureDetector(
      onTap: () => _showCollaboratorList(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey.shade100),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: extraCount > 0 ? 54 : 44,
              height: 24,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    left: 0,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage: NetworkImage(firstAvatar),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: secondAvatar != null
                          ? CircleAvatar(
                              radius: 10,
                              backgroundColor: Colors.grey.shade200,
                              backgroundImage: NetworkImage(secondAvatar),
                            )
                          : CircleAvatar(
                              radius: 10,
                              backgroundColor: Colors.indigo.shade100,
                              child: Icon(
                                Icons.people_alt_rounded,
                                size: 10,
                                color: Colors.indigo.shade400,
                              ),
                            ),
                    ),
                  ),
                  if (extraCount > 0)
                    Positioned(
                      left: 30,
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.indigo,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Text(
                          '+$extraCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: Colors.grey,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImmersiveEditAppBar(
    ItineraryProvider provider,
    ItineraryModel model,
  ) {
    final double top = MediaQuery.of(context).padding.top;
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      elevation: 0,
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, top + 6, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 80,
              child: TextButton(
                onPressed: _isSaving
                    ? null
                    : () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  _autoSaveDebounce?.cancel();

                  final bool someoneElseEditing =
                      provider.someoneElseEditingName != null;
                  if (someoneElseEditing) {
                    setState(() {
                      _isEditing = false;
                      _editablePlanData = null;
                      _planDataSnapshot = null;
                    });
                    provider.updatePresenceStatus('viewing');
                    return;
                  }

                  if (_planDataSnapshot != null) {
                    await provider.rollbackItineraryData(
                      _planDataSnapshot!,
                      _snapshotVersion,
                    );
                  }

                  setState(() {
                    _isEditing = false;
                    _editablePlanData = null;
                    _planDataSnapshot = null;
                  });
                  provider.updatePresenceStatus('viewing');
                },
                child: Text(
                  '取消',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '编辑行程',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  Text(
                    '拖拽可排序',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.indigo.shade600,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () {
                final ItineraryProvider provider =
                    Provider.of<ItineraryProvider>(context, listen: false);
                final ItineraryModel? active =
                    provider.activeItinerary ?? provider.currentItinerary;
                if (active != null) {
                  provider.copyItineraryCommand(active.id, active.title);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🗝️ 协作口令已复制！去微信粘贴给好友吧~'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade50,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_add_alt_1_rounded,
                  size: 18,
                  color: Colors.indigo,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ElevatedButton(
                onPressed: (_isSaving || _saveButtonSuccessMark)
                    ? null
                    : () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  final ItineraryProvider provider =
                      Provider.of<ItineraryProvider>(context, listen: false);
                  if (_editablePlanData == null) {
                    return;
                  }
                  setState(() {
                    _isSaving = true;
                    _saveButtonSuccessMark = false;
                  });
                  try {
                    final bool success = await provider
                        .updateItineraryDataWithLock(_editablePlanData!);
                    if (!mounted) {
                      return;
                    }
                    if (!success) {
                      setState(() {
                        _isSaving = false;
                        _saveButtonSuccessMark = false;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            '🔄 行程已更新为最新版本，请再次点击"完成"保存你的修改',
                          ),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 4),
                        ),
                      );
                      return;
                    }

                    setState(() {
                      _isSaving = false;
                      _saveButtonSuccessMark = true;
                    });
                    
                    // 显示成功动画后立即退出
                    await Future<void>.delayed(const Duration(milliseconds: 600));
                    if (!mounted) {
                      return;
                    }
                    
                    // 🚀 性能优化：移除完成按钮时的路线同步，避免阻塞界面
                    // 路线数据会在查看行程时按需加载，无需在保存时同步
                    setState(() {
                      _isEditing = false;
                      _editablePlanData = null;
                      _planDataSnapshot = null;
                      _isSaving = false;
                      _saveButtonSuccessMark = false;
                    });
                    provider.updatePresenceStatus('viewing');
                  } catch (_) {
                    if (mounted) {
                      setState(() {
                        _isSaving = false;
                        _saveButtonSuccessMark = false;
                      });
                    }
                  }
                },
                style: ButtonStyle(
                  elevation: const WidgetStatePropertyAll<double>(0),
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  ),
                  shape: const WidgetStatePropertyAll<OutlinedBorder>(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                    ),
                  ),
                  backgroundColor:
                      WidgetStateProperty.resolveWith((Set<WidgetState> states) {
                    if (_saveButtonSuccessMark) {
                      return Colors.white;
                    }
                    return Colors.indigo;
                  }),
                  foregroundColor:
                      WidgetStateProperty.resolveWith((Set<WidgetState> states) {
                    if (_saveButtonSuccessMark) {
                      return const Color(0xFF66BB6A);
                    }
                    return Colors.white;
                  }),
                  overlayColor: WidgetStateProperty.resolveWith(
                    (Set<WidgetState> states) {
                      if (_saveButtonSuccessMark) {
                        return Colors.grey.withValues(alpha: 0.08);
                      }
                      return Colors.white.withValues(alpha: 0.12);
                    },
                  ),
                ),
                child: _saveButtonSuccessMark
                    ? TweenAnimationBuilder<double>(
                        key: const ValueKey<String>('save_success_check'),
                        tween: Tween<double>(begin: 0, end: 1),
                        duration: const Duration(milliseconds: 420),
                        curve: Curves.elasticOut,
                        builder: (
                          BuildContext context,
                          double scale,
                          Widget? child,
                        ) {
                          return Transform.scale(scale: scale, child: child);
                        },
                        child: const Icon(
                          Icons.check_rounded,
                          color: Color(0xFF66BB6A),
                          size: 26,
                          semanticLabel: '已保存',
                        ),
                      )
                    : _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          )
                        : const Text(
                            '完成',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 按照时间动态排序当天的行程点（有效时间优先，待定时间沉底）
  void _sortDayActivities(int dayIndex) {
    if (_editablePlanData == null) {
      return;
    }
    final String storageKey = _planDaysStorageKey(_editablePlanData!);
    final List<dynamic> days =
        List<dynamic>.from((_editablePlanData![storageKey] as List<dynamic>?) ?? <dynamic>[]);
    if (dayIndex < 0 || dayIndex >= days.length) {
      return;
    }
    final Map<String, dynamic> dm = Map<String, dynamic>.from(days[dayIndex] as Map);
    final List<dynamic> activities =
        List<dynamic>.from((dm['activities'] as List<dynamic>?) ?? <dynamic>[]);
    activities.sort((dynamic a, dynamic b) {
      final String tA = (a is Map ? a['time'] : '')?.toString() ?? '';
      final String tB = (b is Map ? b['time'] : '')?.toString() ?? '';
      final bool validA =
          RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$').hasMatch(tA);
      final bool validB =
          RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$').hasMatch(tB);
      if (validA && validB) {
        return tA.compareTo(tB);
      }
      if (validA && !validB) {
        return -1;
      }
      if (!validA && validB) {
        return 1;
      }
      return 0;
    });
    setState(() {
      dm['activities'] = activities;
      days[dayIndex] = dm;
      _editablePlanData![storageKey] = days;
      _contentVersion++;
    });
    _triggerAutoSave();
  }

  List<Widget> _buildEditingReorderSlivers() {
    if (_editablePlanData == null) {
      return <Widget>[];
    }
    final String storageKey = _planDaysStorageKey(_editablePlanData!);
    List<dynamic> daysRaw =
        (_editablePlanData![storageKey] as List<dynamic>?) ?? <dynamic>[];
    if (daysRaw.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                '暂无日程结构，请先保存行程后再编辑。',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          ),
        ),
      ];
    }

    final int maxDay = daysRaw.length;
    final int sel = _selectedDayIndex > maxDay ? 0 : _selectedDayIndex;
    final List<int> dayIndices = sel == 0
        ? List<int>.generate(maxDay, (int i) => i)
        : <int>[sel - 1].where((int i) => i >= 0 && i < maxDay).toList();

    final List<Widget> out = <Widget>[];
    bool firstHeader = true;
    for (final int dayIndex in dayIndices) {
      final Map<String, dynamic> dayMap =
          Map<String, dynamic>.from(daysRaw[dayIndex] as Map);
      final List<dynamic> activities =
          List<dynamic>.from((dayMap['activities'] as List<dynamic>?) ?? <dynamic>[]);

      out.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildEditableDayHeader(
              dayMap,
              dayIndex,
              isFirst: firstHeader,
            ),
          ),
        ),
      );
      firstHeader = false;

      out.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: activities.isEmpty
                ? _buildInsertDivider(dayIndex, -1, storageKey)
                : ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: activities.length,
                    onReorder: (int oldIndex, int newIndex) {
                      if (!_isEditing) {
                        return;
                      }
                      setState(() {
                        int ni = newIndex;
                        if (ni > oldIndex) {
                          ni -= 1;
                        }
                        final List<dynamic> dr =
                            (_editablePlanData![storageKey] as List<dynamic>?) ??
                            <dynamic>[];
                        final Map<String, dynamic> dm =
                            Map<String, dynamic>.from(dr[dayIndex] as Map);
                        final List<dynamic> acts = List<dynamic>.from(
                          (dm['activities'] as List<dynamic>?) ?? <dynamic>[],
                        );
                        final dynamic moved = acts.removeAt(oldIndex);
                        acts.insert(ni, moved);
                        dm['activities'] = acts;
                        dr[dayIndex] = dm;
                        _editablePlanData![storageKey] = dr;
                      });
                      _triggerAutoSave();
                    },
                    itemBuilder: (BuildContext context, int index) {
                      final Map<String, dynamic> activity =
                          Map<String, dynamic>.from(activities[index] as Map);
                      final String stableKey =
                          '${activity['id'] ?? 'act'}_${dayIndex}_$index';
                      return Container(
                        key: ValueKey<String>(stableKey),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _buildEditableActivityNode(
                              activity,
                              dayIndex,
                              index,
                              index,
                            ),
                            _buildInsertDivider(dayIndex, index, storageKey),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      );
    }
    out.add(
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _buildAddDayButton(),
        ),
      ),
    );
    return out;
  }

  void _insertEditableActivity(
    int dayIndex,
    int afterIndex,
    String storageKey, {
    String title = '新行程点',
    String time = '',
    String type = 'custom',
    String description = '',
    double lat = 0,
    double lng = 0,
  }) {
    if (_editablePlanData == null) {
      return;
    }

    // ── 智能推算插入位置的默认时间 ──────────────────────────────────
    String resolvedTime = time.trim();
    if (resolvedTime.isEmpty) {
      final List<dynamic> days =
          (_editablePlanData![storageKey] as List<dynamic>?) ?? <dynamic>[];
      if (dayIndex < days.length) {
        final Map<String, dynamic> dm =
            Map<String, dynamic>.from(days[dayIndex] as Map);
        final List<dynamic> acts = List<dynamic>.from(
          (dm['activities'] as List<dynamic>?) ?? <dynamic>[],
        );
        final RegExp hhMm = RegExp(r'^([01]?[0-9]|2[0-3]):([0-5][0-9])$');
        int? prevMinutes;
        int? nextMinutes;

        // 前驱：afterIndex 及之前，找最近一个有效时间
        for (int i = afterIndex; i >= 0; i--) {
          final String t =
              (acts[i] is Map ? (acts[i] as Map)['time'] : '')?.toString().trim() ?? '';
          final Match? m = hhMm.firstMatch(t);
          if (m != null) {
            prevMinutes = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
            break;
          }
        }
        // 后继：afterIndex+1 及之后，找最近一个有效时间
        for (int i = afterIndex + 1; i < acts.length; i++) {
          final String t =
              (acts[i] is Map ? (acts[i] as Map)['time'] : '')?.toString().trim() ?? '';
          final Match? m = hhMm.firstMatch(t);
          if (m != null) {
            nextMinutes = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
            break;
          }
        }

        int? targetMinutes;
        if (prevMinutes != null && nextMinutes != null) {
          // 前后都有时间：取中间值
          targetMinutes = ((prevMinutes + nextMinutes) / 2).round();
        } else if (prevMinutes != null) {
          // 只有前驱：+60 分钟
          targetMinutes = (prevMinutes + 60).clamp(0, 23 * 60 + 59);
        } else if (nextMinutes != null) {
          // 只有后继：-60 分钟
          targetMinutes = (nextMinutes - 60).clamp(0, 23 * 60 + 59);
        }
        // 前后均无有效时间则保持空字符串，显示"时间待定"

        if (targetMinutes != null) {
          final int h = targetMinutes ~/ 60;
          final int min = targetMinutes % 60;
          resolvedTime =
              '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
        }
      }
    }
    // ────────────────────────────────────────────────────────────────

    setState(() {
      final List<dynamic> days =
          (_editablePlanData![storageKey] as List<dynamic>?) ?? <dynamic>[];
      if (dayIndex >= days.length) {
        return;
      }
      final Map<String, dynamic> dm =
          Map<String, dynamic>.from(days[dayIndex] as Map);
      final List<dynamic> acts = List<dynamic>.from(
        (dm['activities'] as List<dynamic>?) ?? <dynamic>[],
      );
      final String newId =
          'edit_${DateTime.now().millisecondsSinceEpoch}_${acts.length}';
      final int insertAt = (afterIndex + 1).clamp(0, acts.length);
      acts.insert(
        insertAt,
        <String, dynamic>{
          'id': newId,
          'title': title,
          'time': resolvedTime,          // ← 使用推算后的时间
          'type': type,
          'tag': '自定义添加',
          'recommended_duration': '时长待定',
          'description': description.isEmpty ? '新增景点待补充描述...' : description,
          'is_polished': false,
          'is_user_added': true,
          'lat': lat == 0 ? 0.0 : lat,
          'lng': lng == 0 ? 0.0 : lng,
          'isArrived': false,
          'imageUrl': '',
        },
      );
      dm['activities'] = acts;
      days[dayIndex] = dm;
      _editablePlanData![storageKey] = days;
      _contentVersion++;
    });
    _sortDayActivities(dayIndex);
    _triggerAutoSave();
  }

  Future<void> _deleteActivity(int dayIndex, int activityIndex) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text(
          '删除行程点',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text('确定要删除这个行程点吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '删除',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || _editablePlanData == null) {
      return;
    }
    final String storageKey = _planDaysStorageKey(_editablePlanData!);
    setState(() {
      final List<dynamic> days =
          (_editablePlanData![storageKey] as List<dynamic>?) ?? <dynamic>[];
      if (dayIndex >= days.length) {
        return;
      }
      final Map<String, dynamic> dm =
          Map<String, dynamic>.from(days[dayIndex] as Map);
      final List<dynamic> acts = List<dynamic>.from(
        (dm['activities'] as List<dynamic>?) ?? <dynamic>[],
      );
      if (activityIndex >= 0 && activityIndex < acts.length) {
        acts.removeAt(activityIndex);
      }
      if (acts.isEmpty) {
        days.removeAt(dayIndex);
      } else {
        dm['activities'] = acts;
        days[dayIndex] = dm;
      }
      _editablePlanData![storageKey] = days;
    });
    _triggerAutoSave();
  }

  Future<void> _deleteWholeDay(int dayIndex) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text(
          '删除整天行程',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: const Text('确定删除这一天的所有行程点吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '删除',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || _editablePlanData == null) {
      return;
    }
    setState(() {
      final String storageKey = _planDaysStorageKey(_editablePlanData!);
      final List<dynamic> days =
          List<dynamic>.from(
            (_editablePlanData![storageKey] as List<dynamic>?) ??
                <dynamic>[],
          );
      if (dayIndex >= 0 && dayIndex < days.length) {
        days.removeAt(dayIndex);
        _editablePlanData![storageKey] = days;
      }
    });
    _triggerAutoSave();
  }

  void _addNewDay() {
    if (_editablePlanData == null) {
      return;
    }
    setState(() {
      final String storageKey = _planDaysStorageKey(_editablePlanData!);
      final List<dynamic> days = List<dynamic>.from(
        (_editablePlanData![storageKey] as List<dynamic>?) ?? <dynamic>[],
      );
      days.add(<String, dynamic>{
        'dayTitle': '新的一天',
        'summary': '继续探索未知的风景...',
        'theme_color': '#4F46E5',
        'activities': <dynamic>[],
      });
      _editablePlanData![storageKey] = days;
    });
    _triggerAutoSave();
  }

  Future<void> _openInsertActivitySheet(
    int dayIndex,
    int afterActivityIndex,
    String storageKey,
  ) async {
    final ItineraryProvider p = context.read<ItineraryProvider>();
    final ItineraryModel? m = p.activeItinerary ?? p.currentItinerary;
    final String city = _destinationCityHint(m);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) => _InsertNodeBottomSheet(
        geocodeCity: city,
        resolveLocation: _getRealLocation,
        onConfirm: (String title, String time, double lat, double lng) {
          _insertEditableActivity(
            dayIndex,
            afterActivityIndex,
            storageKey,
            title: title,
            time: time,
            type: 'custom',
            description: '新增景点待补充描述...',
            lat: lat,
            lng: lng,
          );
        },
      ),
    );
  }

  Widget _buildEditableActivityNode(
    Map<String, dynamic> item,
    int dIdx,
    int aIdx,
    int reorderIndex,
  ) {
    final String titleStr = item['title']?.toString() ?? '';
    final String currentDesc = (item['description'] ?? '').toString().trim();
    final bool isPolished = item['is_polished'] == true;
    // 只有用户手动新增（is_user_added=true）且尚未润色的节点才需要 AI 补全。
    // AI 大模型规划好的景点不带 is_user_added 标志，不应显示补全入口。
    final bool isAiNode = !isPolished && (item['is_user_added'] == true);
    final Color borderColor =
        isAiNode ? Colors.amber.shade400 : Colors.indigo.shade50;
    final Color shadowColor =
        isAiNode
        ? Colors.amber.withOpacity(0.15)
        : Colors.black.withOpacity(0.03);
    final String timeDisplay =
        (item['time']?.toString() ?? '').trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: borderColor,
          width: isAiNode ? 1.5 : 1.0,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: shadowColor,
            blurRadius: 15,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          InkWell(
            onTap: () {
              // ignore: discarded_futures
              _deleteActivity(dIdx, aIdx);
            },
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Icon(
                Icons.remove_circle,
                color: Colors.red.shade300,
                size: 22,
              ),
            ),
          ),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  final TextEditingController editTitleCtrl =
                      TextEditingController(text: item['title'] ?? '');
                  final TextEditingController editTimeCtrl =
                      TextEditingController(text: item['time'] ?? '');
                  final String currentDuration = (item['recommended_duration'] ??
                          '')
                      .toString()
                      .replaceAll('游玩 ', '')
                      .replaceAll('预计游玩 ', '');
                  final TextEditingController editDurationCtrl =
                      TextEditingController(text: currentDuration);
                  showDialog<void>(
                    context: context,
                    builder: (BuildContext ctx) => StatefulBuilder(
                      builder: (
                        BuildContext dialogContext,
                        void Function(void Function()) setDialogState,
                      ) {
                        return AlertDialog(
                          title: const Text(
                            '修改行程信息',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          content: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                TextField(
                                  controller: editTitleCtrl,
                                  decoration: const InputDecoration(
                                    labelText: '地点/活动名称',
                                  ),
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: editDurationCtrl,
                                  decoration: const InputDecoration(
                                    labelText: '游玩时长 (选填)',
                                    hintText: '如：2小时 / 半天',
                                  ),
                                ),
                                const SizedBox(height: 16),
                                GestureDetector(
                                  onTap: () {
                                    FocusScope.of(dialogContext).unfocus();
                                    DateTime tempTime = DateTime(2026, 1, 1, 9, 0);
                                    if (editTimeCtrl.text.isNotEmpty) {
                                      try {
                                        final List<String> parts =
                                            editTimeCtrl.text.split(':');
                                        tempTime = DateTime(
                                          2026,
                                          1,
                                          1,
                                          int.parse(parts[0]),
                                          int.parse(parts[1]),
                                        );
                                      } catch (_) {}
                                    }
                                    showCupertinoModalPopup<void>(
                                      context: dialogContext,
                                      builder: (_) => Container(
                                        height: 260,
                                        color: Colors.white,
                                        child: Column(
                                          children: <Widget>[
                                            Container(
                                              color: Colors.grey.shade50,
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: <Widget>[
                                                  TextButton(
                                                    onPressed: () {
                                                      setDialogState(() {
                                                        editTimeCtrl.clear();
                                                      });
                                                      Navigator.pop(dialogContext);
                                                    },
                                                    child: const Text(
                                                      '清除',
                                                      style: TextStyle(
                                                        color: Colors.grey,
                                                      ),
                                                    ),
                                                  ),
                                                  TextButton(
                                                    onPressed: () {
                                                      setDialogState(() {
                                                        editTimeCtrl.text =
                                                            '${tempTime.hour.toString().padLeft(2, '0')}:${tempTime.minute.toString().padLeft(2, '0')}';
                                                      });
                                                      Navigator.pop(dialogContext);
                                                    },
                                                    child: const Text(
                                                      '确定',
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Expanded(
                                              child: CupertinoDatePicker(
                                                mode:
                                                    CupertinoDatePickerMode.time,
                                                use24hFormat: true,
                                                initialDateTime: tempTime,
                                                onDateTimeChanged:
                                                    (DateTime newDate) {
                                                      tempTime = newDate;
                                                    },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                  child: AbsorbPointer(
                                    child: TextField(
                                      controller: editTimeCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '大概时间 (选填)',
                                        hintText: '点击滑动选择',
                                        suffixIcon: Icon(
                                          Icons.access_time,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text(
                                '取消',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                              ),
                              onPressed: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                if (_editablePlanData == null) {
                                  return;
                                }
                                final String storageKey =
                                    _planDaysStorageKey(_editablePlanData!);
                                setState(() {
                                  final List<dynamic> days = List<dynamic>.from(
                                    (_editablePlanData![storageKey]
                                            as List<dynamic>?) ??
                                        <dynamic>[],
                                  );
                                  if (dIdx >= 0 && dIdx < days.length) {
                                    final Map<String, dynamic> dm =
                                        Map<String, dynamic>.from(
                                      days[dIdx] as Map,
                                    );
                                    final List<dynamic> acts =
                                        List<dynamic>.from(
                                      (dm['activities'] as List<dynamic>?) ??
                                          <dynamic>[],
                                    );
                                    if (aIdx >= 0 && aIdx < acts.length) {
                                      final Map<String, dynamic> act =
                                          Map<String, dynamic>.from(
                                        acts[aIdx] as Map,
                                      );
                                      final String newDuration =
                                          editDurationCtrl.text.trim();
                                      act['title'] = editTitleCtrl.text.trim();
                                      act['time'] = editTimeCtrl.text.trim();
                                      act['recommended_duration'] =
                                          newDuration.isNotEmpty
                                          ? newDuration
                                          : '时长待定';
                                      act['duration'] = act['recommended_duration'];
                                      acts[aIdx] = act;
                                      dm['activities'] = acts;
                                      days[dIdx] = dm;
                                      _editablePlanData![storageKey] = days;
                                      item['title'] = act['title'];
                                      item['time'] = act['time'];
                                      item['recommended_duration'] =
                                          act['recommended_duration'];
                                      item['duration'] = act['duration'];
                                      _refreshFromEditableData();
                                      _contentVersion++;
                                    }
                                  }
                                });
                                _sortDayActivities(dIdx);
                                Navigator.pop(ctx);
                                _triggerAutoSave();
                              },
                              child: const Text(
                                '保存',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        timeDisplay.isNotEmpty ? timeDisplay : '时间待定',
                        style: TextStyle(
                          color: isAiNode
                              ? Colors.amber.shade600
                              : Colors.indigo.shade600,
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isAiNode)
                        GestureDetector(
                          onTap: () {
                            // ignore: discarded_futures
                            _polishNodeDescription(dIdx, aIdx, item);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.amber.shade300),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: Colors.amber.withOpacity(0.2),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.auto_awesome,
                                  size: 12,
                                  color: Colors.amber.shade700,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '点击 AI 补全',
                                  style: TextStyle(
                                    color: Colors.amber.shade700,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '游玩 ${item['recommended_duration'] ?? '2h'}',
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    titleStr.isNotEmpty ? titleStr : '未命名景点',
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: reorderIndex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Icon(
                Icons.drag_handle_rounded,
                color: Colors.grey.shade300,
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsertDivider(int dIdx, int aIdx, String storageKey) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GestureDetector(
        onTap: () {
          // ignore: discarded_futures
          _openInsertActivitySheet(dIdx, aIdx, storageKey);
        },
        child: Row(
          children: <Widget>[
            Expanded(child: _buildDashedLine()),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.indigo.shade100),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add, size: 12, color: Colors.indigo.shade600),
                  const SizedBox(width: 4),
                  Text(
                    '插入新行程点',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.indigo.shade600,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildDashedLine()),
          ],
        ),
      ),
    );
  }

  Widget _buildDashedLine() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double boxWidth = constraints.constrainWidth();
        const double dashWidth = 4.0;
        const double dashHeight = 1.5;
        final int dashCount = (boxWidth / (2 * dashWidth)).floor().clamp(1, 400);
        return Flex(
          direction: Axis.horizontal,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List<Widget>.generate(dashCount, (_) {
            return const SizedBox(
              width: dashWidth,
              height: dashHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Color(0xFFC7D2FE)),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildEditableDayHeader(
    Map<String, dynamic> dayData,
    int dIdx, {
    bool isFirst = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 8 : 24, bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.indigo.shade600,
              borderRadius: BorderRadius.circular(20),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.indigo.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'DAY ${dIdx + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              dayData['dayTitle']?.toString() ??
                  dayData['day_title']?.toString() ??
                  '行程安排',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: () {
              // ignore: discarded_futures
              _deleteWholeDay(dIdx);
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.delete_outline,
                size: 14,
                color: Colors.red.shade300,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddDayButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: GestureDetector(
        onTap: _addNewDay,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.indigo.shade200,
              width: 1.5,
              style: BorderStyle.solid,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.indigo.withValues(alpha: 0.02),
                blurRadius: 10,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.calendar_month, color: Colors.indigo.shade500, size: 18),
              const SizedBox(width: 8),
              Text(
                '添加新的一天',
                style: TextStyle(
                  color: Colors.indigo.shade600,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapOnlyWidget({
    required ItineraryModel model,
    required TripState state,
    required List<_DayRoute> dayRoutes,
  }) {
    final List<ActivityItem> allActivities = dayRoutes
        .expand((_DayRoute route) => route.activities)
        .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
        .toList(growable: false);
    final ActivityItem? next = _nextPendingActivity(model);
    return _isMapLoading
        ? Container(
            color: const Color(0xFFF4F6FB),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(strokeWidth: 2.4),
          )
        : (_mapSource == _MapSource.google
              ? _buildGoogleMap(
                  model: model,
                  state: state,
                  dayRoutes: dayRoutes,
                  allActivities: allActivities,
                  next: next,
                )
              : _buildAmap(
                  model: model,
                  state: state,
                  dayRoutes: dayRoutes,
                  allActivities: allActivities,
                  next: next,
                ));
  }

  Widget _buildDayTabBar({
    required ItineraryModel model,
    required TripState state,
    required List<_DayRoute> dayRoutes,
  }) {
    if (state == TripState.preparing) {
      final int count = dayRoutes.length;
      final int selected = _selectedDayIndex > count ? 0 : _selectedDayIndex;
      return Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          itemCount: count + 1,
          itemBuilder: (BuildContext context, int index) {
            final bool isSelected = selected == index;
            final String label = index == 0 ? '全览' : 'Day $index';
            final Color tabColor = index == 0
                ? Colors.black87
                : _getUnifiedDayColor(
                    index - 1,
                    _getPlanDayDataAt(model, index - 1),
                  );
            return GestureDetector(
              onTap: () => _selectDayFilter(index, dayRoutes: dayRoutes),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? tabColor : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? Colors.transparent
                        : Colors.grey.shade200,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.grey.shade600,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
    final List<Map<String, dynamic>> timelineData = _buildTravelingTimelineData(
      model,
    );
    final int maxDay = timelineData.fold<int>(0, (
      int previous,
      Map<String, dynamic> item,
    ) {
      final int day = (item['day'] as num?)?.toInt() ?? 1;
      return day > previous ? day : previous;
    });
    final int selected = _selectedDayIndex > maxDay ? 0 : _selectedDayIndex;
    return KeyedSubtree(
      key: _timelineListTopKey,
      child: SizedBox(
        height: 44,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: maxDay + 1,
          itemBuilder: (BuildContext context, int index) {
            final bool isSelected = selected == index;
            final String label = index == 0 ? '全览' : 'Day $index';
            final Color tabColor = index == 0
                ? Colors.black87
                : _getUnifiedDayColor(
                    index - 1,
                    _getPlanDayDataAt(model, index - 1),
                  );
            return GestureDetector(
              onTap: () => _selectDayFilter(index, dayRoutes: dayRoutes),
              child: Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? tabColor : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: isSelected
                        ? Colors.transparent
                        : Colors.grey.shade200,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.grey.shade600,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildGoogleMap({
    required ItineraryModel model,
    required TripState state,
    required List<_DayRoute> dayRoutes,
    required List<ActivityItem> allActivities,
    required ActivityItem? next,
  }) {
    final List<_VisibleActivity> visible = state == TripState.traveling
        ? <_VisibleActivity>[]
        : _collectVisibleActivities(model, dayRoutes, state);
    final Set<gmap.Marker> markers = <gmap.Marker>{};
    if (state == TripState.traveling) {
      final List<Map<String, dynamic>> points = _timelineMapItems(model, state);
      for (int i = 0; i < points.length; i++) {
        final Map<String, dynamic> currentActivity = points[i];
        final int currentActIdx = i;
        final String timelineKey = _timelineItemKey(currentActivity);
        final String cacheKey =
            '${timelineKey}_${_isTimelineItemArrived(currentActivity) ? 'arrived' : 'active'}';
        final gmap.BitmapDescriptor? customIcon = _googleMarkerCache[cacheKey];
        if (customIcon == null) continue;
        markers.add(
          gmap.Marker(
            markerId: gmap.MarkerId(cacheKey),
            position: gmap.LatLng(
              (currentActivity['lat'] as num).toDouble(),
              (currentActivity['lng'] as num).toDouble(),
            ),
            icon: customIcon,
            infoWindow: gmap.InfoWindow(
              title: currentActivity['title'] as String? ?? '',
              snippet: currentActivity['duration'] as String? ?? '',
            ),
            onTap: () => _focusTimelineMapItem(currentActivity, currentActIdx),
          ),
        );
      }
    } else {
      for (final _VisibleActivity va in visible) {
        final gmap.BitmapDescriptor? customIcon = _googleMarkerCache[va.key];
        if (customIcon == null) continue;
        markers.add(
          gmap.Marker(
            markerId: gmap.MarkerId(va.key),
            position: gmap.LatLng(va.activity.lat, va.activity.lng),
            icon: customIcon,
            infoWindow: gmap.InfoWindow(
              title: va.activity.title,
              snippet:
                  '${va.activity.recommendedDuration} · ${va.activity.aiHighlight}',
            ),
            onTap: () {
              setState(() => _selectedActivity = va.activity);
              _focusOnActivity(va.activity);
            },
          ),
        );
      }
    }

    final Set<gmap.Polyline> lines = _buildGooglePolylines(
      model: model,
      dayRoutes: dayRoutes,
      state: state,
      next: next,
    );

    final gmap.LatLng center = _currentPosition != null
        ? gmap.LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : (allActivities.isNotEmpty
              ? gmap.LatLng(allActivities.first.lat, allActivities.first.lng)
              : const gmap.LatLng(39.909187, 116.397451));

    return Stack(
      children: <Widget>[
        gmap.GoogleMap(
          initialCameraPosition: gmap.CameraPosition(target: center, zoom: 12),
          onMapCreated: (gmap.GoogleMapController c) {
            _googleController = c;
            if (_allowAutoFitOnMapCreate) {
              _allowAutoFitOnMapCreate = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _focusSelectedRoute(dayRoutes);
              });
            }
          },
          markers: markers,
          polylines: lines,
          // 行程中模式：开启定位；规划模式：关闭定位，允许自由缩放总览全局
          myLocationEnabled: state == TripState.traveling,
          myLocationButtonEnabled: true,
          zoomControlsEnabled: false,
          onTap: (_) => setState(() => _selectedActivity = null),
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        ),
        _buildMapInfoOverlay(),
      ],
    );
  }

  Set<gmap.Polyline> _buildGooglePolylines({
    required ItineraryModel model,
    required List<_DayRoute> dayRoutes,
    required TripState state,
    required ActivityItem? next,
  }) {
    final Set<gmap.Polyline> lines = <gmap.Polyline>{};
    final List<gmap.LatLng> points = _orderedGoogleRoutePoints(
      model,
      dayRoutes,
      state,
    );
    if (points.length >= 2) {
      lines.add(
        gmap.Polyline(
          polylineId: const gmap.PolylineId('route_border'),
          points: points,
          color: Colors.white,
          width: 10,
          zIndex: 1,
        ),
      );
      lines.add(
        gmap.Polyline(
          polylineId: const gmap.PolylineId('route_core'),
          points: points,
          color: Colors.indigo,
          width: 6,
          zIndex: 2,
        ),
      );
    } else if (next != null && _currentPosition != null) {
      lines.add(
        gmap.Polyline(
          polylineId: const gmap.PolylineId('fallback_border'),
          points: <gmap.LatLng>[
            gmap.LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            gmap.LatLng(next.lat, next.lng),
          ],
          color: Colors.white,
          width: 10,
          zIndex: 1,
        ),
      );
      lines.add(
        gmap.Polyline(
          polylineId: const gmap.PolylineId('fallback_core'),
          points: <gmap.LatLng>[
            gmap.LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            gmap.LatLng(next.lat, next.lng),
          ],
          color: Colors.indigo,
          width: 6,
          zIndex: 2,
        ),
      );
    }
    return lines;
  }

  Widget _buildAmap({
    required ItineraryModel model,
    required TripState state,
    required List<_DayRoute> dayRoutes,
    required List<ActivityItem> allActivities,
    required ActivityItem? next,
  }) {
    final List<_VisibleActivity> visible = state == TripState.traveling
        ? <_VisibleActivity>[]
        : _collectVisibleActivities(model, dayRoutes, state);
    final Set<amap.Marker> markers = <amap.Marker>{};
    if (state == TripState.traveling) {
      final List<Map<String, dynamic>> points = _timelineMapItems(model, state);
      for (int i = 0; i < points.length; i++) {
        final Map<String, dynamic> currentActivity = points[i];
        final int currentActIdx = i;
        final String timelineKey = _timelineItemKey(currentActivity);
        final String cacheKey =
            '${timelineKey}_${_isTimelineItemArrived(currentActivity) ? 'arrived' : 'active'}';
        final amap.BitmapDescriptor? customIcon = _amapMarkerCache[cacheKey];
        if (customIcon == null) continue;
        markers.add(
          amap.Marker(
            position: amap_base.LatLng(
              (currentActivity['lat'] as num).toDouble(),
              (currentActivity['lng'] as num).toDouble(),
            ),
            icon: customIcon,
            infoWindowEnable: false,
            onTap: (String markerId) =>
                _focusTimelineMapItem(currentActivity, currentActIdx),
          ),
        );
      }
    } else {
      for (final _VisibleActivity va in visible) {
        final amap.BitmapDescriptor? customIcon = _amapMarkerCache[va.key];
        if (customIcon == null) continue;
        markers.add(
          amap.Marker(
            position: amap_base.LatLng(va.activity.lat, va.activity.lng),
            icon: customIcon,
            infoWindowEnable: false,
            onTap: (String markerId) {
              _selectedActivityImages = va.activity.imageUrl.trim().isEmpty
                  ? <String>[]
                  : <String>[va.activity.imageUrl];
              setState(() => _selectedActivity = va.activity);
              _focusOnActivity(va.activity);
            },
          ),
        );
      }
    }
    final Set<amap.Polyline> polylines = _buildAmapPolylines(
      model: model,
      dayRoutes: dayRoutes,
      state: state,
      next: next,
    );

    final amap_base.LatLng center = _currentPosition != null
        ? amap_base.LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          )
        : (allActivities.isNotEmpty
              ? amap_base.LatLng(
                  allActivities.first.lat,
                  allActivities.first.lng,
                )
              : const amap_base.LatLng(39.909187, 116.397451));

    return Stack(
      children: <Widget>[
        amap.AMapWidget(
          privacyStatement: const amap_base.AMapPrivacyStatement(
            hasContains: true,
            hasShow: true,
            hasAgree: true,
          ),
          // 如原生配置异常，请在此填入你自己的高德 Key 作为兜底。
          apiKey: const amap_base.AMapApiKey(
            androidKey: AMapConfig.androidKey,
            iosKey: AMapConfig.iosKey,
          ),
          initialCameraPosition: amap.CameraPosition(target: center, zoom: 12),
          onMapCreated: (amap.AMapController c) {
            _aMapController = c;
            if (_allowAutoFitOnMapCreate) {
              _allowAutoFitOnMapCreate = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _focusSelectedRoute(dayRoutes);
              });
            }
          },
          markers: markers,
          polylines: polylines,
          // 行程中模式：开启蓝点定位与视角跟随；规划模式：关闭跟随，允许自由缩放总览全局
          myLocationStyleOptions: state == TripState.traveling
              ? amap.MyLocationStyleOptions(true)
              : amap.MyLocationStyleOptions(false),
          onTap: (amap_base.LatLng latLng) {
            if (_selectedActivity != null) {
              setState(() => _selectedActivity = null);
            }
          },
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        ),
        _buildMapInfoOverlay(),
      ],
    );
  }

  Set<amap.Polyline> _buildAmapPolylines({
    required ItineraryModel model,
    required List<_DayRoute> dayRoutes,
    required TripState state,
    required ActivityItem? next,
  }) {
    final Set<amap.Polyline> lines = <amap.Polyline>{};

    void addRouteSegments(
      List<amap_base.LatLng> points,
      Color color, {
      required int day,
    }) {
      if (points.length < 2) return;
      final amap.BitmapDescriptor? dayTexture = _amapArrowTextureByDay[day];
      for (int i = 0; i < points.length - 1; i++) {
        final amap_base.LatLng from = points[i];
        final amap_base.LatLng to = points[i + 1];
        final String segKey =
            '${from.latitude},${from.longitude}'
            '|${to.latitude},${to.longitude}';
        final List<amap_base.LatLng>? segPoints = _routeCache[segKey];
        if (segPoints == null) {
          continue;
        }

        lines.add(
          amap.Polyline(points: segPoints, color: Colors.white, width: 14),
        );
        lines.add(amap.Polyline(points: segPoints, color: color, width: 9.2));
        lines.add(
          amap.Polyline(
            points: segPoints,
            color: color,
            width: 9.2,
            customTexture: dayTexture,
          ),
        );
      }
    }

    if (state == TripState.traveling) {
      // 【行程中模式】：使用真实的弯曲轨迹
      final Map<int, List<Map<String, dynamic>>> activitiesByDay =
          <int, List<Map<String, dynamic>>>{};
      for (final Map<String, dynamic> item in _timelineMapItems(model, state)) {
        final int day = (item['day'] as num?)?.toInt() ?? 1;
        activitiesByDay
            .putIfAbsent(day, () => <Map<String, dynamic>>[])
            .add(item);
      }
      for (final MapEntry<int, List<Map<String, dynamic>>> entry
          in activitiesByDay.entries) {
        final List<Map<String, dynamic>> activities = entry.value;
        final Map<String, dynamic> currentDayData = _getPlanDayDataAt(
          model,
          entry.key - 1,
        );
        final Color unifiedDayColor = _getUnifiedDayColor(
          entry.key - 1,
          currentDayData,
        );
        for (int i = 0; i < activities.length - 1; i++) {
          final Map<String, dynamic> origin = activities[i];
          final Map<String, dynamic> dest = activities[i + 1];
          final List<amap_base.LatLng> routePoints = _routePointsFromTransit(
            origin,
            dest,
          );
          if (routePoints.length < 2) continue;
          
          // 行程中模式：使用真实弯曲轨迹（保持原有逻辑）
          lines.add(
            amap.Polyline(points: routePoints, color: Colors.white, width: 14),
          );
          lines.add(
            amap.Polyline(
              points: routePoints,
              color: unifiedDayColor,
              width: 9.2,
            ),
          );
          lines.add(
            amap.Polyline(
              points: routePoints,
              color: unifiedDayColor,
              width: 9.2,
              customTexture: _amapArrowTextureByDay[entry.key],
            ),
          );
        }
      }
    } else if (dayRoutes.isNotEmpty) {
      // 【规划模式】：强制使用两点直连飞线
      final Iterable<MapEntry<int, _DayRoute>> visibleRoutes =
          _selectedDayIndex == 0
          ? dayRoutes.asMap().entries
          : dayRoutes.asMap().entries.where(
              (MapEntry<int, _DayRoute> entry) =>
                  entry.key + 1 == _selectedDayIndex,
            );
      for (final MapEntry<int, _DayRoute> entry in visibleRoutes) {
        final List<ActivityItem> validActivities = entry.value.activities
            .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
            .toList(growable: false);
        final Map<String, dynamic> currentDayData = _getPlanDayDataAt(
          model,
          entry.key,
        );
        final Color unifiedDayColor = _getUnifiedDayColor(
          entry.key,
          currentDayData,
        );
        
        // 遍历相邻活动，生成两点直连飞线
        for (int i = 0; i < validActivities.length - 1; i++) {
          final ActivityItem origin = validActivities[i];
          final ActivityItem dest = validActivities[i + 1];
          
          // 规划模式：强制使用两点直连飞线（不使用真实路网）
          final List<amap_base.LatLng> straightLinePoints = <amap_base.LatLng>[
            amap_base.LatLng(origin.lat, origin.lng),
            amap_base.LatLng(dest.lat, dest.lng),
          ];
          
          final amap.BitmapDescriptor? dayTexture = _amapArrowTextureByDay[entry.key + 1];
          
          // 底层白边（保持原有样式）
          lines.add(
            amap.Polyline(
              points: straightLinePoints,
              color: Colors.white,
              width: 14,
            ),
          );
          
          // 表层彩色线（保持原有样式）
          lines.add(
            amap.Polyline(
              points: straightLinePoints,
              color: unifiedDayColor,
              width: 9.2,
            ),
          );
          
          // 带箭头纹理的彩色线（保持原有样式）
          lines.add(
            amap.Polyline(
              points: straightLinePoints,
              color: unifiedDayColor,
              width: 9.2,
              customTexture: dayTexture,
            ),
          );
        }
      }
    } else if (next != null && _currentPosition != null) {
      // 当前位置 → 下一个待游玩景点的兜底导航线
      final amap_base.LatLng curPos = amap_base.LatLng(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
      final amap_base.LatLng nextPos = amap_base.LatLng(next.lat, next.lng);
      final String segKey =
          '${curPos.latitude},${curPos.longitude}'
          '|${nextPos.latitude},${nextPos.longitude}';
      final List<amap_base.LatLng>? segPoints = _routeCache[segKey];
      if (segPoints == null) {
        return lines;
      }
      lines.add(
        amap.Polyline(points: segPoints, color: Colors.white, width: 14),
      );
      lines.add(
        amap.Polyline(
          points: segPoints,
          color: _getUnifiedDayColor(
            ((_selectedDayIndex - 1).clamp(0, 9999)).toInt(),
            _getPlanDayDataAt(model, _selectedDayIndex - 1),
          ),
          width: 9.2,
        ),
      );
      lines.add(
        amap.Polyline(
          points: segPoints,
          color: _getUnifiedDayColor(
            ((_selectedDayIndex - 1).clamp(0, 9999)).toInt(),
            _getPlanDayDataAt(model, _selectedDayIndex - 1),
          ),
          width: 9.2,
          customTexture: _amapArrowTextureByDay[_selectedDayIndex],
        ),
      );
    }
    return lines;
  }

  List<amap_base.LatLng> _routePointsFromTransit(
    Map<String, dynamic> origin,
    Map<String, dynamic> dest,
  ) {
    final Object? raw =
        (origin['transit'] as Map<String, dynamic>?)?['routePoints'];
    final List<amap_base.LatLng> parsed = <amap_base.LatLng>[];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is amap_base.LatLng) {
          parsed.add(item);
        } else if (item is Map) {
          final double? lat = (item['lat'] as num?)?.toDouble();
          final double? lng = (item['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            parsed.add(amap_base.LatLng(lat, lng));
          }
        }
      }
    }
    final String originTitle = origin['title']?.toString() ?? '起点';
    final String destTitle = dest['title']?.toString() ?? '终点';
    if (parsed.length >= 2) {
      debugPrint(
        '✅ 成功加载真实路线 [$originTitle -> $destTitle]，共 ${parsed.length} 个拐点',
      );
      return parsed;
    }
    final double? oLat = (origin['lat'] as num?)?.toDouble();
    final double? oLng = (origin['lng'] as num?)?.toDouble();
    final double? dLat = (dest['lat'] as num?)?.toDouble();
    final double? dLng = (dest['lng'] as num?)?.toDouble();
    if (oLat == null || oLng == null || dLat == null || dLng == null) {
      debugPrint('🚨 严重警告：[$originTitle -> $destTitle] 缺少有效经纬度，无法构建路线');
      return <amap_base.LatLng>[];
    }
    debugPrint(
      '🚨 严重警告：[$originTitle -> $destTitle] 缺少真实轨迹 routePoints！已被迫触发直线兜底！请检查 _fetchAllRoutesAndSync 是否执行成功！',
    );
    return <amap_base.LatLng>[
      amap_base.LatLng(oLat, oLng),
      amap_base.LatLng(dLat, dLng),
    ];
  }

  List<Map<String, dynamic>> _timelineMapItems(
    ItineraryModel model,
    TripState state,
  ) {
    final List<Map<String, dynamic>> source = state == TripState.traveling
        ? _buildTravelingTimelineData(model)
        : _mockTimeline;
    return source
        .where((Map<String, dynamic> item) {
          final double? lat = (item['lat'] as num?)?.toDouble();
          final double? lng = (item['lng'] as num?)?.toDouble();
          if (lat == null || lng == null) return false;
          if (_selectedDayIndex == 0) return true;
          return ((item['day'] as num?)?.toInt() ?? 1) == _selectedDayIndex;
        })
        .toList(growable: false);
  }

  List<gmap.LatLng> _orderedGoogleRoutePoints(
    ItineraryModel model,
    List<_DayRoute> dayRoutes,
    TripState state,
  ) {
    if (state == TripState.traveling) {
      return _timelineMapItems(model, state)
          .map(
            (Map<String, dynamic> item) => gmap.LatLng(
              (item['lat'] as num).toDouble(),
              (item['lng'] as num).toDouble(),
            ),
          )
          .toList(growable: false);
    }
    final Iterable<ActivityItem> activities = _selectedDayIndex == 0
        ? dayRoutes.expand((_DayRoute route) => route.activities)
        : dayRoutes[_selectedDayIndex - 1].activities;
    return activities
        .map((ActivityItem a) => gmap.LatLng(a.lat, a.lng))
        .toList(growable: false);
  }

  List<_VisibleActivity> _collectVisibleActivities(
    ItineraryModel model,
    List<_DayRoute> dayRoutes,
    TripState state,
  ) {
    final List<_VisibleActivity> result = <_VisibleActivity>[];
    for (int dayIndex = 0; dayIndex < dayRoutes.length; dayIndex++) {
      if (state == TripState.preparing &&
          _selectedDayIndex != 0 &&
          _selectedDayIndex != dayIndex + 1) {
        continue;
      }
      final _DayRoute route = dayRoutes[dayIndex];
      final Color unifiedDayColor = _getUnifiedDayColor(
        dayIndex,
        _getPlanDayDataAt(model, dayIndex),
      );
      for (int i = 0; i < route.activities.length; i++) {
        final ActivityItem activity = route.activities[i];
        if (activity.lat == 0 || activity.lng == 0) continue;
        result.add(
          _VisibleActivity(
            key: 'd${dayIndex + 1}_m${i + 1}_${activity.id}',
            dayIndex: dayIndex,
            order: i + 1,
            activity: activity,
            color: unifiedDayColor,
          ),
        );
      }
    }
    return result;
  }

  String _buildMarkerPlanKey(ItineraryModel model, List<_DayRoute> dayRoutes) {
    final StringBuffer buffer = StringBuffer();
    for (int d = 0; d < dayRoutes.length; d++) {
      final _DayRoute route = dayRoutes[d];
      final Color dayColor = _getUnifiedDayColor(d, _getPlanDayDataAt(model, d));
      buffer.write(
        'd$d:${dayColor.toARGB32()}:${route.activities.length};',
      );
      for (final ActivityItem activity in route.activities) {
        buffer.write('${activity.id}:${activity.lat},${activity.lng}|');
      }
    }
    for (final Map<String, dynamic> item in _buildTravelingTimelineData(
      model,
    )) {
      buffer.write(
        't:${_timelineItemKey(item)}:${item['day']}:${item['lat']},${item['lng']}|',
      );
    }
    return buffer.toString();
  }

  void _maybeInitMarkers(ItineraryModel model, List<_DayRoute> dayRoutes) {
    final String nextKey = _buildMarkerPlanKey(model, dayRoutes);
    if (nextKey == _markerCachePlanKey) return;
    _markerCachePlanKey = nextKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initMarkers(model, dayRoutes);
    });
    _maybeSyncRoutes(model);
  }

  String _buildRouteSyncPlanKey(ItineraryModel model) {
    final List<Map<String, dynamic>> items = _buildTravelingTimelineData(model);
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < items.length; i++) {
      final Map<String, dynamic> it = items[i];
      b.write(
        '${_timelineItemKey(it)}:${it['day']}:${it['lat']},${it['lng']}|',
      );
    }
    return b.toString();
  }

  void _maybeSyncRoutes(ItineraryModel model) {
    final String nextKey = _buildRouteSyncPlanKey(model);
    if (nextKey == _routeSyncPlanKey) return;
    _routeSyncPlanKey = nextKey;
    // ignore: unawaited_futures
    _fetchAllRoutesAndSync(model);
  }

  Future<void> _initMarkers(
    ItineraryModel model,
    List<_DayRoute> dayRoutes,
  ) async {
    if (!mounted) return;
    setState(() {
      _isMapLoading = true;
      _googleMarkerCache.clear();
      _amapMarkerCache.clear();
    });
    final List<_VisibleActivity> allVisible = _collectVisibleActivities(
      model,
      dayRoutes,
      TripState.preparing,
    );
    final Map<String, gmap.BitmapDescriptor> nextGoogleMarkerCache =
        <String, gmap.BitmapDescriptor>{};
    final Map<String, amap.BitmapDescriptor> nextAmapMarkerCache =
        <String, amap.BitmapDescriptor>{};
    final List<Future<void>> markerTasks = <Future<void>>[];

    for (final _VisibleActivity va in allVisible) {
      markerTasks.add(() async {
        try {
          final gmap.BitmapDescriptor googleIcon = await _createNumberedMarker(
            va.order,
            va.color,
          );
          final Uint8List bytes = await _createNumberedMarkerBytes(
            va.order,
            va.color,
          );
          nextGoogleMarkerCache[va.key] = googleIcon;
          nextAmapMarkerCache[va.key] = amap.BitmapDescriptor.fromBytes(bytes);
        } catch (_) {
          // ignore failed marker icon and continue
        }
      }());
    }
    final List<Map<String, dynamic>> timelineItems =
        _buildTravelingTimelineData(model);
    final Set<int> usedDays = <int>{
      ...timelineItems.map(
        (Map<String, dynamic> item) => (item['day'] as num?)?.toInt() ?? 1,
      ),
      ...dayRoutes.asMap().keys.map((int idx) => idx + 1),
    };
    for (final int day in usedDays) {
      markerTasks.add(_ensureArrowTextureForDay(day));
    }
    for (int i = 0; i < timelineItems.length; i++) {
      final Map<String, dynamic> item = timelineItems[i];
      final double? lat = (item['lat'] as num?)?.toDouble();
      final double? lng = (item['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final String cacheKey = _timelineItemKey(item);
      final int order = _globalDayOrderAt(timelineItems, i);
      final int day = (item['day'] as num?)?.toInt() ?? 1;
      final Color markerColor = _getUnifiedDayColor(
        day - 1,
        _getPlanDayDataAt(model, day - 1),
      );
      markerTasks.add(() async {
        try {
          final gmap.BitmapDescriptor googleIcon = await _createNumberedMarker(
            order,
            markerColor,
          );
          final Uint8List bytes = await _createNumberedMarkerBytes(
            order,
            markerColor,
          );
          final gmap.BitmapDescriptor arrivedGoogleIcon =
              await _createNumberedMarker(order, Colors.grey.shade400);
          final Uint8List arrivedBytes = await _createNumberedMarkerBytes(
            order,
            Colors.grey.shade400,
          );
          nextGoogleMarkerCache['${cacheKey}_active'] = googleIcon;
          nextAmapMarkerCache['${cacheKey}_active'] =
              amap.BitmapDescriptor.fromBytes(bytes);
          nextGoogleMarkerCache['${cacheKey}_arrived'] = arrivedGoogleIcon;
          nextAmapMarkerCache['${cacheKey}_arrived'] =
              amap.BitmapDescriptor.fromBytes(arrivedBytes);
        } catch (_) {
          // ignore failed marker icon and continue
        }
      }());
    }
    await Future.wait(markerTasks);
    if (!mounted) return;
    setState(() {
      _googleMarkerCache
        ..clear()
        ..addAll(nextGoogleMarkerCache);
      _amapMarkerCache
        ..clear()
        ..addAll(nextAmapMarkerCache);
      _isMapLoading = false;
    });
    // 所有 Marker 已就绪后，后台异步预取真实路网（渐进式更新折线）
    // ignore: unawaited_futures
    _initRoutes(timelineItems, dayRoutes);
  }

  Future<Uint8List> _createNumberedMarkerBytes(
    int number,
    Color bgColor,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    const double size = 80.0;

    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, borderPaint);

    final Paint bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 6, bgPaint);

    final TextPainter painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: number.toString(),
        style: const TextStyle(
          fontSize: 36,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    )..layout();
    painter.paint(
      canvas,
      Offset(size / 2 - painter.width / 2, size / 2 - painter.height / 2),
    );

    final ui.Image img = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<gmap.BitmapDescriptor> _createNumberedMarker(
    int number,
    Color bgColor,
  ) async {
    final Uint8List bytes = await _createNumberedMarkerBytes(number, bgColor);
    return gmap.BitmapDescriptor.bytes(bytes);
  }

  Future<void> _focusSelectedRoute(List<_DayRoute> routes) async {
    if (routes.isEmpty) return;
    final List<ActivityItem> target;
    if (_selectedDayIndex == 0) {
      target = routes
          .expand((_DayRoute route) => route.activities)
          .toList(growable: false);
    } else {
      target = routes[_selectedDayIndex - 1].activities;
    }
    await _focusPoints(target);
  }

  List<amap_base.LatLng> _pointsForSelectedDay(List<_DayRoute> routes) {
    if (routes.isEmpty) return <amap_base.LatLng>[];
    final Iterable<ActivityItem> target = _selectedDayIndex == 0
        ? routes.expand((_DayRoute route) => route.activities)
        : routes[_selectedDayIndex - 1].activities;
    return target
        .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
        .map((ActivityItem a) => amap_base.LatLng(a.lat, a.lng))
        .toList(growable: false);
  }

  void _fitMapToBounds(List<amap_base.LatLng> points) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      final amap_base.LatLng p = points.first;
      _googleController?.animateCamera(
        gmap.CameraUpdate.newLatLngZoom(gmap.LatLng(p.latitude, p.longitude), 14),
      );
      _aMapController?.moveCamera(
        amap.CameraUpdate.newLatLngZoom(
          amap_base.LatLng(p.latitude, p.longitude),
          14,
        ),
      );
      return;
    }
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final amap_base.LatLng p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _googleController?.animateCamera(
      gmap.CameraUpdate.newLatLngBounds(
        gmap.LatLngBounds(
          southwest: gmap.LatLng(minLat, minLng),
          northeast: gmap.LatLng(maxLat, maxLng),
        ),
        50,
      ),
    );
    _aMapController?.moveCamera(
      amap.CameraUpdate.newLatLngBounds(
        amap_base.LatLngBounds(
          southwest: amap_base.LatLng(minLat, minLng),
          northeast: amap_base.LatLng(maxLat, maxLng),
        ),
        50,
      ),
    );
  }

  void _selectDayFilter(int index, {required List<_DayRoute> dayRoutes}) {
    setState(() {
      _selectedDayIndex = index;
      _selectedActivity = null;
      _focusedTimelineKey = null;
      _allowAutoFitOnMapCreate = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      _fitMapToBounds(_pointsForSelectedDay(dayRoutes));
    });
  }

  Future<void> _focusOnActivity(ActivityItem activity) async {
    await _googleController?.animateCamera(
      gmap.CameraUpdate.newLatLngZoom(
        gmap.LatLng(activity.lat, activity.lng),
        14,
      ),
    );
    await _aMapController?.moveCamera(
      amap.CameraUpdate.newLatLngZoom(
        amap_base.LatLng(activity.lat, activity.lng),
        14,
      ),
    );
  }

  Future<void> _focusPoints(List<ActivityItem> points) async {
    final List<ActivityItem> valid = points
        .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
        .toList(growable: false);
    if (valid.isEmpty) return;
    if (valid.length == 1) {
      await _focusOnActivity(valid.first);
      return;
    }
    double minLat = valid.first.lat;
    double maxLat = valid.first.lat;
    double minLng = valid.first.lng;
    double maxLng = valid.first.lng;
    for (final ActivityItem a in valid) {
      minLat = a.lat < minLat ? a.lat : minLat;
      maxLat = a.lat > maxLat ? a.lat : maxLat;
      minLng = a.lng < minLng ? a.lng : minLng;
      maxLng = a.lng > maxLng ? a.lng : maxLng;
    }
    await _googleController?.animateCamera(
      gmap.CameraUpdate.newLatLngBounds(
        gmap.LatLngBounds(
          southwest: gmap.LatLng(minLat, minLng),
          northeast: gmap.LatLng(maxLat, maxLng),
        ),
        60,
      ),
    );
    await _aMapController?.moveCamera(
      amap.CameraUpdate.newLatLngBounds(
        amap_base.LatLngBounds(
          southwest: amap_base.LatLng(minLat, minLng),
          northeast: amap_base.LatLng(maxLat, maxLng),
        ),
        60,
      ),
    );
  }

  // ─── 高德真实路网 ────────────────────────────────────────────────
  // 调用高德步行 / 驾车路径规划 API，返回沿路真实拐点数组。
  // 结果写入 _routeCache，后续直接复用，无需重复网络请求。
  // 若 API 不可达或无结果，只记录失败状态，渲染层不会用直线冒充路线。
  //
  // ⚠️ Key 说明：本文件已在 AMapWidget.apiKey 注入了硬编码兜底 Key，
  //    生产环境请同步在 AndroidManifest / Info.plist 原生层填入真实 Key；
  //    否则高德底图与 Direction API 都可能无法加载。
  Future<_RouteFetchResult> _fetchRoute(
    amap_base.LatLng origin,
    amap_base.LatLng dest,
    String? preferredMode,
  ) async {
    final String cacheKey =
        '${origin.latitude},${origin.longitude}'
        '|${dest.latitude},${dest.longitude}';
    if (_routeResultCache.containsKey(cacheKey)) {
      final _RouteFetchResult cached = _routeResultCache[cacheKey]!;
      return _RouteFetchResult(
        points: cached.points,
        distanceMeters: cached.distanceMeters,
        durationSeconds: cached.durationSeconds,
        routeMode: cached.routeMode.isNotEmpty
            ? cached.routeMode
            : (preferredMode ?? ''),
      );
    }
    if (_routeCache.containsKey(cacheKey)) {
      return _RouteFetchResult(
        points: _routeCache[cacheKey]!,
        routeMode: preferredMode ?? '',
      );
    }

    // 这里是高德 Direction HTTP 请求，必须使用 Web 服务 Key，严禁使用 SDK Key。
    const String amapWebKey = AMapConfig.webApiKey;
    // 短距离优先步行，长距离优先驾车，避免“全是步行”不合理。
    final double dist = Geolocator.distanceBetween(
      origin.latitude,
      origin.longitude,
      dest.latitude,
      dest.longitude,
    );
    final String mode = switch (preferredMode) {
      'walk' => dist < 2600 ? 'walking' : 'driving',
      'car' || 'metro' => 'driving',
      _ => dist < 1800 ? 'walking' : 'driving',
    };

    Future<_RouteFetchResult?> requestByMode(String requestMode) async {
      final Uri uri = Uri.parse(
        'https://restapi.amap.com/v3/direction/$requestMode'
        '?key=$amapWebKey'
        '&origin=${origin.longitude},${origin.latitude}'
        '&destination=${dest.longitude},${dest.latitude}',
      );
      try {
        final http.Response response = await http
            .get(uri)
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) return null;
        final Map<String, dynamic> data =
            jsonDecode(response.body) as Map<String, dynamic>;
        if (data['status'] != '1') {
          debugPrint(
            '高德算路失败($requestMode): info=${data['info']} infocode=${data['infocode']}',
          );
          return null;
        }
        final List<dynamic> paths =
            ((data['route'] as Map<String, dynamic>)['paths'] as List<dynamic>?) ??
            <dynamic>[];
        if (paths.isEmpty) return null;
        final Map<String, dynamic> path =
            paths.first as Map<String, dynamic>? ?? <String, dynamic>{};
        final List<dynamic> steps = (path['steps'] as List<dynamic>?) ?? <dynamic>[];
        final List<amap_base.LatLng> points = <amap_base.LatLng>[];
        for (final Object? step in steps) {
          final String polyline =
              (step as Map<String, dynamic>)['polyline'] as String? ?? '';
          for (final String coord in polyline.split(';')) {
            final List<String> parts = coord.split(',');
            if (parts.length == 2) {
              final double? lng = double.tryParse(parts[0]);
              final double? lat = double.tryParse(parts[1]);
              if (lat != null && lng != null) {
                points.add(amap_base.LatLng(lat, lng));
              }
            }
          }
        }
        if (points.isEmpty) return null;
        final int distanceMeters = int.tryParse(path['distance'].toString()) ?? 0;
        final int durationSeconds = int.tryParse(path['duration'].toString()) ?? 0;
        return _RouteFetchResult(
          points: points,
          distanceMeters: distanceMeters,
          durationSeconds: durationSeconds,
          routeMode: requestMode,
        );
      } catch (e) {
        debugPrint('请求路段失败($requestMode): $e');
        return null;
      }
    }

    _RouteFetchResult? result = await requestByMode(mode);
    if (result == null) {
      final String fallbackMode = mode == 'walking' ? 'driving' : 'walking';
      result = await requestByMode(fallbackMode);
    }
    if (result != null) {
      _routeFallbackKeys.remove(cacheKey);
      _routeCache[cacheKey] = result.points;
      _routeResultCache[cacheKey] = result;
      return result;
    }

    // API 失败：保留失败标记，渲染层会跳过该段，避免出现飞线。
    final List<amap_base.LatLng> fallback = <amap_base.LatLng>[origin, dest];
    final int fallbackDistance = Geolocator.distanceBetween(
      origin.latitude,
      origin.longitude,
      dest.latitude,
      dest.longitude,
    ).round();
    final int fallbackDuration = mode == 'walking'
        ? (fallbackDistance / 1.2)
              .round() // 约 4.3 km/h
        : (fallbackDistance / 8.3).round(); // 约 30 km/h
    _routeFallbackKeys.add(cacheKey);
    _routeCache[cacheKey] = fallback;
    final _RouteFetchResult fallbackResult = _RouteFetchResult(
      points: fallback,
      distanceMeters: fallbackDistance,
      durationSeconds: fallbackDuration,
      routeMode: mode,
    );
    _routeResultCache[cacheKey] = fallbackResult;
    return fallbackResult;
  }

  // 批量预取所有相邻活动之间的路径，后台异步执行不阻塞地图渲染。
  // 每段路径拿到后立刻 setState 触发折线更新，实现"渐进式真实路网"效果。
  Future<void> _initRoutes(
    List<Map<String, dynamic>> timelineItems,
    List<_DayRoute> dayRoutes,
  ) async {
    // ① 行程中（traveling）模式：按 Day 分组预取，严禁跨天连接成飞线
    final Map<int, List<Map<String, dynamic>>> timelineByDay =
        <int, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> item in timelineItems) {
      final int day = (item['day'] as num?)?.toInt() ?? 1;
      timelineByDay.putIfAbsent(day, () => <Map<String, dynamic>>[]).add(item);
    }
    for (final List<Map<String, dynamic>> items in timelineByDay.values) {
      for (int i = 0; i < items.length - 1; i++) {
        final double? lat1 = (items[i]['lat'] as num?)?.toDouble();
        final double? lng1 = (items[i]['lng'] as num?)?.toDouble();
        final double? lat2 = (items[i + 1]['lat'] as num?)?.toDouble();
        final double? lng2 = (items[i + 1]['lng'] as num?)?.toDouble();
        if (lat1 == null || lng1 == null || lat2 == null || lng2 == null) {
          continue;
        }
        final _RouteFetchResult routeResult = await _fetchRoute(
          amap_base.LatLng(lat1, lng1),
          amap_base.LatLng(lat2, lng2),
          (items[i]['transit'] as Map<String, dynamic>?)?['mode']?.toString(),
        );
        if (!mounted) return;
        final Map<String, dynamic>? transit =
            items[i]['transit'] as Map<String, dynamic>?;
        final Map<String, dynamic> writableTransit =
            transit ??
            <String, dynamic>{
              'mode': routeResult.routeMode == 'walking' ? 'walk' : 'car',
              'text': '',
              'distance': '',
            };
        if (transit == null) {
          items[i]['transit'] = writableTransit;
        }
        {
          final int distanceMeters = routeResult.distanceMeters > 0
              ? routeResult.distanceMeters
              : Geolocator.distanceBetween(lat1, lng1, lat2, lng2).round();
          final int durationMinutes = routeResult.durationSeconds > 0
              ? (routeResult.durationSeconds / 60).ceil()
              : (distanceMeters /
                        (writableTransit['mode'] == 'walk' ? 72 : 500))
                    .ceil();
          final String distanceText = distanceMeters > 1000
              ? '${(distanceMeters / 1000).toStringAsFixed(1)}公里'
              : '$distanceMeters米';
          final String modeLabel = writableTransit['mode'] == 'walk'
              ? '步行'
              : '驾车';
          final String itemKey = _timelineItemKey(items[i]);
          setState(() {
            writableTransit['distance'] = distanceText;
            writableTransit['text'] = '$modeLabel约$durationMinutes分钟';
            writableTransit['routePoints'] = routeResult.points;
            _timelineTransitOverride[itemKey] = Map<String, dynamic>.from(
              writableTransit,
            );
          });
        }
        setState(() {}); // 每拿到一段即时刷新折线
      }
    }

    // ② 行前（preparing）模式：跳过无坐标节点，连接相邻有效点
    for (final _DayRoute route in dayRoutes) {
      int i = 0;
      while (i < route.activities.length) {
        while (i < route.activities.length &&
            (route.activities[i].lat == 0 || route.activities[i].lng == 0)) {
          i++;
        }
        if (i >= route.activities.length) {
          break;
        }
        int j = i + 1;
        while (j < route.activities.length &&
            (route.activities[j].lat == 0 || route.activities[j].lng == 0)) {
          j++;
        }
        if (j >= route.activities.length) {
          break;
        }
        final ActivityItem a = route.activities[i];
        final ActivityItem b = route.activities[j];
        await _fetchRoute(
          amap_base.LatLng(a.lat, a.lng),
          amap_base.LatLng(b.lat, b.lng),
          _transportModeFromText(a.transportInfo),
        );
        if (!mounted) return;
        setState(() {});
        i = j;
      }
    }
  }

  // 全量同步：遍历所有相邻景点段，逐段请求高德并回写 transit。
  // 🚨 双轨引擎策略：地图画驾车平滑线，卡片显示真实公交时间
  Future<void> _fetchAllRoutesAndSync(ItineraryModel model) async {
    final List<Map<String, dynamic>> planItems = _buildTravelingTimelineData(
      model,
    );
    final Map<int, List<Map<String, dynamic>>> planDays =
        <int, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> item in planItems) {
      final int day = (item['day'] as num?)?.toInt() ?? 1;
      planDays.putIfAbsent(day, () => <Map<String, dynamic>>[]).add(item);
    }

    final String targetCity = _destinationCityHint(model);

    for (final List<Map<String, dynamic>> activities in planDays.values) {
      int i = 0;
      while (i < activities.length) {
        while (i < activities.length &&
            !_coordsNonZero(
              (activities[i]['lat'] as num?)?.toDouble(),
              (activities[i]['lng'] as num?)?.toDouble(),
            )) {
          i++;
        }
        if (i >= activities.length) {
          break;
        }
        int j = i + 1;
        while (j < activities.length &&
            !_coordsNonZero(
              (activities[j]['lat'] as num?)?.toDouble(),
              (activities[j]['lng'] as num?)?.toDouble(),
            )) {
          j++;
        }
        if (j >= activities.length) {
          break;
        }
        final Map<String, dynamic> origin = activities[i];
        final Map<String, dynamic> dest = activities[j];
        final String originTitle = origin['title']?.toString() ?? '起点';
        final String destTitle = dest['title']?.toString() ?? '终点';
        final double? olat = (origin['lat'] as num?)?.toDouble();
        final double? olng = (origin['lng'] as num?)?.toDouble();
        final double? dlat = (dest['lat'] as num?)?.toDouble();
        final double? dlng = (dest['lng'] as num?)?.toDouble();
        if (!_coordsNonZero(olat, olng) || !_coordsNonZero(dlat, dlng)) {
          i = j;
          continue;
        }

        final double originLat = olat!;
        final double originLng = olng!;
        final double destLat = dlat!;
        final double destLng = dlng!;

        // 计算直线距离，用于智能分发路线模式
        final double straightDistance = Geolocator.distanceBetween(
          originLat,
          originLng,
          destLat,
          destLng,
        );

        // 🚨 智能交通引擎分发
        String url = '';
        String mode = '';
        String transitTimeUrl = ''; // 新增：专门用于单独获取公交时间的 URL

        if (straightDistance < 1500) {
          mode = 'walk';
          url = 'https://restapi.amap.com/v3/direction/walking?key=${AMapConfig.webApiKey}&origin=$originLng,$originLat&destination=$destLng,$destLat';
        } else if (straightDistance < 15000) {
          mode = 'transit';
          // 1. 主请求：为了保证地图画线平滑好看，我们使用【驾车】API来画线！
          url = 'https://restapi.amap.com/v3/direction/driving?key=${AMapConfig.webApiKey}&origin=$originLng,$originLat&destination=$destLng,$destLat&strategy=0';
          // 2. 辅请求：为了给用户真实的通勤预期，准备一个【公交】API，稍后去"偷"时间！
          transitTimeUrl = 'https://restapi.amap.com/v3/direction/transit/integrated?key=${AMapConfig.webApiKey}&origin=$originLng,$originLat&destination=$destLng,$destLat&city=$targetCity&strategy=0';
        } else {
          mode = 'car';
          url = 'https://restapi.amap.com/v3/direction/driving?key=${AMapConfig.webApiKey}&origin=$originLng,$originLat&destination=$destLng,$destLat&strategy=0';
        }

        int retryCount = 0;
        bool success = false;

        while (retryCount < 2 && !success) {
          try {
            final http.Response response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
            if (response.statusCode == 200) {
              final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;

              if (data['status'] == '1' && data['route'] != null && data['route']['paths'] != null && (data['route']['paths'] as List).isNotEmpty) {
                final Map<String, dynamic> path = (data['route']['paths'] as List)[0] as Map<String, dynamic>;

                int distanceMeters = int.tryParse(path['distance'].toString()) ?? 0;
                int durationSeconds = int.tryParse(path['duration'].toString()) ?? 0; // 默认拿到的驾车/步行时间
                List<amap_base.LatLng> realRoutePoints = <amap_base.LatLng>[];

                // =========================================================
                // 🚨 1. 提取漂亮、平滑的驾车/步行轨迹线
                // =========================================================
                if (path['steps'] != null) {
                  for (final dynamic step in path['steps'] as List<dynamic>) {
                    if ((step as Map<String, dynamic>)['polyline'] != null) {
                      for (final String p in step['polyline'].toString().split(';')) {
                        final List<String> coords = p.split(',');
                        if (coords.length == 2) {
                          realRoutePoints.add(amap_base.LatLng(double.parse(coords[1]), double.parse(coords[0])));
                        }
                      }
                    }
                  }
                }

                // =========================================================
                // 🚨 2. 核心黑科技："偷"取真实公交时间 (仅在 transit 模式下触发)
                // =========================================================
                if (mode == 'transit' && transitTimeUrl.isNotEmpty) {
                  try {
                    // 发起第二次静默请求，去问高德公交要多久
                    final http.Response transitRes = await http.get(Uri.parse(transitTimeUrl)).timeout(const Duration(seconds: 5));
                    if (transitRes.statusCode == 200) {
                      final Map<String, dynamic> tData = jsonDecode(transitRes.body) as Map<String, dynamic>;
                      if (tData['status'] == '1' && tData['route'] != null && tData['route']['transits'] != null && (tData['route']['transits'] as List).isNotEmpty) {
                        // 成功拿到公交方案！
                        final Map<String, dynamic> transitOption = (tData['route']['transits'] as List)[0] as Map<String, dynamic>;
                        // 无情覆盖：用公交的真实时间替换掉刚才驾车的时间
                        durationSeconds = int.tryParse(transitOption['duration'].toString()) ?? durationSeconds;
                      }
                    }
                  } catch (e) {
                    debugPrint('获取真实公交时间超时，降级使用驾车时间: $e');
                  }
                }

                // =========================================================
                // 3. 数据渲染与回写
                // =========================================================
                if (distanceMeters > 0 || durationSeconds > 0) {
                  int durationMinutes = (durationSeconds / 60).ceil();
                  
                  // =========================================================
                  // 🚨 核心优化：公交/地铁路网的智能时间压缩算法（打七折）
                  // 消除 API 默认计算的冗长"徒步惩罚"，模拟真实世界中的骑行接驳
                  // =========================================================
                  if (mode == 'transit') {
                    // 乘以 0.7 (打七折)，并向上取整
                    durationMinutes = (durationMinutes * 0.7).ceil();
                    // 设置一个保底时间，防止距离极短时算出个位数的奇怪时间
                    if (durationMinutes < 10 && straightDistance > 1000) {
                      durationMinutes = 10;
                    }
                  }
                  
                  final String distanceText = distanceMeters > 1000
                      ? '${(distanceMeters / 1000).toStringAsFixed(1)}公里'
                      : '${distanceMeters}米';

                  String modeText = '步行';
                  if (mode == 'car') modeText = '驾车';
                  if (mode == 'transit') modeText = '公交/地铁'; // UI 上依然显示公交！

                  // 容错补齐直线
                  if (realRoutePoints.isEmpty) {
                    realRoutePoints = <amap_base.LatLng>[amap_base.LatLng(originLat, originLng), amap_base.LatLng(destLat, destLng)];
                  }

                  if (mounted) {
                    final String itemKey = _timelineItemKey(origin);
                    setState(() {
                      origin['transit'] = <String, dynamic>{
                        'mode': mode, // UI 会根据它渲染公交车 Icon
                        'distance': distanceText,
                        'text': '$modeText约$durationMinutes分钟', // 这里渲染的就是打完七折后的真实感时间！
                        'routePoints': realRoutePoints, // 这里的线依然是漂亮的驾车平滑线！
                      };
                      _timelineTransitOverride[itemKey] = Map<String, dynamic>.from(
                        origin['transit'] as Map<String, dynamic>,
                      );
                    });
                  }
                  success = true; // 宣告成功！
                } else {
                  retryCount++;
                  await Future<void>.delayed(const Duration(milliseconds: 300));
                }
              } else {
                retryCount++;
                await Future<void>.delayed(const Duration(milliseconds: 300));
              }
            } else {
              retryCount++;
            }
          } catch (e) {
            debugPrint('请求路段 $originTitle 到 $destTitle 失败: $e');
            retryCount++;
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        }

        if (!success) {
          debugPrint('路段 $originTitle 到 $destTitle 最终失败，使用直线兜底');
        }

        i = j;
      }
    }
  }

  Widget _buildMapInfoOverlay() {
    final ActivityItem? selected = _selectedActivity;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      left: 16,
      right: 16,
      bottom: selected == null ? -130 : 30,
      child: IgnorePointer(
        ignoring: selected == null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: selected == null ? 0 : 1,
          child: selected == null
              ? const SizedBox.shrink()
              : Center(child: _buildMapInfoCard(selected)),
        ),
      ),
    );
  }

  Widget _buildMapInfoCard(ActivityItem activity) {
    const String fallbackImage =
        'https://images.unsplash.com/photo-1488085061387-422e29b40080?auto=format&fit=crop&w=300&q=80';
    final String imgUrl = _selectedActivityImages.isNotEmpty
        ? _selectedActivityImages.first
        : (activity.imageUrl.trim().isNotEmpty
              ? activity.imageUrl.trim()
              : fallbackImage);
    return Container(
      height: 90,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: imgUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: imgUrl,
                    width: 66,
                    height: 66,
                    fit: BoxFit.cover,
                    errorWidget: (BuildContext c, String u, Object e) =>
                        Container(
                          width: 66,
                          height: 66,
                          color: Colors.grey.shade200,
                          child: const Icon(
                            Icons.image_not_supported,
                            color: Colors.grey,
                          ),
                        ),
                  )
                : Container(
                    width: 66,
                    height: 66,
                    color: Colors.grey.shade200,
                    child: const Icon(
                      Icons.image_not_supported,
                      color: Colors.grey,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  activity.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.schedule,
                      size: 12,
                      color: Colors.indigo.shade400,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${activity.time} · 建议 ${activity.recommendedDuration}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  activity.aiHighlight.isEmpty ? '行程亮点' : activity.aiHighlight,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                ),
              ],
            ),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              GestureDetector(
                onTap: () => setState(() => _selectedActivity = null),
                child: const Icon(Icons.close, size: 18, color: Colors.black45),
              ),
              GestureDetector(
                onTap: () => _launchNavigation(activity),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '导航',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo.shade600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 迷你版模式切换胶囊 - 放置在顶栏（完整恢复精美样式）
  Widget _buildMiniModeToggle(BuildContext context) {
    final ItineraryProvider provider = Provider.of<ItineraryProvider>(context);
    final bool isTraveling = provider.currentMode == TripMode.traveling;
    
    return Container(
      width: 160,
      height: 36,
      decoration: BoxDecoration(
        color: Colors.grey.shade100, // 浅灰底色
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Stack(
        children: <Widget>[
          // 滑动的白色高光背景
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: isTraveling ? 80 : 2,
            top: 2,
            bottom: 2,
            width: 76,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
          // 文字层
          Row(
            children: <Widget>[
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => provider.toggleTripMode(TripMode.planning),
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: !isTraveling ? FontWeight.bold : FontWeight.w500,
                        color: !isTraveling ? Colors.indigo.shade600 : Colors.grey.shade500,
                      ),
                      child: const Text('规划'),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => provider.toggleTripMode(TripMode.traveling),
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isTraveling ? FontWeight.bold : FontWeight.w500,
                        color: isTraveling ? Colors.indigo.shade600 : Colors.grey.shade500,
                      ),
                      child: const Text('行程中'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 紧凑型 Day 标题组件
  Widget _buildCompactDayHeader(int dayIndex, String dateString, Color dayColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: dayColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: dayColor.withValues(alpha: 0.3)),
            ),
            child: Text(
              'DAY ${dayIndex + 1}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: dayColor,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            dateString,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // 获取 Day 颜色（确保双模式一致）
  Color getDayColor(int dayIndex) {
    final List<Color> colors = <Color>[
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.red,
    ];
    return colors[dayIndex % colors.length];
  }

  Widget _buildSafeNetworkThumb(String rawUrl, {double height = 80}) {
    final String imgUrl = rawUrl.trim();
    if (imgUrl.isEmpty) {
      return Container(
        height: height,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported, color: Colors.grey),
      );
    }
    return CachedNetworkImage(
      imageUrl: imgUrl,
      height: height,
      fit: BoxFit.cover,
      errorWidget: (BuildContext context, String url, Object error) =>
          Container(
        height: height,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported, color: Colors.grey),
      ),
    );
  }

  /// 行程景点照片全屏查看（与手账图库共用交互，大图 contain 展示）。
  Widget _buildItineraryGalleryPageImage(String rawUrl) {
    final String u = rawUrl.trim();
    if (u.isEmpty) {
      return const Icon(Icons.image_not_supported, color: Colors.white54, size: 56);
    }
    if (u.startsWith('http://') || u.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: u,
        fit: BoxFit.contain,
        placeholder: (BuildContext context, String url) => const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white54,
            ),
          ),
        ),
        errorWidget:
            (BuildContext context, String url, Object error) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 56,
                ),
      );
    }
    if (u.startsWith('blob:')) {
      return Image.network(u, fit: BoxFit.contain);
    }
    if (kIsWeb) {
      return Image.network(u, fit: BoxFit.contain);
    }
    return Image.file(File(u), fit: BoxFit.contain);
  }

  Dismissible _buildDismissiblePrepItem({
    required _PrepTask task,
    required Widget child,
    required VoidCallback onBeforeDelete,
    required void Function(void Function()) setModalState,
    required List<_PrepTask> localTasks,
    required Map<String, bool> localDone,
    required ItineraryProvider provider,
    required _PrepModule module,
  }) {
    return Dismissible(
      key: ValueKey<String>('prep_${module.key}_${task.key}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (DismissDirection direction) async {
        final bool? ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Text('确认删除？'),
              content: Text('将删除「${task.title}」'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('删除'),
                ),
              ],
            );
          },
        );
        if (ok == true) {
          onBeforeDelete();
        }
        return ok == true;
      },
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_sweep, color: Colors.white),
      ),
      onDismissed: (DismissDirection direction) async {
        onBeforeDelete();
        setModalState(() {
          localTasks.removeWhere((_PrepTask t) => t.key == task.key);
          localDone.remove(task.key);
        });
        await provider.removePrepTask(
          moduleKey: module.key,
          taskKey: task.key,
          title: task.title,
        );
      },
      child: child,
    );
  }

  List<Widget> _buildPreparingSlivers(
    ItineraryModel model,
    ItineraryProvider provider,
    List<_DayRoute> dayRoutes,
  ) {
    if (_isEditing) {
      return _buildEditingReorderSlivers();
    }
    final Map<dynamic, dynamic> prepRoot =
        (model.planData['pre_trip_prep'] as Map?) ?? const <dynamic, dynamic>{};
    final _PrepModule bookingsModule = _PrepModule(
      key: 'bookings',
      title: '提前预定与票务 (包含证件)',
      subtitle: '门票、酒店、交通与证件材料统一核对',
      icon: Icons.event_available_outlined,
      tasks: _extractPrepTasks(
        model,
        moduleKey: 'bookings',
        hasRemoteValue: prepRoot.containsKey('bookings'),
        source:
            (((model.planData['pre_trip_prep'] as Map?)?['bookings']
                as List?) ??
            const <dynamic>[]),
        fallback: const <Map<String, String>>[
          <String, String>{'item': '往返交通票', 'tips': '建议提前 7-14 天预定'},
          <String, String>{'item': '酒店订单', 'tips': '确认可免费取消策略'},
          <String, String>{'item': '身份证/护照', 'tips': '拍照留档并检查有效期'},
        ],
      ),
    );
    final _PrepModule pitfallModule = _PrepModule(
      key: 'pitfalls',
      title: '避坑指南',
      subtitle: '景区和消费提醒',
      icon: Icons.warning_amber_rounded,
      tasks: _extractPrepTasks(
        model,
        moduleKey: 'pitfalls',
        hasRemoteValue: prepRoot.containsKey('pitfalls'),
        source:
            (((model.planData['pre_trip_prep'] as Map?)?['pitfalls']
                as List?) ??
            const <dynamic>[]),
        fallback: const <Map<String, String>>[
          <String, String>{'item': '拒绝黑车', 'tips': '优先官方打车或地铁'},
          <String, String>{'item': '门票渠道核验', 'tips': '只走官方或大平台'},
          <String, String>{'item': '消费明细留存', 'tips': '防止额外加价'},
        ],
      ),
    );
    final _PrepModule luggageModule = _PrepModule(
      key: 'luggage',
      title: '智能行李箱清单',
      subtitle: '按天气和行程自动检查随身物品',
      icon: Icons.luggage_outlined,
      tasks: _extractPrepTasks(
        model,
        moduleKey: 'luggage',
        hasRemoteValue: prepRoot.containsKey('luggage'),
        source:
            (((model.planData['pre_trip_prep'] as Map?)?['luggage'] as List?) ??
            const <dynamic>[]),
        fallback: const <Map<String, String>>[
          <String, String>{'item': '证件与复印件', 'tips': '纸质与电子版都保留'},
          <String, String>{'item': '充电器与转换头', 'tips': '按目的地插头标准准备'},
          <String, String>{'item': '常备药品', 'tips': '过敏药/肠胃药/创可贴'},
        ],
      ),
    );

    final List<_PrepModule> modules = <_PrepModule>[
      bookingsModule,
      pitfallModule,
      luggageModule,
    ];

    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            children: modules
                .map((_PrepModule module) {
                  final int doneCount = module.tasks
                      .where((_PrepTask t) => t.isDone)
                      .length;
                  final String? subtitle = module.key == 'pitfalls'
                      ? null
                      : '$doneCount / ${module.tasks.length} 项已完成';
                  return GestureDetector(
                    onTap: () => _showPrepBottomSheet(
                      context: context,
                      provider: provider,
                      module: module,
                    ),
                    child: _buildChecklistTile(
                      icon: module.icon,
                      title: module.title,
                      subtitle: subtitle,
                    ),
                  );
                })
                .toList(growable: false),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
          final _DayRoute route = dayRoutes[index];
          return Container(
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: ExpansionTile(
              title: Text(
                route.dayTitle,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text('${route.activities.length} 个行程点'),
              children: route.activities
                  .map((ActivityItem a) {
                    return ListTile(
                      title: Text(a.title),
                      subtitle: Text('${a.time} · ${a.recommendedDuration}'),
                      trailing: SizedBox(
                        width: 56,
                        height: 56,
                        child: _SafeTravelImage(imageUrl: a.imageUrl),
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          );
        }, childCount: dayRoutes.length),
      ),
    ];
  }

  Widget _buildChecklistTile({
    required IconData icon,
    required String title,
    required String? subtitle,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: Colors.indigo),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null && subtitle.trim().isNotEmpty)
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
              ],
            ),
          ),
          Icon(Icons.keyboard_arrow_right, color: Colors.grey.shade400),
        ],
      ),
    );
  }

  Future<void> _showPrepBottomSheet({
    required BuildContext context,
    required ItineraryProvider provider,
    required _PrepModule module,
  }) async {
    final Map<String, bool> localDone = <String, bool>{
      for (final _PrepTask task in module.tasks) task.key: task.isDone,
    };
    final List<_PrepTask> localTasks = List<_PrepTask>.from(module.tasks);
    final TextEditingController customController = TextEditingController();
    final ScrollController listScrollController = ScrollController();
    final FocusNode customInputFocusNode = FocusNode();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder:
              (
                BuildContext context,
                void Function(void Function()) setModalState,
              ) {
                final bool isPitfallMode = module.key == 'pitfalls';
                Future<void> submitCustomTask() async {
                  final String value = customController.text.trim();
                  if (value.isEmpty) return;
                  final String? taskId = await provider.addPrepCustomTask(
                    moduleKey: module.key,
                    title: value,
                  );
                  if (taskId == null || !mounted || !context.mounted) {
                    return;
                  }
                  final _PrepTask task = _PrepTask(
                    key: taskId,
                    title: value,
                    tips: '',
                    isDone: false,
                  );
                  setModalState(() {
                    localTasks.add(task);
                    localDone[task.key] = false;
                    customController.clear();
                  });
                  Future<void>.delayed(const Duration(milliseconds: 80), () {
                    if (!context.mounted) return;
                    if (!listScrollController.hasClients) return;
                    listScrollController.animateTo(
                      listScrollController.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  });
                }

                return Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Container(
                    height: MediaQuery.of(context).size.height * 0.75,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(28),
                        topRight: Radius.circular(28),
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        child: Column(
                          children: <Widget>[
                              Container(
                                width: 40,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade300,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  module.title,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                child: ListView.builder(
                                  controller: listScrollController,
                                  itemCount:
                                      localTasks.length +
                                      (localTasks.isEmpty ? 1 : 0),
                                  itemBuilder: (BuildContext context, int index) {
                                    if (localTasks.isEmpty && index == 0) {
                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 16,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: Colors.grey.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: <Widget>[
                                            Icon(
                                              Icons.inbox_outlined,
                                              color: Colors.grey.shade500,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '暂无事项，可在下方添加',
                                              style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }

                                    final int taskIndex = localTasks.isEmpty
                                        ? index - 1
                                        : index;
                                    final _PrepTask task =
                                        localTasks[taskIndex];
                                    final bool checked =
                                        localDone[task.key] == true;
                                    if (isPitfallMode) {
                                      return _buildDismissiblePrepItem(
                                        task: task,
                                        onBeforeDelete: () {
                                          customInputFocusNode.unfocus();
                                          FocusScope.of(context).unfocus();
                                        },
                                        setModalState: setModalState,
                                        localTasks: localTasks,
                                        localDone: localDone,
                                        provider: provider,
                                        module: module,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 16,
                                          ),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              boxShadow: <BoxShadow>[
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.04),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                              border: Border(
                                                left: BorderSide(
                                                  color: Colors.orange.shade500,
                                                  width: 4,
                                                ),
                                              ),
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    12,
                                                    10,
                                                    10,
                                                    10,
                                                  ),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: <Widget>[
                                                  Icon(
                                                    Icons.warning_amber_rounded,
                                                    color:
                                                        Colors.orange.shade600,
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: <Widget>[
                                                        Text(
                                                          task.title,
                                                          style:
                                                              const TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                fontSize: 14,
                                                              ),
                                                        ),
                                                        if (task
                                                            .tips
                                                            .isNotEmpty) ...<
                                                          Widget
                                                        >[
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            task.tips,
                                                            style: TextStyle(
                                                              color: Colors
                                                                  .grey
                                                                  .shade700,
                                                              fontSize: 12,
                                                              height: 1.4,
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }

                                    return _buildDismissiblePrepItem(
                                      task: task,
                                      onBeforeDelete: () {
                                        customInputFocusNode.unfocus();
                                        FocusScope.of(context).unfocus();
                                      },
                                      setModalState: setModalState,
                                      localTasks: localTasks,
                                      localDone: localDone,
                                      provider: provider,
                                      module: module,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            boxShadow: <BoxShadow>[
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.04,
                                                ),
                                                blurRadius: 10,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: CheckboxListTile(
                                            value: checked,
                                            onChanged: (bool? value) {
                                              final bool next = value == true;
                                              provider.togglePrepTask(
                                                task.key,
                                                next,
                                              );
                                              setModalState(() {
                                                localDone[task.key] = next;
                                              });
                                            },
                                            controlAffinity:
                                                ListTileControlAffinity.leading,
                                            title: Text(
                                              task.title,
                                              style: TextStyle(
                                                color: checked
                                                    ? Colors.grey.shade500
                                                    : Colors.grey.shade900,
                                                decoration: checked
                                                    ? TextDecoration.lineThrough
                                                    : TextDecoration.none,
                                              ),
                                            ),
                                            subtitle: task.tips.isEmpty
                                                ? null
                                                : Text(
                                                    task.tips,
                                                    style: TextStyle(
                                                      color: checked
                                                          ? Colors.grey.shade400
                                                          : Colors
                                                                .grey
                                                                .shade600,
                                                      decoration: checked
                                                          ? TextDecoration
                                                                .lineThrough
                                                          : TextDecoration.none,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              Container(
                                margin: const EdgeInsets.only(top: 16),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextField(
                                        controller: customController,
                                        focusNode: customInputFocusNode,
                                        textInputAction: TextInputAction.done,
                                        onSubmitted: (_) => submitCustomTask(),
                                        decoration: const InputDecoration(
                                          hintText: '添加新的备忘事项...',
                                          hintStyle: TextStyle(
                                            fontSize: 13,
                                            color: Colors.black38,
                                          ),
                                          border: InputBorder.none,
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      onTap: submitCustomTask,
                                      borderRadius: BorderRadius.circular(20),
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: const BoxDecoration(
                                          color: Colors.indigo,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.add,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
        );
      },
    );
  }

  List<_PrepTask> _extractPrepTasks(
    ItineraryModel model, {
    required String moduleKey,
    required bool hasRemoteValue,
    required List<dynamic> source,
    required List<Map<String, String>> fallback,
  }) {
    final List<dynamic> raw = hasRemoteValue
        ? source
        : (source.isNotEmpty ? source : fallback);
    final List<_PrepTask> tasks = <_PrepTask>[];
    for (int i = 0; i < raw.length; i++) {
      final dynamic item = raw[i];
      String title = '';
      String tips = '';
      if (item is String) {
        title = item;
      } else if (item is Map) {
        title = (item['item'] ?? item['title'] ?? '').toString();
        tips = (item['tips'] ?? item['tip'] ?? item['desc'] ?? '').toString();
      }
      if (title.trim().isEmpty) continue;
      final String key = item is Map && item['id'] != null
          ? item['id'].toString()
          : 'prep_${moduleKey}_${title.hashCode}_$i';
      tasks.add(
        _PrepTask(
          key: key,
          title: title,
          tips: tips,
          isDone: model.prepTaskDoneMap[key] == true,
        ),
      );
    }
    return tasks;
  }

  List<_DayRoute> _buildDayRoutes(ItineraryModel model) {
    final List<dynamic> rawSchedules =
        (model.planData['daily_schedules'] as List<dynamic>?) ?? <dynamic>[];
    if (rawSchedules.isNotEmpty) {
      final List<_DayRoute> parsed = <_DayRoute>[];
      for (int i = 0; i < rawSchedules.length; i++) {
        final dynamic day = rawSchedules[i];
        if (day is! Map) continue;
        final List<dynamic> activitiesRaw =
            (day['activities'] as List<dynamic>?) ?? <dynamic>[];
        int idx = 0;
        final List<ActivityItem> activities = activitiesRaw
            .whereType<Map<String, dynamic>>()
            .map((Map<String, dynamic> map) {
              idx++;
              return ActivityItem.fromJson(
                map,
                fallbackId: 'schedule_d${i + 1}_a$idx',
              );
            })
            .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
            .toList(growable: false);
        
        // 新增：按 time 升序排序，时间为空的沉底
        final RegExp timeReg = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
        activities.sort((ActivityItem a, ActivityItem b) {
          final bool validA = timeReg.hasMatch(a.time ?? '');
          final bool validB = timeReg.hasMatch(b.time ?? '');
          if (validA && validB) return (a.time ?? '').compareTo(b.time ?? '');
          if (validA) return -1;
          if (validB) return 1;
          return 0;
        });
        
        parsed.add(
          _DayRoute(
            dayTitle: (day['dayTitle'] ?? day['day_title'] ?? '第${i + 1}天')
                .toString(),
            themeColor: _parseHexColor(
              day['theme_color']?.toString() ?? '',
              _palette[i % _palette.length],
            ),
            activities: activities,
          ),
        );
      }
      return parsed.where((_DayRoute r) => r.activities.isNotEmpty).toList();
    }

    // ② 新增：读取 planData['days']（AI 生成的标准 JSON 格式）
    final List<dynamic> rawDays =
        (model.planData['days'] as List<dynamic>?) ?? <dynamic>[];
    if (rawDays.isNotEmpty) {
      final List<_DayRoute> parsed = <_DayRoute>[];
      for (int i = 0; i < rawDays.length; i++) {
        final dynamic rawDay = rawDays[i];
        if (rawDay is! Map) continue;
        final Map<String, dynamic> day = Map<String, dynamic>.from(rawDay);
        final List<dynamic> activitiesRaw =
            (day['activities'] as List<dynamic>?) ??
            (day['items'] as List<dynamic>?) ??
            <dynamic>[];
        int idx = 0;
        final List<ActivityItem> activities = activitiesRaw
            .whereType<Map<String, dynamic>>()
            .map((Map<String, dynamic> map) {
              idx++;
              return ActivityItem.fromJson(
                map,
                fallbackId: 'days_d${i + 1}_a$idx',
              );
            })
            .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
            .toList(growable: false);
        final RegExp timeReg = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
        activities.sort((ActivityItem a, ActivityItem b) {
          final bool validA = timeReg.hasMatch(a.time ?? '');
          final bool validB = timeReg.hasMatch(b.time ?? '');
          if (validA && validB) return (a.time ?? '').compareTo(b.time ?? '');
          if (validA) return -1;
          if (validB) return 1;
          return 0;
        });
        if (activities.isEmpty) continue;
        parsed.add(
          _DayRoute(
            dayTitle:
                (day['dayTitle'] ?? day['day_title'] ?? '第${i + 1}天').toString(),
            themeColor: _parseHexColor(
              day['theme_color']?.toString() ?? '',
              _palette[i % _palette.length],
            ),
            activities: activities,
          ),
        );
      }
      if (parsed.isNotEmpty) return parsed;
    }

    // ③ 原有兜底保持不变
    return List<_DayRoute>.generate(model.days.length, (int i) {
      final DayPlan day = model.days[i];
      final List<ActivityItem> sortedActivities = day.activities
          .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
          .toList(growable: false);
      
      // 新增：按 time 升序排序，时间为空的沉底
      final RegExp timeReg = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
      sortedActivities.sort((ActivityItem a, ActivityItem b) {
        final bool validA = timeReg.hasMatch(a.time ?? '');
        final bool validB = timeReg.hasMatch(b.time ?? '');
        if (validA && validB) return (a.time ?? '').compareTo(b.time ?? '');
        if (validA) return -1;
        if (validB) return 1;
        return 0;
      });
      
      return _DayRoute(
        dayTitle: day.dayTitle,
        themeColor: _palette[i % _palette.length],
        activities: sortedActivities,
      );
    });
  }

  // 31 色均匀分布色相环，覆盖最长 31 天旅行，相邻天色相差 > 25°
  static const List<Color> _palette = <Color>[
    Color(0xFF4F6DFF), // Day 1  蓝
    Color(0xFFE11D48), // Day 2  玫红
    Color(0xFF00A28A), // Day 3  青绿
    Color(0xFFF59E0B), // Day 4  琥珀
    Color(0xFF8B5CF6), // Day 5  紫
    Color(0xFF0891B2), // Day 6  青蓝
    Color(0xFFEA580C), // Day 7  橙红
    Color(0xFF16A34A), // Day 8  草绿
    Color(0xFFDB2777), // Day 9  粉红
    Color(0xFF7C3AED), // Day 10 深紫
    Color(0xFF0D9488), // Day 11 水鸭绿
    Color(0xFFD97706), // Day 12 深琥珀
    Color(0xFF7C2D12), // Day 13 砖红
    Color(0xFF1D4ED8), // Day 14 深蓝
    Color(0xFF059669), // Day 15 翠绿
    Color(0xFFC026D3), // Day 16 洋红
    Color(0xFF0369A1), // Day 17 海蓝
    Color(0xFFB45309), // Day 18 棕橙
    Color(0xFF4D7C0F), // Day 19 橄榄绿
    Color(0xFF9D174D), // Day 20 深玫红
    Color(0xFF1E40AF), // Day 21 皇室蓝
    Color(0xFF065F46), // Day 22 森林绿
    Color(0xFFB91C1C), // Day 23 深红
    Color(0xFF6D28D9), // Day 24 靛紫
    Color(0xFF0F766E), // Day 25 深青绿
    Color(0xFFC2410C), // Day 26 深橙
    Color(0xFF166534), // Day 27 深绿
    Color(0xFF831843), // Day 28 酒红
    Color(0xFF1E3A8A), // Day 29 午夜蓝
    Color(0xFF713F12), // Day 30 深棕
    Color(0xFF4C1D95), // Day 31 深紫罗兰
  ];

  Color _parseHexColor(String raw, Color fallback) {
    final String value = raw.trim().replaceAll('#', '');
    if (value.isEmpty) return fallback;
    final String normalized = value.length == 6 ? 'FF$value' : value;
    final int? parsed = int.tryParse(normalized, radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }

  List<Widget> _buildTravelingSlivers(
    ItineraryModel model,
    ItineraryProvider provider,
    List<_DayRoute> dayRoutes,
  ) {
    if (_isEditing) {
      return _buildEditingReorderSlivers();
    }
    final int keep = model.hashCode ^ provider.hashCode;
    if (keep == -1) {
      return <Widget>[];
    }
    final List<Map<String, dynamic>> timelineData = _buildTravelingTimelineData(
      model,
    );
    _timelineItemByKey
      ..clear()
      ..addEntries(
        timelineData.map(
          (Map<String, dynamic> item) => MapEntry<String, Map<String, dynamic>>(
            _timelineItemKey(item),
            item,
          ),
        ),
      );
    final int maxDay = timelineData.fold<int>(0, (
      int previous,
      Map<String, dynamic> item,
    ) {
      final int day = (item['day'] as num?)?.toInt() ?? 1;
      return day > previous ? day : previous;
    });
    final int effectiveSelectedDay = _selectedDayIndex > maxDay
        ? 0
        : _selectedDayIndex;
    final List<Map<String, dynamic>> filteredTimeline =
        effectiveSelectedDay == 0
        ? timelineData
        : timelineData
              .where(
                (Map<String, dynamic> item) =>
                    item['day'] == effectiveSelectedDay,
              )
              .toList(growable: false);
    return <Widget>[
      SliverList(
        key: ValueKey<int>(_contentVersion),
        delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
          final Map<String, dynamic> item = filteredTimeline[index];
          final int currentDayIndex =
              (item['dayIndex'] as num?)?.toInt() ??
              (((item['day'] as num?)?.toInt() ?? 1) - 1);
          final int currentActivityIndex =
              (item['activityIndex'] as num?)?.toInt() ?? 0;
          final bool isLast = index == filteredTimeline.length - 1;
          final Map<String, dynamic>? transit =
              item['transit'] as Map<String, dynamic>?;
          final int currentDay = (item['day'] as num?)?.toInt() ?? 1;
          final int? previousDay = index > 0
              ? (filteredTimeline[index - 1]['day'] as num?)?.toInt()
              : null;
          final bool showDayHeader =
              effectiveSelectedDay == 0 &&
              (index == 0 || previousDay == null || previousDay != currentDay);
          return Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (showDayHeader) ...<Widget>[
                  SizedBox(height: index == 0 ? 2 : 14),
                  _buildCompactDayHeader(
                    currentDay - 1,
                    _formatTripDate(model.startDate, currentDay),
                    getDayColor(currentDay - 1),
                  ),
                  const SizedBox(height: 10),
                ],
                _buildTimelineItemCard(
                  item: item,
                  dayIndex: currentDayIndex,
                  activityIndex: currentActivityIndex,
                  isFirst: index == 0,
                  isLast: isLast && transit == null,
                  dayOrder: _dayOrderAt(filteredTimeline, index),
                  itineraryModel: model,
                ),
                if (!isLast && transit != null) ...<Widget>[
                  const SizedBox(height: 2),
                  _buildTransitCard(
                    transit: transit,
                    origin: item,
                    destination: filteredTimeline[index + 1],
                  ),
                ],
              ],
            ),
          );
        }, childCount: filteredTimeline.length),
      ),
    ];
  }

  String _formatTripDate(DateTime tripStartDate, int dayNumber) {
    final DateTime date = DateTime(
      tripStartDate.year,
      tripStartDate.month,
      tripStartDate.day,
    ).add(Duration(days: dayNumber - 1));
    const List<String> weekdays = <String>[
      '周一',
      '周二',
      '周三',
      '周四',
      '周五',
      '周六',
      '周日',
    ];
    final String weekday = weekdays[date.weekday - 1];
    return '${date.month}/${date.day} $weekday';
  }

  List<Map<String, dynamic>> _buildTravelingTimelineData(ItineraryModel model) {
    final List<dynamic> rawDays =
        (model.planData['days'] as List<dynamic>?) ??
        (model.planData['daily_schedules'] as List<dynamic>?) ??
        <dynamic>[];
    if (rawDays.isNotEmpty) {
      final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
      for (int dayIndex = 0; dayIndex < rawDays.length; dayIndex++) {
        final Object? rawDay = rawDays[dayIndex];
        if (rawDay is! Map) continue;
        final Map<String, dynamic> day = Map<String, dynamic>.from(rawDay);
        final int dayNumber =
            (day['day_index'] as num?)?.toInt() ??
            (day['day'] as num?)?.toInt() ??
            dayIndex + 1;
        final List<dynamic> activities =
            (day['activities'] as List<dynamic>?) ??
            (day['items'] as List<dynamic>?) ??
            <dynamic>[];
        for (
          int activityIndex = 0;
          activityIndex < activities.length;
          activityIndex++
        ) {
          final Object? rawActivity = activities[activityIndex];
          if (rawActivity is! Map) continue;
          final Map<String, dynamic> activity = Map<String, dynamic>.from(
            rawActivity,
          );
          final String activityId =
              (activity['id']?.toString().trim().isNotEmpty ?? false)
              ? activity['id'].toString()
              : 'd${dayNumber}_a${activityIndex + 1}';
          final Map<String, dynamic> item = <String, dynamic>{
            'id': result.length + 1,
            'activityId': activityId,
            'day': dayNumber,
            'dayIndex': dayIndex,
            'activityIndex': activityIndex,
            'scheduledTime': _stringValue(activity['time'], ''),
            'title': _stringValue(activity['title'], '未命名活动'),
            'openTime': _stringValue(
              activity['openTime'] ?? activity['open_time'],
              '时间未知',
            ),
            'duration': _formatDuration(
              activity['recommended_duration'] ??
                  activity['recommendedDuration'],
            ),
            'tag': _stringValue(activity['tag'], '行程亮点'),
            'images': _timelineImages(activity),
            'strategy': _stringValue(activity['strategy'], ''),
            'description': _stringValue(
              activity['description'] ?? activity['note'],
              '',
            ),
            'note': _stringValue(activity['note'] ?? activity['description'], ''),
            'lat': _toNullableDouble(activity['lat'] ?? activity['latitude']),
            'lng': _toNullableDouble(
              activity['lng'] ?? activity['lon'] ?? activity['longitude'],
            ),
            'isArrived': model.arrivedActivityIds.contains(activityId),
            'transit': _timelineTransit(activity, activityIndex, activities),
          };
          final String key = _timelineItemKey(item);
          final Map<String, dynamic>? overrideTransit =
              _timelineTransitOverride[key];
          if (overrideTransit != null && item['transit'] is Map) {
            item['transit'] = <String, dynamic>{
              ...(item['transit'] as Map<String, dynamic>),
              ...overrideTransit,
            };
          }
          result.add(item);
        }
      }
      if (result.isNotEmpty) return result;
    }

    if (model.days.isEmpty) return _mockTimeline;
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (int dayIndex = 0; dayIndex < model.days.length; dayIndex++) {
      final DayPlan day = model.days[dayIndex];
      for (
        int activityIndex = 0;
        activityIndex < day.activities.length;
        activityIndex++
      ) {
        final ActivityItem activity = day.activities[activityIndex];
        final Map<String, dynamic> item = <String, dynamic>{
          'id': result.length + 1,
          'activityId': activity.id,
          'day': dayIndex + 1,
          'dayIndex': dayIndex,
          'activityIndex': activityIndex,
          'scheduledTime': activity.time,
          'title': activity.title,
          'openTime': activity.time.isEmpty ? '时间未知' : '${activity.time} 开放',
          'duration': _formatDuration(activity.recommendedDuration),
          'tag': activity.aiHighlight.isEmpty ? '行程亮点' : activity.aiHighlight,
          'images': <String>[
            activity.imageUrl,
            'https://images.unsplash.com/photo-1469474968028-56623f02e42e?w=400',
          ],
          'strategy': activity.aiHighlight,
          'description': '',
          'note': '',
          'lat': activity.lat,
          'lng': activity.lng,
          'isArrived': model.arrivedActivityIds.contains(activity.id),
          'transit': activityIndex == day.activities.length - 1
              ? null
              : <String, dynamic>{
                  'mode': _transportModeFromText(activity.transportInfo),
                  'text': activity.transportInfo,
                  'distance': '',
                },
        };
        final String key = _timelineItemKey(item);
        final Map<String, dynamic>? overrideTransit =
            _timelineTransitOverride[key];
        if (overrideTransit != null && item['transit'] is Map) {
          item['transit'] = <String, dynamic>{
            ...(item['transit'] as Map<String, dynamic>),
            ...overrideTransit,
          };
        }
        result.add(item);
      }
    }
    return result.isEmpty ? _mockTimeline : result;
  }

  String _stringValue(Object? value, String fallback) {
    final String text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String _formatDuration(Object? value) {
    final String text = _stringValue(value, '时长未知');
    if (text == '时长未知' || text.startsWith('预计游玩')) return text;
    return '预计游玩 $text';
  }

  double? _toNullableDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  List<String> _timelineImages(Map<String, dynamic> activity) {
    final Object? rawImages = activity['images'];
    
    // 🐛 DEBUG: 打印原始数据
    debugPrint('🔍 _timelineImages 处理: ${activity['title']} - rawImages类型=${rawImages.runtimeType}');
    
    if (rawImages is List && rawImages.isNotEmpty) {
      // ✅ 移除 .take(2) 限制，返回所有照片
      final List<String> result = rawImages
          .map((Object? item) => item.toString().trim())
          .where((String url) => url.isNotEmpty)
          .toList();
      debugPrint('  ✅ 返回 ${result.length} 张照片');
      return result;
    }
    final String imageUrl = _stringValue(
      activity['imageUrl'] ?? activity['image_url'],
      '',
    );
    // 如果没有 images 数组，返回 imageUrl（如果存在）
    if (imageUrl.isNotEmpty) {
      debugPrint('  ✅ 返回 imageUrl: $imageUrl');
      return <String>[imageUrl];
    }
    // 如果都没有，返回空数组
    debugPrint('  ⚠️ 无照片数据');
    return <String>[];
  }

  Map<String, dynamic>? _timelineTransit(
    Map<String, dynamic> activity,
    int activityIndex,
    List<dynamic> activities,
  ) {
    final Object? rawTransit = activity['transit'];
    if (rawTransit is Map) return Map<String, dynamic>.from(rawTransit);
    if (activityIndex == activities.length - 1) return null;
    final String text = _stringValue(
      activity['transport_info'] ?? activity['transportInfo'],
      '步行约10分钟',
    );
    return <String, dynamic>{
      'mode': _transportModeFromText(text),
      'text': text,
      'distance': '',
    };
  }

  String _transportModeFromText(String transportInfo) {
    if (transportInfo.contains('打车') ||
        transportInfo.contains('驾车') ||
        transportInfo.contains('car')) {
      return 'car';
    }
    return 'walk';
  }

  // 统一读取计划中的 daily_schedules，确保颜色来源唯一。
  Map<String, dynamic> _getPlanDayDataAt(ItineraryModel model, int dayIndex) {
    if (dayIndex < 0) return <String, dynamic>{};
    final List<dynamic> rawSchedules =
        (model.planData['daily_schedules'] as List<dynamic>?) ?? <dynamic>[];
    if (dayIndex >= rawSchedules.length) return <String, dynamic>{};
    final dynamic dayData = rawSchedules[dayIndex];
    if (dayData is Map<String, dynamic>) return dayData;
    if (dayData is Map) {
      return dayData.map(
        (dynamic key, dynamic value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      );
    }
    return <String, dynamic>{};
  }

  // 🚨 核心修复 1：统一的颜色解析中心
  Color _getUnifiedDayColor(int dayIndex, Map<String, dynamic> dayData) {
    // 1. 优先使用大模型生成的当天主题色 (theme_color)
    if (dayData['theme_color'] != null &&
        dayData['theme_color'].toString().trim().isNotEmpty) {
      try {
        final String hexColor = dayData['theme_color']
            .toString()
            .replaceAll('#', '');
        // 如果是 6 位 Hex，前面补 FF 代表不透明度
        final int colorValue = int.parse(
          hexColor.length == 6 ? 'FF$hexColor' : hexColor,
          radix: 16,
        );
        return Color(colorValue);
      } catch (e) {
        debugPrint('解析主题色失败，触发兜底: $e');
      }
    }

    // 2. 无 theme_color 时，从色相环均匀取色，彻底杜绝撞色
    // 黄金角 137.508° 分割，任意相邻天数色相差均 > 30°
    const double goldenAngle = 137.508;
    // 起始色相错开 210°，让 Day 1 落在蓝色区，视觉更舒适
    final double hue = (210.0 + dayIndex * goldenAngle) % 360;
    // 饱和度和亮度固定，保证颜色鲜明统一
    return HSVColor.fromAHSV(1.0, hue, 0.80, 0.88).toColor();
  }

  Widget _buildTimelineItemCard({
    required Map<String, dynamic> item,
    required int dayIndex,
    required int activityIndex,
    required bool isFirst,
    required bool isLast,
    required int dayOrder,
    required ItineraryModel itineraryModel,
  }) {
    return KeyedSubtree(
      key: _timelineItemGlobalKey(item),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildTimelineRail(
            isFirst: isFirst,
            isLast: isLast,
            dayOrder: dayOrder,
          ),
          Expanded(
            child: _buildMainCard(
              item,
              dayIndex,
              activityIndex,
              itineraryModel: itineraryModel,
            ),
          ),
        ],
      ),
    );
  }

  int _dayOrderAt(List<Map<String, dynamic>> items, int index) {
    final int day = (items[index]['day'] as num?)?.toInt() ?? 1;
    int order = 0;
    for (int i = 0; i <= index; i++) {
      final int currentDay = (items[i]['day'] as num?)?.toInt() ?? 1;
      if (currentDay == day) {
        order++;
      }
    }
    return order;
  }

  int _globalDayOrderAt(List<Map<String, dynamic>> items, int index) {
    final int day = (items[index]['day'] as num?)?.toInt() ?? 1;
    int order = 0;
    for (int i = 0; i <= index; i++) {
      final int currentDay = (items[i]['day'] as num?)?.toInt() ?? 1;
      if (currentDay == day) order++;
    }
    return order;
  }

  String _timelineItemKey(Map<String, dynamic> item) {
    final String id = item['activityId']?.toString() ?? item['id'].toString();
    return 'timeline_${item['day'] ?? 1}_$id';
  }

  GlobalKey _timelineItemGlobalKey(Map<String, dynamic> item) {
    final String key = _timelineItemKey(item);
    return _timelineItemKeys.putIfAbsent(key, GlobalKey.new);
  }

  bool _isTimelineItemArrived(Map<String, dynamic> item) {
    final String key = _timelineItemKey(item);
    return _timelineArrivedOverride[key] ??
        ((item['isArrived'] as bool?) ?? false);
  }

  Future<void> _focusTimelineMapItem(
    Map<String, dynamic> item,
    int index,
  ) async {
    final double? lat = (item['lat'] as num?)?.toDouble();
    final double? lng = (item['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    _selectedActivityImages =
        ((item['images'] as List<dynamic>?) ?? <dynamic>[])
            .map((dynamic e) => e.toString())
            .where((String e) => e.trim().isNotEmpty)
            .toList(growable: false);
    final ActivityItem activity = _activityFromTimelineItem(item);
    setState(() => _selectedActivity = activity);
    _aMapController?.moveCamera(
      amap.CameraUpdate.newLatLngZoom(amap_base.LatLng(lat, lng), 14),
    );
    _googleController?.animateCamera(
      gmap.CameraUpdate.newLatLngZoom(gmap.LatLng(lat, lng), 14),
    );
    await _scrollToActivity(item);
  }

  Future<void> _scrollToActivity(Map<String, dynamic> activity) async {
    final BuildContext? itemContext = _timelineItemGlobalKey(activity).currentContext;
    if (itemContext == null) return;
    await Scrollable.ensureVisible(
      itemContext,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  ActivityItem _activityFromTimelineItem(Map<String, dynamic> item) {
    final List<dynamic> images =
        (item['images'] as List<dynamic>?) ?? <dynamic>[];
    return ActivityItem(
      id: _timelineItemKey(item),
      time: item['scheduledTime']?.toString() ?? '',
      title: item['title']?.toString() ?? '未命名活动',
      type: 'scenic',
      lat: (item['lat'] as num?)?.toDouble() ?? 0,
      lng: (item['lng'] as num?)?.toDouble() ?? 0,
      imageUrl: images.isNotEmpty ? images.first.toString() : '',
      transportInfo: ((item['transit'] as Map?)?['text'] ?? '').toString(),
      recommendedDuration: item['duration']?.toString() ?? '',
      aiHighlight: item['tag']?.toString() ?? '',
    );
  }

  void _syncMapWithVisibleTimelineItem() {
    if (_mapSource != _MapSource.amap || _timelineItemByKey.isEmpty) return;
    Map<String, dynamic>? target;
    double bestDistance = double.infinity;
    for (final Map<String, dynamic> item in _timelineItemByKey.values) {
      final BuildContext? itemContext =
          _timelineItemKeys[_timelineItemKey(item)]?.currentContext;
      if (itemContext == null) continue;
      final RenderObject? renderObject = itemContext.findRenderObject();
      if (renderObject is! RenderBox) continue;
      final Offset offset = renderObject.localToGlobal(Offset.zero);
      final double distance =
          (offset.dy - MediaQuery.of(context).size.height * 0.48).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        target = item;
      }
    }
    if (target == null) return;
    final String key = _timelineItemKey(target);
    if (_focusedTimelineKey == key) return;
    _focusedTimelineKey = key;
    final double? lat = (target['lat'] as num?)?.toDouble();
    final double? lng = (target['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    _aMapController?.moveCamera(
      amap.CameraUpdate.newLatLngZoom(amap_base.LatLng(lat, lng), 14),
    );
  }

  Widget _buildTimelineRail({
    required bool isFirst,
    required bool isLast,
    required int dayOrder,
  }) {
    return SizedBox(
      width: 34,
      child: Column(
        children: <Widget>[
          Container(
            width: 2,
            height: 16,
            color: isFirst ? Colors.transparent : const Color(0xFFE2E8F0),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.indigo.shade500,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              '$dayOrder',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Container(
            width: 2,
            height: isLast ? 22 : 190,
            color: isLast ? Colors.transparent : const Color(0xFFE2E8F0),
          ),
        ],
      ),
    );
  }

  Widget _buildMainCard(
    Map<String, dynamic> item,
    int dayIndex,
    int activityIndex, {
    required ItineraryModel itineraryModel,
  }) {
    final bool isArrived = _isTimelineItemArrived(item);
    final String notePreview =
        (item['description'] ?? item['note'] ?? '').toString().trim();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 预览态（行程中）：仅编辑随行备注，不进入全局编辑模式
        // ignore: discarded_futures
        _showTravelNoteBottomSheet(item, itineraryModel);
      },
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: isArrived ? 0.65 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade100, width: 1.5),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    "${item['scheduledTime']} · ${item['title']}",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Colors.indigo.shade800,
                    ),
                    softWrap: true,
                  ),
                ),
                const SizedBox(width: 8),
                TweenAnimationBuilder<double>(
                  key: ValueKey<bool>(isArrived),
                  tween: Tween<double>(begin: 0.92, end: 1),
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOutBack,
                  builder: (BuildContext context, double scale, Widget? child) {
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      setState(() {
                        item['isArrived'] = !isArrived;
                        _timelineArrivedOverride[_timelineItemKey(item)] =
                            !isArrived;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isArrived ? Colors.green.shade50 : Colors.white,
                        border: Border.all(
                          color: isArrived
                              ? Colors.green.shade200
                              : Colors.grey.shade300,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            isArrived
                                ? Icons.check
                                : Icons.location_on_outlined,
                            size: 12,
                            color: isArrived
                                ? Colors.green.shade600
                                : Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isArrived ? "已到达" : "标记到达",
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: isArrived
                                  ? Colors.green.shade600
                                  : Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "${item['openTime'] ?? '时间未知'} | ${item['duration'] ?? '时长未知'}",
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            if (item['tag'] != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  item['tag'],
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.orange.shade700,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            _buildPhotoGallery(item, dayIndex, activityIndex),
            if (item['strategy'] != null &&
                item['strategy'].toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  item['strategy'],
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
              ),
            if (notePreview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade100),
                  ),
                  child: Text(
                    notePreview,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade700,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildTransitCard({
    required Map<String, dynamic> transit,
    required Map<String, dynamic> origin,
    required Map<String, dynamic> destination,
  }) {
    final double? lat = (destination['lat'] as num?)?.toDouble();
    final double? lng = (destination['lng'] as num?)?.toDouble();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 34,
          child: Center(
            child: Container(
              width: 2,
              height: 44,
              color: const Color(0xFFE2E8F0),
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(left: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  transit['mode'] == 'transit'
                      ? const Text(
                          '🚇',
                          style: TextStyle(fontSize: 14),
                        )
                      : Icon(
                          transit['mode'] == 'car'
                              ? Icons.directions_car
                              : Icons.directions_walk,
                          size: 14,
                          color: Colors.grey.shade600,
                        ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      "${transit['text']} · ${transit['distance']}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(width: 1, height: 12, color: Colors.grey.shade300),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: (lat != null && lng != null)
                        ? () => _launchNavigationTo(
                              origin: origin,
                              destination: destination,
                              transit: transit,
                            )
                        : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Row(
                      children: const <Widget>[
                        Icon(
                          Icons.map_outlined,
                          size: 14,
                          color: Colors.indigo,
                        ),
                        SizedBox(width: 4),
                        Text(
                          "路线",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.indigo,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoGallery(Map<String, dynamic> activity, int dayIdx, int actIdx) {
    // 1️⃣ 提取并清洗 images 数组
    final List<dynamic> rawImages = (activity['images'] as List<dynamic>?) ?? <dynamic>[];
    final List<String> images = rawImages
        .map((dynamic e) => e.toString().trim())
        .where((String e) => e.isNotEmpty)
        .toList(growable: true);

    // 2️⃣ 【关键】抢救首图：如果 images 为空，检查 imageUrl
    final String legacyImageUrl = (activity['imageUrl'] ?? activity['image_url'] ?? '').toString().trim();
    if (images.isEmpty && legacyImageUrl.isNotEmpty) {
      images.add(legacyImageUrl);
    } else if (images.isNotEmpty && legacyImageUrl.isNotEmpty && !images.contains(legacyImageUrl)) {
      // 如果 images 有数据但不包含 imageUrl，补充到开头
      images.insert(0, legacyImageUrl);
    }

    // 🐛 DEBUG: 打印画廊接收到的照片数量
    debugPrint('📸 画廊渲染 Day${dayIdx + 1} Activity${actIdx + 1}: ${activity['title']} - 照片数=${images.length}');
    for (int i = 0; i < images.length; i++) {
      debugPrint('  [$i] ${images[i].substring(0, images[i].length > 60 ? 60 : images[i].length)}...');
    }

    final bool isThisUploading = _uploadingDayIdx == dayIdx && _uploadingActIdx == actIdx;

    // 3️⃣ 【红线 3】彻底重写横向画廊：固定高度 + 原生 ListView
    return SizedBox(
      height: 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: images.length + 1, // 图片数量 + 1 个添加按钮
        itemBuilder: (BuildContext context, int index) {
          if (index < images.length) {
            // 渲染图片项（带删除按钮）
            return _buildImageItem(
              allUrls: images,
              imageIndex: index,
              imageUrl: images[index],
              onDelete: () =>
                  _handleDeletePhoto(dayIdx, actIdx, images[index], activity),
            );
          }
          // 渲染添加按钮
          return _buildAddPhotoButton(
            isUploading: isThisUploading,
            onTap: () => _pickAndUploadImage(
              dayIdx,
              actIdx,
              activity['title']?.toString() ?? '未命名景点',
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleDeletePhoto(
    int dayIdx,
    int actIdx,
    String targetUrl,
    Map<String, dynamic> activity,
  ) async {
    final bool? confirm = await showCupertinoDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => CupertinoAlertDialog(
        title: const Text('删除照片'),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('确定要删除这张照片吗？操作不可撤销。'),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ItineraryProvider provider = context.read<ItineraryProvider>();
    final String itineraryId =
        provider.activeItinerary?.remoteId ??
        provider.currentItinerary?.remoteId ??
        '';
    final bool ok = await provider.deleteAndSyncPhoto(
      dayIndex: dayIdx,
      activityIndex: actIdx,
      targetUrl: targetUrl,
      itineraryId: itineraryId,
      activityTitle: activity['title']?.toString() ?? '',
    );
    if (!ok) {
      debugPrint('删除失败: $targetUrl');
    }
  }

  Widget _buildImageItem({
    required List<String> allUrls,
    required int imageIndex,
    required String imageUrl,
    required VoidCallback onDelete,
  }) {
    return Container(
      width: 100,
      margin: const EdgeInsets.only(right: 10),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showFullScreenPhotoGallery(
                context,
                allUrls,
                imageIndex,
                imageBuilder: _buildItineraryGalleryPageImage,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildSafeNetworkThumb(imageUrl, height: 100),
              ),
            ),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddPhotoButton({
    required bool isUploading,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: isUploading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: Colors.grey.shade400,
            radius: 12,
          ),
          child: Center(
            child: isUploading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.indigo.shade500,
                    ),
                  )
                : Icon(
                    Icons.add_a_photo_outlined,
                    size: 22,
                    color: Colors.indigo.shade500,
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndUploadImage(
    int dayIdx,
    int actIdx,
    String activityTitle,
  ) async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('💡 提示：在相册中长按图片即可进行多选'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    List<XFile> picked = <XFile>[];
    try {
      picked = await _imagePicker.pickMultiImage(
        imageQuality: 88,
        maxWidth: 1800,
      );
    } catch (e, st) {
      debugPrint('pickMultiImage failed: $e\n$st');
      try {
        final XFile? one = await _imagePicker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 88,
          maxWidth: 1800,
        );
        if (one != null) picked = <XFile>[one];
      } catch (e2, st2) {
        debugPrint('pickImage fallback failed: $e2\n$st2');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法打开相册，请稍后重试')),
          );
        }
        return;
      }
    }

    if (picked.isEmpty || !mounted) return;

    final List<String> paths = picked
        .map((XFile x) => x.path.trim())
        .where((String p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未能读取所选图片')),
        );
      }
      return;
    }

    setState(() {
      _uploadingDayIdx = dayIdx;
      _uploadingActIdx = actIdx;
    });

    final ItineraryProvider provider = context.read<ItineraryProvider>();
    final String itineraryId =
        provider.activeItinerary?.remoteId ??
        provider.currentItinerary?.remoteId ??
        '';

    int okCount = 0;
    for (final String filePath in paths) {
      if (!mounted) break;
      final bool ok = await provider.uploadAndSyncPhoto(
        dayIndex: dayIdx,
        activityIndex: actIdx,
        filePath: filePath,
        itineraryId: itineraryId,
        activityTitle: activityTitle,
      );
      if (ok) okCount++;
    }

    if (!mounted) return;
    setState(() {
      _uploadingDayIdx = null;
      _uploadingActIdx = null;
    });

    if (okCount == 0) {
      debugPrint('上传失败: $activityTitle');
      return;
    }
    if (mounted && paths.length > 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已上传 $okCount 张图片')),
      );
    }
  }

  Future<void> _launchNavigation(ActivityItem target) async {
    final Uri amapUri = Uri.parse(
      'androidamap://route?sourceApplication=gonow&dlat=${target.lat}&dlon=${target.lng}&dname=${Uri.encodeComponent(target.title)}&dev=0&t=0',
    );
    final Uri googleUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${target.lat},${target.lng}&travelmode=driving',
    );
    if (_mapSource == _MapSource.amap && await canLaunchUrl(amapUri)) {
      await launchUrl(amapUri, mode: LaunchMode.externalApplication);
      return;
    }
    await launchUrl(googleUri, mode: LaunchMode.externalApplication);
  }

  Future<void> _launchNavigationTo({
    required Map<String, dynamic> origin,
    required Map<String, dynamic> destination,
    required Map<String, dynamic> transit,
  }) async {
    final double? dLat = (destination['lat'] as num?)?.toDouble();
    final double? dLng = (destination['lng'] as num?)?.toDouble();
    final String dName = destination['title']?.toString() ?? '目的地';
    if (dLat == null || dLng == null) return;

    final double? sLat = (origin['lat'] as num?)?.toDouble();
    final double? sLng = (origin['lng'] as num?)?.toDouble();
    final String sName = origin['title']?.toString() ?? '起点';
    final bool hasStart =
        sLat != null &&
        sLng != null &&
        sLat != 0 &&
        sLng != 0;

    final String mode = transit['mode']?.toString() ?? 'car';
    final int androidMode = mode == 'walk' ? 2 : 0;
    final String webMode = mode == 'walk' ? 'walk' : 'car';

    final String encS = Uri.encodeComponent(sName);
    final String encD = Uri.encodeComponent(dName);

    final Uri androidRouteUri = Uri.parse(
      hasStart
          ? 'androidamap://route?sourceApplication=gonow&slat=$sLat&slon=$sLng&sname=$encS&dlat=$dLat&dlon=$dLng&dname=$encD&dev=0&t=$androidMode'
          : 'androidamap://route?sourceApplication=gonow&dlat=$dLat&dlon=$dLng&dname=$encD&dev=0&t=$androidMode',
    );
    final Uri iosRouteUri = Uri.parse(
      hasStart
          ? 'iosamap://path?sourceApplication=gonow&slat=$sLat&slon=$sLng&sname=$encS&dlat=$dLat&dlon=$dLng&dname=$encD&dev=0&t=$androidMode'
          : 'iosamap://path?sourceApplication=gonow&dlat=$dLat&dlon=$dLng&dname=$encD&dev=0&t=$androidMode',
    );
    final Uri webUri = Uri.parse(
      hasStart
          ? 'https://uri.amap.com/navigation?from=$sLng,$sLat,$encS&to=$dLng,$dLat,$encD&mode=$webMode&callnative=1&src=gonow'
          : 'https://uri.amap.com/navigation?to=$dLng,$dLat,$encD&mode=$webMode&callnative=1&src=gonow',
    );
    final Uri appleMapUri = Uri.parse(
      hasStart
          ? 'http://maps.apple.com/?saddr=$sLat,$sLng&daddr=$dLat,$dLng&dirflg=d'
          : 'http://maps.apple.com/?daddr=$dLat,$dLng&dirflg=d',
    );

    try {
      if (!kIsWeb && Platform.isAndroid && await canLaunchUrl(androidRouteUri)) {
        await launchUrl(androidRouteUri, mode: LaunchMode.externalApplication);
      } else if (!kIsWeb &&
          Platform.isIOS &&
          await canLaunchUrl(iosRouteUri)) {
        await launchUrl(iosRouteUri, mode: LaunchMode.externalApplication);
      } else if (!kIsWeb && await canLaunchUrl(appleMapUri)) {
        await launchUrl(appleMapUri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('导航拉起失败: $e');
    }
  }

  ActivityItem? _nextPendingActivity(ItineraryModel model) {
    for (final DayPlan d in model.days) {
      for (final ActivityItem a in d.activities) {
        if (!model.arrivedActivityIds.contains(a.id)) return a;
      }
    }
    return null;
  }
}

/// 插入新行程点：Cupertino 滑动时钟 + 高德静默纠偏坐标
class _InsertNodeBottomSheet extends StatefulWidget {
  const _InsertNodeBottomSheet({
    required this.geocodeCity,
    required this.resolveLocation,
    required this.onConfirm,
  });

  final String geocodeCity;
  final Future<gmap.LatLng?> Function(String title, String city)
      resolveLocation;
  final void Function(String title, String time, double lat, double lng)
      onConfirm;

  @override
  State<_InsertNodeBottomSheet> createState() => _InsertNodeBottomSheetState();
}

class _InsertNodeBottomSheetState extends State<_InsertNodeBottomSheet> {
  static final RegExp _hhmmRegExp =
      RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');

  late final TextEditingController _titleController;
  late final TextEditingController _timeController;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _timeController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _timeController.dispose();
    super.dispose();
  }

  void _showCupertinoTimePicker() {
    FocusScope.of(context).unfocus();

    DateTime tempTime = DateTime(2026, 1, 1, 9, 0);
    final String t = _timeController.text.trim();
    if (t.isNotEmpty) {
      try {
        final List<String> parts = t.split(':');
        if (parts.length >= 2) {
          tempTime = DateTime(
            2026,
            1,
            1,
            int.parse(parts[0]).clamp(0, 23),
            int.parse(parts[1]).clamp(0, 59),
          );
        }
      } catch (_) {}
    }

    showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return Container(
          height: 260,
          color: Colors.white,
          child: Column(
            children: <Widget>[
              Container(
                color: Colors.grey.shade50,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    TextButton(
                      onPressed: () {
                        setState(() => _timeController.clear());
                        Navigator.of(sheetContext).pop();
                      },
                      child: const Text(
                        '清除',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _timeController.text =
                              '${tempTime.hour.toString().padLeft(2, '0')}:'
                              '${tempTime.minute.toString().padLeft(2, '0')}';
                        });
                        Navigator.of(sheetContext).pop();
                      },
                      child: Text(
                        '确定',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  initialDateTime: tempTime,
                  onDateTimeChanged: (DateTime newDate) {
                    tempTime = newDate;
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final double bottomInset = mq.viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(28),
                    topRight: Radius.circular(28),
                  ),
                ),
                child: const Center(
                  child: Text(
                    '插入新记录点',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: TextField(
                            controller: _titleController,
                            autofocus: true,
                            decoration: const InputDecoration(
                              hintText: '新行程点 (例如：老北京炸酱面)',
                              hintStyle: TextStyle(
                                color: Colors.black38,
                                fontSize: 14,
                              ),
                              border: InputBorder.none,
                            ),
                            onChanged: (_) {
                              if (_errorMessage != null) {
                                setState(() => _errorMessage = null);
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: _showCupertinoTimePicker,
                          child: AbsorbPointer(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: _errorMessage != null
                                      ? Colors.red.shade300
                                      : Colors.grey.shade200,
                                ),
                              ),
                              child: TextField(
                                controller: _timeController,
                                decoration: const InputDecoration(
                                  hintText: '大概时间 (选填，点击滑动选择)',
                                  hintStyle: TextStyle(
                                    color: Colors.black38,
                                    fontSize: 14,
                                  ),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8, left: 4),
                            child: Row(
                              children: <Widget>[
                                const Icon(
                                  Icons.error_outline,
                                  color: Colors.redAccent,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    _errorMessage!,
                                    style: const TextStyle(
                                      color: Colors.redAccent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 24),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: TextButton(
                                onPressed: () {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  Navigator.pop(context);
                                },
                                child: const Text(
                                  '取消',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.indigo,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: () async {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  final String titleInput =
                                      _titleController.text.trim();
                                  if (titleInput.isEmpty) {
                                    setState(() => _errorMessage = '请填写行程点名称');
                                    return;
                                  }
                                  final String timeInput =
                                      _timeController.text.trim();
                                  if (timeInput.isNotEmpty &&
                                      !_hhmmRegExp.hasMatch(timeInput)) {
                                    setState(
                                      () => _errorMessage =
                                          '时间格式有误，请输入如 14:30',
                                    );
                                    return;
                                  }
                                  gmap.LatLng? realCoords;
                                  try {
                                    realCoords = await widget.resolveLocation(
                                      titleInput,
                                      widget.geocodeCity,
                                    );
                                  } catch (_) {}
                                  final double lat = realCoords?.latitude ?? 0.0;
                                  final double lng = realCoords?.longitude ?? 0.0;
                                  if (!context.mounted) {
                                    return;
                                  }
                                  widget.onConfirm(titleInput, timeInput, lat, lng);
                                  Navigator.pop(context);
                                },
                                child: const Text(
                                  '确定',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteFetchResult {
  const _RouteFetchResult({
    required this.points,
    this.distanceMeters = 0,
    this.durationSeconds = 0,
    this.routeMode = '',
  });

  final List<amap_base.LatLng> points;
  final int distanceMeters;
  final int durationSeconds;
  final String routeMode;
}

class _VisibleActivity {
  const _VisibleActivity({
    required this.key,
    required this.dayIndex,
    required this.order,
    required this.activity,
    required this.color,
  });

  final String key;
  final int dayIndex;
  final int order;
  final ActivityItem activity;
  final Color color;
}

class _PrepModule {
  const _PrepModule({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tasks,
  });

  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<_PrepTask> tasks;
}

class _PrepTask {
  const _PrepTask({
    required this.key,
    required this.title,
    required this.tips,
    required this.isDone,
  });

  final String key;
  final String title;
  final String tips;
  final bool isDone;
}

class _DayRoute {
  const _DayRoute({
    required this.dayTitle,
    required this.themeColor,
    required this.activities,
  });

  final String dayTitle;
  final Color themeColor;
  final List<ActivityItem> activities;
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final Path path = Path()..addRRect(rrect);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const double dash = 6;
    const double gap = 4;
    for (final ui.PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double next = distance + dash;
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}

class _SafeTravelImage extends StatelessWidget {
  const _SafeTravelImage({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final String imgUrl = imageUrl.trim();
    final Uri? uri = Uri.tryParse(imgUrl);
    final bool hasValidHttpHost =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (!hasValidHttpHost) {
      return _buildImageFallback();
    }
    return CachedNetworkImage(
      imageUrl: imgUrl,
      fit: BoxFit.cover,
      placeholder: (BuildContext context, String url) =>
          Container(color: const Color(0xFFE7EDF8)),
      errorWidget: (BuildContext context, String url, Object error) =>
          _buildImageFallback(),
    );
  }

  Widget _buildImageFallback() {
    return Container(
      color: const Color(0xFFE7EDF8),
      alignment: Alignment.center,
      child: Icon(
        Icons.photo_outlined,
        color: Colors.grey.shade400,
        size: 28,
      ),
    );
  }
}