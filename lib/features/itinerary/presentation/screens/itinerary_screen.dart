import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'package:amap_flutter_base/amap_flutter_base.dart' as amap_base;
import 'package:amap_flutter_map/amap_flutter_map.dart' as amap;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gonow/core/constants/amap_config.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmap;
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
  _MapSource _mapSource = _MapSource.amap;
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
        final ItineraryModel? model =
            provider.activeItinerary ?? provider.currentItinerary;
        if (model == null) {
          return Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '暂无行程，请先在 AI 定制页生成并导入。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        }

        final TripState state = provider.getTripState();
        final List<_DayRoute> dayRoutes = _buildDayRoutes(model);
        if (_selectedDayIndex > dayRoutes.length) {
          _selectedDayIndex = 0;
        }
        _maybeInitMarkers(model, dayRoutes);

        return Scaffold(
          backgroundColor: Colors.white,
          // NestedScrollView 将地图固定在 header SliverArea；
          // 当用户点击地图 Marker 触发列表跳转时，只有 body 内的列表
          // 发生内部滚动，地图 header 不受影响，彻底消灭"地图被顶飞"Bug。
          body: NestedScrollView(
            controller: _scrollController,
            headerSliverBuilder: (BuildContext ctx, bool innerBoxIsScrolled) =>
                <Widget>[
                  SliverToBoxAdapter(
                    child: _buildMapSection(
                      model: model,
                      state: state,
                      dayRoutes: dayRoutes,
                    ),
                  ),
                ],
            body: NotificationListener<ScrollUpdateNotification>(
              // 用事件通知代替 addListener，驱动"列表滚→地图动镜"
              onNotification: (ScrollUpdateNotification _) {
                _syncMapWithVisibleTimelineItem();
                return false;
              },
              child: CustomScrollView(
                slivers: <Widget>[
                  if (state == TripState.preparing)
                    ..._buildPreparingSlivers(model, provider, dayRoutes)
                  else
                    ..._buildTravelingSlivers(model, provider, dayRoutes),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMapSection({
    required ItineraryModel model,
    required TripState state,
    required List<_DayRoute> dayRoutes,
  }) {
    final List<ActivityItem> allActivities = dayRoutes
        .expand((_DayRoute route) => route.activities)
        .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
        .toList(growable: false);
    final ActivityItem? next = _nextPendingActivity(model);
    final Color selectedTabColor = _selectedDayIndex == 0
        ? Colors.black87
        : dayRoutes[_selectedDayIndex - 1].themeColor;

    final Widget map = _isMapLoading
        ? Container(
            color: const Color(0xFFF4F6FB),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(strokeWidth: 2.4),
          )
        : (_mapSource == _MapSource.amap
              ? _buildAmap(
                  model: model,
                  state: state,
                  dayRoutes: dayRoutes,
                  allActivities: allActivities,
                  next: next,
                )
              : _buildGoogleMap(
                  model: model,
                  state: state,
                  dayRoutes: dayRoutes,
                  allActivities: allActivities,
                  next: next,
                ));

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${model.title} · ${state == TripState.preparing ? "行前准备" : "行中伴游"}',
                    style: TextStyle(
                      color: Colors.grey.shade800,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DropdownButton<_MapSource>(
                  value: _mapSource,
                  underline: const SizedBox.shrink(),
                  items: const <DropdownMenuItem<_MapSource>>[
                    DropdownMenuItem(
                      value: _MapSource.amap,
                      child: Text('高德地图'),
                    ),
                    DropdownMenuItem(
                      value: _MapSource.google,
                      child: Text('Google Maps'),
                    ),
                  ],
                  onChanged: (_MapSource? value) {
                    if (value == null) return;
                    setState(() => _mapSource = value);
                    _focusSelectedRoute(dayRoutes);
                  },
                ),
              ],
            ),
          ),
          SizedBox(height: 260, child: map),
          if (state == TripState.preparing)
            Container(
              color: Colors.white,
              child: DefaultTabController(
                key: ValueKey<String>(
                  'prepare-tabs-${_selectedDayIndex}_${dayRoutes.length}',
                ),
                initialIndex: _selectedDayIndex,
                length: dayRoutes.length + 1,
                child: TabBar(
                  isScrollable: true,
                  labelColor: selectedTabColor,
                  indicatorColor: selectedTabColor,
                  unselectedLabelColor: Colors.grey.shade600,
                  onTap: (int index) {
                    _selectDayFilter(index, dayRoutes: dayRoutes);
                  },
                  tabs: <Widget>[
                    const Tab(text: '全览'),
                    for (int i = 0; i < dayRoutes.length; i++)
                      Tab(text: '第${i + 1}天'),
                  ],
                ),
              ),
            ),
        ],
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
        : _collectVisibleActivities(dayRoutes, state);
    final Set<gmap.Marker> markers = <gmap.Marker>{};
    if (state == TripState.traveling) {
      final List<Map<String, dynamic>> points = _timelineMapItems(model, state);
      for (int i = 0; i < points.length; i++) {
        final Map<String, dynamic> point = points[i];
        final String timelineKey = _timelineItemKey(point);
        final String cacheKey =
            '${timelineKey}_${_isTimelineItemArrived(point) ? 'arrived' : 'active'}';
        final gmap.BitmapDescriptor? customIcon = _googleMarkerCache[cacheKey];
        if (customIcon == null) continue;
        markers.add(
          gmap.Marker(
            markerId: gmap.MarkerId(cacheKey),
            position: gmap.LatLng(
              (point['lat'] as num).toDouble(),
              (point['lng'] as num).toDouble(),
            ),
            icon: customIcon,
            infoWindow: gmap.InfoWindow(
              title: point['title'] as String? ?? '',
              snippet: point['duration'] as String? ?? '',
            ),
            onTap: () => _focusTimelineMapItem(point, i),
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
            if (state == TripState.preparing) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _focusSelectedRoute(dayRoutes);
              });
            }
          },
          markers: markers,
          polylines: lines,
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
        : _collectVisibleActivities(dayRoutes, state);
    final Set<amap.Marker> markers = <amap.Marker>{};
    if (state == TripState.traveling) {
      final List<Map<String, dynamic>> points = _timelineMapItems(model, state);
      for (int i = 0; i < points.length; i++) {
        final Map<String, dynamic> point = points[i];
        final String timelineKey = _timelineItemKey(point);
        final String cacheKey =
            '${timelineKey}_${_isTimelineItemArrived(point) ? 'arrived' : 'active'}';
        final amap.BitmapDescriptor? customIcon = _amapMarkerCache[cacheKey];
        if (customIcon == null) continue;
        markers.add(
          amap.Marker(
            position: amap_base.LatLng(
              (point['lat'] as num).toDouble(),
              (point['lng'] as num).toDouble(),
            ),
            icon: customIcon,
            infoWindowEnable: false,
            onTap: (String markerId) => _focusTimelineMapItem(point, i),
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
            if (state == TripState.preparing) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _focusSelectedRoute(dayRoutes);
              });
            }
          },
          markers: markers,
          polylines: polylines,
          myLocationStyleOptions: state == TripState.traveling
              ? amap.MyLocationStyleOptions(true)
              : null,
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
        for (int i = 0; i < activities.length - 1; i++) {
          final Map<String, dynamic> origin = activities[i];
          final Map<String, dynamic> dest = activities[i + 1];
          final List<amap_base.LatLng> routePoints = _routePointsFromTransit(
            origin,
            dest,
          );
          if (routePoints.length < 2) continue;
          lines.add(
            amap.Polyline(points: routePoints, color: Colors.white, width: 14),
          );
          lines.add(
            amap.Polyline(
              points: routePoints,
              color: _getRouteColor(entry.key),
              width: 9.2,
            ),
          );
          lines.add(
            amap.Polyline(
              points: routePoints,
              color: _getRouteColor(entry.key),
              width: 9.2,
              customTexture: _amapArrowTextureByDay[entry.key],
            ),
          );
        }
      }
    } else if (dayRoutes.isNotEmpty) {
      final Iterable<MapEntry<int, _DayRoute>> visibleRoutes =
          _selectedDayIndex == 0
          ? dayRoutes.asMap().entries
          : dayRoutes.asMap().entries.where(
              (MapEntry<int, _DayRoute> entry) =>
                  entry.key + 1 == _selectedDayIndex,
            );
      for (final MapEntry<int, _DayRoute> entry in visibleRoutes) {
        final List<amap_base.LatLng> points = entry.value.activities
            .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
            .map((ActivityItem a) => amap_base.LatLng(a.lat, a.lng))
            .toList(growable: false);
        addRouteSegments(
          points,
          _getRouteColor(entry.key + 1),
          day: entry.key + 1,
        );
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
          color: _getRouteColor(_selectedDayIndex),
          width: 9.2,
        ),
      );
      lines.add(
        amap.Polyline(
          points: segPoints,
          color: _getRouteColor(_selectedDayIndex),
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
      for (int i = 0; i < route.activities.length; i++) {
        final ActivityItem activity = route.activities[i];
        if (activity.lat == 0 || activity.lng == 0) continue;
        result.add(
          _VisibleActivity(
            key: 'd${dayIndex + 1}_m${i + 1}_${activity.id}',
            dayIndex: dayIndex,
            order: i + 1,
            activity: activity,
            color: route.themeColor,
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
      buffer.write(
        'd$d:${route.themeColor.toARGB32()}:${route.activities.length};',
      );
      for (final ActivityItem activity in route.activities) {
        buffer.write('${activity.id}:${activity.lat},${activity.lng}|');
      }
    }
    for (final Map<String, dynamic> item in _buildTravelingTimelineData(
      model,
    )) {
      buffer.write(
        't:${_timelineItemKey(item)}:${item['day']}:${item['lat']},${item['lng']}:${_isTimelineItemArrived(item)}|',
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
      final Color markerColor = _getRouteColor(day);
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

  void _selectDayFilter(int index, {required List<_DayRoute> dayRoutes}) {
    setState(() {
      _selectedDayIndex = index;
      _selectedActivity = null;
      _focusedTimelineKey = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusSelectedRoute(dayRoutes);
      final BuildContext? topContext = _timelineListTopKey.currentContext;
      if (topContext != null) {
        Scrollable.ensureVisible(
          topContext,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: 0,
        );
      }
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

    // ② 行前（preparing）模式：按 DayRoute 内部顺序预取
    for (final _DayRoute route in dayRoutes) {
      for (int i = 0; i < route.activities.length - 1; i++) {
        final ActivityItem a = route.activities[i];
        final ActivityItem b = route.activities[i + 1];
        if (a.lat == 0 || a.lng == 0 || b.lat == 0 || b.lng == 0) continue;
        await _fetchRoute(
          amap_base.LatLng(a.lat, a.lng),
          amap_base.LatLng(b.lat, b.lng),
          _transportModeFromText(a.transportInfo),
        );
        if (!mounted) return;
        setState(() {});
      }
    }
  }

  // 全量同步：遍历所有相邻景点段，逐段请求高德并回写 transit。
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

    for (final List<Map<String, dynamic>> activities in planDays.values) {
      for (int i = 0; i < activities.length - 1; i++) {
        final Map<String, dynamic> origin = activities[i];
        final Map<String, dynamic> dest = activities[i + 1];
        final String originTitle = origin['title']?.toString() ?? '起点';
        final String destTitle = dest['title']?.toString() ?? '终点';
        final double? olat = (origin['lat'] as num?)?.toDouble();
        final double? olng = (origin['lng'] as num?)?.toDouble();
        final double? dlat = (dest['lat'] as num?)?.toDouble();
        final double? dlng = (dest['lng'] as num?)?.toDouble();
        if (olat == null || olng == null || dlat == null || dlng == null) {
          continue;
        }

        _RouteFetchResult result;
        try {
          result = await _fetchRoute(
            amap_base.LatLng(olat, olng),
            amap_base.LatLng(dlat, dlng),
            (origin['transit'] as Map<String, dynamic>?)?['mode']?.toString(),
          );
        } catch (e) {
          debugPrint('请求路段 $originTitle 到 $destTitle 失败: $e');
          continue;
        }
        if (!mounted) return;

        final int distanceMeters = result.distanceMeters > 0
            ? result.distanceMeters
            : Geolocator.distanceBetween(olat, olng, dlat, dlng).round();
        final int durationSeconds = result.durationSeconds > 0
            ? result.durationSeconds
            : (distanceMeters / (distanceMeters > 2000 ? 8.3 : 1.2)).round();
        final int durationMinutes = (durationSeconds / 60).ceil();
        final String distanceText = distanceMeters > 1000
            ? '${(distanceMeters / 1000).toStringAsFixed(1)}公里'
            : '$distanceMeters米';
        final String mode = distanceMeters > 2000 ? 'car' : 'walk';
        final String modeText = mode == 'car' ? '驾车' : '步行';
        final String itemKey = _timelineItemKey(origin);

        setState(() {
          origin['transit'] = <String, dynamic>{
            'mode': mode,
            'distance': distanceText,
            'text': '$modeText约$durationMinutes分钟',
            'routePoints': result.points,
          };
          // 核心写入：确保真实轨迹坐标绑定到 origin.transit.routePoints
          origin['transit']['routePoints'] = result.points;
          _timelineTransitOverride[itemKey] = Map<String, dynamic>.from(
            origin['transit'] as Map<String, dynamic>,
          );
        });
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
                        child: _SafeTravelImage(
                          imageUrl: a.imageUrl,
                          cityWatermark: model.title,
                        ),
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
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height * 0.78,
                    child: Container(
                      color: Colors.grey.shade50,
                      child: SafeArea(
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
                  ),
                );
              },
        );
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      customInputFocusNode.dispose();
      customController.dispose();
      listScrollController.dispose();
    });
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

    return List<_DayRoute>.generate(model.days.length, (int i) {
      final DayPlan day = model.days[i];
      return _DayRoute(
        dayTitle: day.dayTitle,
        themeColor: _palette[i % _palette.length],
        activities: day.activities
            .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
            .toList(growable: false),
      );
    });
  }

  static const List<Color> _palette = <Color>[
    Color(0xFF4F6DFF),
    Color(0xFF00A28A),
    Color(0xFFF59E0B),
    Color(0xFFE11D48),
    Color(0xFF8B5CF6),
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
    final Color selectedDayColor = _getRouteColor(effectiveSelectedDay);
    return <Widget>[
      SliverToBoxAdapter(
        child: KeyedSubtree(
          key: _timelineListTopKey,
          child: Container(
            height: 44,
            margin: const EdgeInsets.only(bottom: 16, top: 8),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: maxDay + 1,
              itemBuilder: (BuildContext context, int index) {
                final bool isSelected = effectiveSelectedDay == index;
                final String label = index == 0 ? "全览" : "Day $index";
                return GestureDetector(
                  onTap: () => _selectDayFilter(index, dayRoutes: dayRoutes),
                  child: Container(
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? selectedDayColor
                          : Colors.grey.shade100,
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
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
          final Map<String, dynamic> item = filteredTimeline[index];
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
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'Day $currentDay · ${_formatTripDate(model.startDate, currentDay)}',
                      style: TextStyle(
                        color: Colors.indigo.shade700,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                _buildTimelineItemCard(
                  item: item,
                  isFirst: index == 0,
                  isLast: isLast && transit == null,
                  dayOrder: _dayOrderAt(filteredTimeline, index),
                ),
                if (!isLast && transit != null) ...<Widget>[
                  const SizedBox(height: 2),
                  _buildTransitCard(
                    transit: transit,
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
            'scheduledTime': _stringValue(activity['time'], '09:00'),
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
    if (rawImages is List && rawImages.isNotEmpty) {
      return rawImages.map((Object? item) => item.toString()).take(2).toList();
    }
    final String imageUrl = _stringValue(
      activity['imageUrl'] ?? activity['image_url'],
      '',
    );
    return <String>[
      imageUrl,
      'https://images.unsplash.com/photo-1469474968028-56623f02e42e?w=400',
    ];
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

  Color _routeColorForDay(int day) {
    if (day <= 0) return Colors.indigo.shade600;
    final List<Color> palette = <Color>[
      Colors.indigo.shade600,
      Colors.teal.shade600,
      Colors.deepOrange.shade500,
      Colors.purple.shade500,
      Colors.blue.shade600,
    ];
    return palette[(day - 1) % palette.length];
  }

  Color _getRouteColor(int dayIndex) => _routeColorForDay(dayIndex);

  Widget _buildTimelineItemCard({
    required Map<String, dynamic> item,
    required bool isFirst,
    required bool isLast,
    required int dayOrder,
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
          Expanded(child: _buildMainCard(item)),
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
    final BuildContext? context = _timelineItemGlobalKey(item).currentContext;
    if (context != null) {
      await Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    }
  }

  ActivityItem _activityFromTimelineItem(Map<String, dynamic> item) {
    final List<dynamic> images =
        (item['images'] as List<dynamic>?) ?? <dynamic>[];
    return ActivityItem(
      id: _timelineItemKey(item),
      time: item['scheduledTime']?.toString() ?? '09:00',
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

  Widget _buildMainCard(Map<String, dynamic> item) {
    final bool isArrived = _isTimelineItemArrived(item);

    return AnimatedOpacity(
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
                        _markerCachePlanKey = '__dirty__';
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
            if (item['images'] != null && (item['images'] as List).length >= 2)
              Row(
                children: <Widget>[
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildSafeNetworkThumb(
                        item['images'][0].toString(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildSafeNetworkThumb(
                        item['images'][1].toString(),
                      ),
                    ),
                  ),
                ],
              ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildTransitCard({
    required Map<String, dynamic> transit,
    required Map<String, dynamic> destination,
  }) {
    final double? lat = (destination['lat'] as num?)?.toDouble();
    final double? lng = (destination['lng'] as num?)?.toDouble();
    final String name = destination['title']?.toString() ?? '目的地';
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
                  Icon(
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
                            lat: lat,
                            lng: lng,
                            name: name,
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
    required double lat,
    required double lng,
    required String name,
  }) async {
    final Uri amapUri = Uri.parse(
      'androidamap://navi?sourceApplication=GoNow&lat=$lat&lon=$lng&dev=0&style=2',
    );
    final Uri appleMapUri = Uri.parse(
      'http://maps.apple.com/?daddr=$lat,$lng&dirflg=d',
    );
    final Uri webUri = Uri.parse(
      'https://uri.amap.com/navigation?to=$lng,$lat,${Uri.encodeComponent(name)}&mode=car',
    );
    try {
      if (await canLaunchUrl(amapUri)) {
        await launchUrl(amapUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(appleMapUri)) {
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

class _SafeTravelImage extends StatelessWidget {
  const _SafeTravelImage({required this.imageUrl, required this.cityWatermark});

  final String imageUrl;
  final String cityWatermark;

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
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0A2A57), Color(0xFF1E4B88)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        cityWatermark.isEmpty ? 'TRAVEL' : cityWatermark,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 26,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}
