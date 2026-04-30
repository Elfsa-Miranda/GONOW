import 'dart:async';
import 'dart:ui' as ui;

import 'package:amap_flutter_base/amap_flutter_base.dart' as amap_base;
import 'package:amap_flutter_map/amap_flutter_map.dart' as amap;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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
  gmap.GoogleMapController? _googleController;
  amap.AMapController? _aMapController;
  late final AnimationController _pulseController;

  int _selectedDayIndex = 0; // 0=全览, 1..N=第N天
  ActivityItem? _selectedActivity;
  bool _isMapLoading = true;
  String _markerCachePlanKey = '__pending__';

  final Map<String, gmap.BitmapDescriptor> _googleMarkerCache =
      <String, gmap.BitmapDescriptor>{};
  final Map<String, amap.BitmapDescriptor> _amapMarkerCache =
      <String, amap.BitmapDescriptor>{};

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _initLocation();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
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
        _maybeInitMarkers(dayRoutes);

        return Scaffold(
          backgroundColor: Colors.white,
          body: CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _buildMapSection(
                  model: model,
                  state: state,
                  dayRoutes: dayRoutes,
                ),
              ),
              if (state == TripState.preparing)
                ..._buildPreparingSlivers(model, provider, dayRoutes)
              else
                ..._buildTravelingSlivers(model, provider),
              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
            ],
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
                initialIndex: _selectedDayIndex,
                length: dayRoutes.length + 1,
                child: TabBar(
                  isScrollable: true,
                  labelColor: selectedTabColor,
                  indicatorColor: selectedTabColor,
                  unselectedLabelColor: Colors.grey.shade600,
                  onTap: (int index) {
                    setState(() => _selectedDayIndex = index);
                    _focusSelectedRoute(dayRoutes);
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
    final List<_VisibleActivity> visible = _collectVisibleActivities(
      dayRoutes,
      state,
    );
    final Set<gmap.Marker> markers = <gmap.Marker>{};
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

    final Set<gmap.Polyline> lines = _buildGooglePolylines(
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
    required List<_DayRoute> dayRoutes,
    required TripState state,
    required ActivityItem? next,
  }) {
    final Set<gmap.Polyline> lines = <gmap.Polyline>{};
    if (state == TripState.preparing) {
      for (int dayIndex = 0; dayIndex < dayRoutes.length; dayIndex++) {
        if (_selectedDayIndex != 0 && _selectedDayIndex != dayIndex + 1) {
          continue;
        }
        final _DayRoute route = dayRoutes[dayIndex];
        if (route.activities.length < 2) continue;
        final List<gmap.LatLng> points = route.activities
            .map((ActivityItem a) => gmap.LatLng(a.lat, a.lng))
            .toList(growable: false);
        lines.add(
          gmap.Polyline(
            polylineId: gmap.PolylineId('border_$dayIndex'),
            points: points,
            color: Colors.white,
            width: 10,
            zIndex: 1,
          ),
        );
        lines.add(
          gmap.Polyline(
            polylineId: gmap.PolylineId('core_$dayIndex'),
            points: points,
            color: route.themeColor,
            width: 6,
            zIndex: 2,
          ),
        );
      }
    } else if (next != null && _currentPosition != null) {
      lines.add(
        gmap.Polyline(
          polylineId: const gmap.PolylineId('travel_border'),
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
          polylineId: const gmap.PolylineId('travel_core'),
          points: <gmap.LatLng>[
            gmap.LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            gmap.LatLng(next.lat, next.lng),
          ],
          color: Colors.blueAccent,
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
    final List<_VisibleActivity> visible = _collectVisibleActivities(
      dayRoutes,
      state,
    );
    final Set<amap.Marker> markers = <amap.Marker>{};
    for (final _VisibleActivity va in visible) {
      final amap.BitmapDescriptor? customIcon = _amapMarkerCache[va.key];
      if (customIcon == null) continue;
      markers.add(
        amap.Marker(
          position: amap_base.LatLng(va.activity.lat, va.activity.lng),
          icon: customIcon,
          infoWindow: amap.InfoWindow(
            title: va.activity.title,
            snippet:
                '${va.activity.recommendedDuration} · ${va.activity.aiHighlight}',
          ),
          onTap: (String markerId) {
            setState(() => _selectedActivity = va.activity);
            _focusOnActivity(va.activity);
          },
        ),
      );
    }

    final Set<amap.Polyline> polylines = _buildAmapPolylines(
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
            androidKey: '请替换为你的Android高德Key',
            iosKey: '请替换为你的iOS高德Key',
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
    required List<_DayRoute> dayRoutes,
    required TripState state,
    required ActivityItem? next,
  }) {
    final Set<amap.Polyline> lines = <amap.Polyline>{};
    if (state == TripState.preparing) {
      for (int dayIndex = 0; dayIndex < dayRoutes.length; dayIndex++) {
        if (_selectedDayIndex != 0 && _selectedDayIndex != dayIndex + 1) {
          continue;
        }
        final _DayRoute route = dayRoutes[dayIndex];
        if (route.activities.length < 2) continue;
        final List<amap_base.LatLng> points = route.activities
            .map((ActivityItem a) => amap_base.LatLng(a.lat, a.lng))
            .toList(growable: false);
        lines.add(
          amap.Polyline(points: points, color: Colors.white, width: 10),
        );
        lines.add(
          amap.Polyline(points: points, color: route.themeColor, width: 6),
        );
      }
    } else if (next != null && _currentPosition != null) {
      lines.add(
        amap.Polyline(
          points: <amap_base.LatLng>[
            amap_base.LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            amap_base.LatLng(next.lat, next.lng),
          ],
          color: Colors.white,
          width: 10,
        ),
      );
      lines.add(
        amap.Polyline(
          points: <amap_base.LatLng>[
            amap_base.LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            amap_base.LatLng(next.lat, next.lng),
          ],
          color: Colors.blueAccent,
          width: 6,
        ),
      );
    }
    return lines;
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

  String _buildMarkerPlanKey(List<_DayRoute> dayRoutes) {
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
    return buffer.toString();
  }

  void _maybeInitMarkers(List<_DayRoute> dayRoutes) {
    final String nextKey = _buildMarkerPlanKey(dayRoutes);
    if (nextKey == _markerCachePlanKey) return;
    _markerCachePlanKey = nextKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initMarkers(dayRoutes);
    });
  }

  Future<void> _initMarkers(List<_DayRoute> dayRoutes) async {
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
    for (final _VisibleActivity va in allVisible) {
      try {
        final Uint8List bytes = await _createCustomMarkerBytes(
          va.order,
          va.color,
        );
        if (!mounted) return;
        _googleMarkerCache[va.key] = gmap.BitmapDescriptor.bytes(bytes);
        _amapMarkerCache[va.key] = amap.BitmapDescriptor.fromBytes(bytes);
      } catch (_) {
        // ignore failed marker icon and continue
      }
    }
    if (!mounted) return;
    setState(() {
      _isMapLoading = false;
    });
  }

  Future<Uint8List> _createCustomMarkerBytes(int number, Color bgColor) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    const double size = 100;

    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, borderPaint);

    final Paint bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 8, bgPaint);

    final TextPainter painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: number.toString(),
        style: const TextStyle(
          fontSize: 45,
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

  Widget _buildMapInfoOverlay() {
    final ActivityItem? selected = _selectedActivity;
    return IgnorePointer(
      ignoring: selected == null,
      child: AnimatedPositioned(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        left: 16,
        right: 16,
        bottom: selected == null ? -130 : 30,
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
            child: CachedNetworkImage(
              imageUrl: activity.imageUrl,
              width: 66,
              height: 66,
              fit: BoxFit.cover,
              errorWidget: (BuildContext c, String u, Object e) => Container(
                width: 66,
                height: 66,
                color: Colors.grey.shade200,
                child: const Icon(Icons.image, color: Colors.grey),
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
                  activity.aiHighlight.isEmpty
                      ? 'AI 推荐打卡点'
                      : activity.aiHighlight,
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

  Dismissible _buildDismissiblePrepItem({
    required _PrepTask task,
    required Widget child,
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
                  if (taskId == null || !mounted) {
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
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (listScrollController.hasClients) {
                      listScrollController.animateTo(
                        listScrollController.position.maxScrollExtent,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                      );
                    }
                  });
                }

                return Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Container(
                    color: Colors.grey.shade50,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
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
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 16,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(12),
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
                                  final _PrepTask task = localTasks[taskIndex];
                                  final bool checked =
                                      localDone[task.key] == true;
                                  if (isPitfallMode) {
                                    return _buildDismissiblePrepItem(
                                      task: task,
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
                                            border: Border(
                                              left: BorderSide(
                                                color: Colors.orange.shade500,
                                                width: 4,
                                              ),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
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
                                                  color: Colors.orange.shade600,
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
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w700,
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
                                                        : Colors.grey.shade600,
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
    customController.dispose();
    listScrollController.dispose();
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
  ) {
    final List<_TimelineNode> nodes = _flatten(model);
    final String? currentId = _currentActivityId(model, nodes);
    return <Widget>[
      SliverList(
        delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
          final _TimelineNode node = nodes[index];
          final bool arrived = model.arrivedActivityIds.contains(
            node.activity.id,
          );
          final bool isCurrent = node.activity.id == currentId && !arrived;
          return Column(
            children: <Widget>[
              _buildTimelineCard(
                model: model,
                node: node,
                arrived: arrived,
                isCurrent: isCurrent,
                onArrived: () => provider.markActivityArrived(node.activity.id),
              ),
              if (index < nodes.length - 1)
                _buildTransportStrip(
                  nodes[index].activity.transportInfo,
                  nodes[index + 1].activity,
                ),
            ],
          );
        }, childCount: nodes.length),
      ),
    ];
  }

  Widget _buildTimelineCard({
    required ItineraryModel model,
    required _TimelineNode node,
    required bool arrived,
    required bool isCurrent,
    required VoidCallback onArrived,
  }) {
    final ActivityItem activity = node.activity;
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (BuildContext context, Widget? child) {
        final double pulse = 1 + (_pulseController.value * 0.04);
        return Transform.scale(
          scale: isCurrent ? pulse : 1,
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: arrived ? Colors.grey.shade100 : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isCurrent ? Colors.blueAccent : Colors.grey.shade200,
                width: isCurrent ? 1.6 : 1,
              ),
              boxShadow: isCurrent
                  ? <BoxShadow>[
                      BoxShadow(
                        color: Colors.blueAccent.withValues(alpha: 0.25),
                        blurRadius: 18,
                        spreadRadius: 2,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${activity.time} · ${activity.title}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: arrived ? Colors.grey : Colors.black87,
                        ),
                      ),
                    ),
                    if (arrived)
                      const Chip(label: Text('✅ 已到达'))
                    else
                      TextButton(
                        onPressed: onArrived,
                        child: const Text('🚩 我已到达'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 170,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _SafeTravelImage(
                      imageUrl: activity.imageUrl,
                      cityWatermark: model.title,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _tag(activity.recommendedDuration),
                    _tag(activity.aiHighlight),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTransportStrip(String transportInfo, ActivityItem next) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '🚗 $transportInfo',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          OutlinedButton(
            onPressed: () => _launchNavigation(next),
            child: const Text('一键导航'),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF3FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF3E5ED8),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
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

  ActivityItem? _nextPendingActivity(ItineraryModel model) {
    for (final DayPlan d in model.days) {
      for (final ActivityItem a in d.activities) {
        if (!model.arrivedActivityIds.contains(a.id)) return a;
      }
    }
    return null;
  }

  String? _currentActivityId(ItineraryModel model, List<_TimelineNode> nodes) {
    if (model.days.isEmpty || nodes.isEmpty) return null;
    final int targetDay = DateTime.now()
        .difference(
          DateTime(
            model.startDate.year,
            model.startDate.month,
            model.startDate.day,
          ),
        )
        .inDays
        .clamp(0, model.days.length - 1);
    final List<_TimelineNode> todayNodes = nodes
        .where((_TimelineNode node) => node.dayIndex == targetDay)
        .toList(growable: false);
    final DateTime now = DateTime.now();
    for (final _TimelineNode node in todayNodes) {
      if (model.arrivedActivityIds.contains(node.activity.id)) continue;
      final DateTime? slot = _parseTime(node.activity.time, now);
      if (slot == null) return node.activity.id;
      final Duration delta = now.difference(slot).abs();
      if (delta.inMinutes <= 100) return node.activity.id;
    }
    return _nextPendingActivity(model)?.id;
  }

  DateTime? _parseTime(String raw, DateTime base) {
    final List<String> parts = raw.split(':');
    if (parts.length != 2) return null;
    final int? h = int.tryParse(parts[0]);
    final int? m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return DateTime(base.year, base.month, base.day, h, m);
  }

  List<_TimelineNode> _flatten(ItineraryModel model) {
    final List<_TimelineNode> nodes = <_TimelineNode>[];
    for (int d = 0; d < model.days.length; d++) {
      final DayPlan day = model.days[d];
      for (int i = 0; i < day.activities.length; i++) {
        nodes.add(
          _TimelineNode(
            dayIndex: d,
            activityIndex: i,
            activity: day.activities[i],
          ),
        );
      }
    }
    return nodes;
  }
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

class _TimelineNode {
  const _TimelineNode({
    required this.dayIndex,
    required this.activityIndex,
    required this.activity,
  });

  final int dayIndex;
  final int activityIndex;
  final ActivityItem activity;
}

class _SafeTravelImage extends StatelessWidget {
  const _SafeTravelImage({required this.imageUrl, required this.cityWatermark});

  final String imageUrl;
  final String cityWatermark;

  @override
  Widget build(BuildContext context) {
    const String fallbackUrl =
        'https://images.unsplash.com/photo-1488085061387-422e29b40080?auto=format&fit=crop&w=1200&q=80';
    return CachedNetworkImage(
      imageUrl: imageUrl.trim().isEmpty ? fallbackUrl : imageUrl,
      fit: BoxFit.cover,
      placeholder: (BuildContext context, String url) =>
          Container(color: const Color(0xFFE7EDF8)),
      errorWidget: (BuildContext context, String url, Object error) =>
          CachedNetworkImage(
            imageUrl: fallbackUrl,
            fit: BoxFit.cover,
            placeholder: (BuildContext context, String url) =>
                Container(color: const Color(0xFFE7EDF8)),
            errorWidget: (BuildContext context, String url, Object error) =>
                Container(
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
                ),
          ),
    );
  }
}
