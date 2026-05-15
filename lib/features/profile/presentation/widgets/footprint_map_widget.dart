import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'; // 用于 compute
import 'package:syncfusion_flutter_maps/maps.dart';
import 'package:gonow/core/data/city_to_province_map.dart';

// 顶层函数供 compute 使用：返回简单类型避免 isolate 私有类问题
List<List<dynamic>> _buildMapDataIsolate(Map<String, dynamic> args) {
  final features = args['features'] as List<dynamic>;
  final visitedSet = Set<String>.from(args['visited'] as List);
  final isProvince = args['isProvince'] as bool;
  final litProvinces = Set<String>.from(args['litProvinces'] as List);
  
  return features.map((feature) {
    final String regionName = feature['properties']['name'].toString();
    bool isLit;
    if (isProvince) {
      isLit = litProvinces.any(
        (p) => regionName.startsWith(p) || p.startsWith(regionName),
      );
    } else {
      isLit = visitedSet.contains(regionName);
    }
    return [regionName, isLit];
  }).toList();
}

class FootprintMapWidget extends StatefulWidget {
  final List<String> visitedChina;
  final List<String> visitedWorld;
  final Function(List<String> newChina, List<String> newWorld)? onDataChanged;
  final bool isFullScreen;
  final bool initialIsChinaView;

  const FootprintMapWidget({
    super.key, 
    required this.visitedChina,
    required this.visitedWorld,
    this.onDataChanged,
    this.isFullScreen = false,
    this.initialIsChinaView = true,
  });

  @override
  State<FootprintMapWidget> createState() => _FootprintMapWidgetState();
}

class _FootprintMapWidgetState extends State<FootprintMapWidget> {
  late bool _isChinaView;
  bool _isLoading = true;
  
  late MapShapeSource _shapeSource;
  List<_MapModel> _mapData = [];
  
  late Set<String> _localVisitedProvinces; // 省份视图点亮的省份名
  late Set<String> _localVisitedCities;    // 城市视图点亮的城市名
  late Set<String> _localVisitedWorld;

  late MapZoomPanBehavior _zoomPanBehavior;

  // 🚨 核心修复 1：将缓存类型从 Model 列表改为 Map，直接缓存清洗后的安全 GeoJSON
  Map<String, dynamic>? _chinaGeoJsonCache;
  Map<String, dynamic>? _worldGeoJsonCache;
  
  // 预编码的字节缓存，避免每次 _buildMapSource 都重复 jsonEncode（解决城市地图卡顿）
  Uint8List? _chinaProvinceBytes;
  Uint8List? _chinaCityBytes;
  Uint8List? _worldBytes;
  
  // ── 语义缩放新增字段 ──
  Map<String, dynamic>? _chinaCityGeoJsonCache;  // 城市级 GeoJSON 缓存
  bool _isShowingCities = false;                  // 当前是否显示城市视图
  static const double _zoomThreshold = 3.5;       // 缩放阈值，可在真机上微调
  bool _pendingZoomSwitch = false;                // 防止 postFrameCallback 重复注册

  @override
  void initState() {
    super.initState();
    _isChinaView = widget.initialIsChinaView;
    
    // visitedChina 里可能混有城市名和省份名，按 cityToProvinceMap 分类
    _localVisitedCities = <String>{};
    _localVisitedProvinces = <String>{};
    for (final name in widget.visitedChina) {
      if (cityToProvinceMap.containsKey(name)) {
        _localVisitedCities.add(name);
      } else {
        _localVisitedProvinces.add(name);
      }
    }
    _localVisitedWorld = Set.from(widget.visitedWorld);
    
    _zoomPanBehavior = MapZoomPanBehavior(
      enableDoubleTapZooming: true,
      enablePanning: true,
      enablePinching: true,
      zoomLevel: _isChinaView ? 1.0 : 1.2, 
      maxZoomLevel: 30.0, 
    );

    _initMapData();
  }

  void _cleanGeoJson(Map<String, dynamic> geoJson) {
    // 删除 crs 字段——world.json 含有此字段，Syncfusion 解析时会尝试坐标系转换导致渲染失败
    // china.json 没有此字段所以一直正常，这是 china/world 显示差异的根本原因
    geoJson.remove('crs');  // ← 加这一行

    if (geoJson['features'] == null) return;
    final features = geoJson['features'] as List<dynamic>;

    // ✅ 唯一修复：world.json 每个 Feature 缺少 "type":"Feature" 字段
    // china.json 有此字段所以正常，world.json 没有所以 Syncfusion 全部跳过 → 空白
    for (final feature in features) {
      final f = feature as Map<String, dynamic>;
      f['type'] = 'Feature';  // ← 这一行就是全部修复
    }

    debugPrint('[MAP-DIAG] ===== _cleanGeoJson 开始 =====');

    final rawFeatures = geoJson['features'];
    if (rawFeatures == null) {
      debugPrint('[MAP-DIAG-3] ❌ features 字段为 null，JSON 结构异常！');
      return;
    }

    final List<dynamic> input = rawFeatures as List<dynamic>;
    debugPrint('[MAP-DIAG-3] 原始 features 数量: ${input.length}');

    if (input.isNotEmpty) {
      final first = input[0] as Map<String, dynamic>;
      debugPrint('[MAP-DIAG-4] 第一条 feature keys: ${first.keys.toList()}');
      debugPrint('[MAP-DIAG-4] 有无 type 字段: ${first.containsKey("type")} => ${first["type"]}');
      debugPrint('[MAP-DIAG-4] properties: ${first["properties"]}');
      debugPrint('[MAP-DIAG-5] geometry.type: ${(first["geometry"] as Map?)?["type"]}');
    }

    final Map<String, int> geomTypeCounts = {};
    for (final f in input) {
      final geomType = (f['geometry'] as Map<String, dynamic>?)?['type']?.toString() ?? 'null';
      geomTypeCounts[geomType] = (geomTypeCounts[geomType] ?? 0) + 1;
    }
    debugPrint('[MAP-DIAG-5] geometry 类型分布: $geomTypeCounts');

    final List<Map<String, dynamic>> fixedFeatures = [];
    int skipped = 0;
    int expanded = 0;

    for (final raw in input) {
      final Map<String, dynamic> feat = raw as Map<String, dynamic>;
      final props = feat['properties'] as Map<String, dynamic>?;
      final geom = feat['geometry'] as Map<String, dynamic>?;

      if (props == null || geom == null || geom['coordinates'] == null) {
        skipped++;
        continue;
      }
      final name = props['name']?.toString().trim() ?? '';
      if (name.isEmpty) {
        skipped++;
        continue;
      }

      final geomType = geom['type']?.toString() ?? '';

      if (geomType == 'Polygon') {
        fixedFeatures.add({
          'type': 'Feature',
          'properties': {'name': name},
          'geometry': geom,
        });
      } else if (geomType == 'MultiPolygon') {
        for (final polyCoords in (geom['coordinates'] as List<dynamic>)) {
          fixedFeatures.add({
            'type': 'Feature',
            'properties': {'name': name},
            'geometry': {'type': 'Polygon', 'coordinates': polyCoords},
          });
          expanded++;
        }
      } else {
        skipped++;
      }
    }

    debugPrint('[MAP-DIAG-5] 处理后 features 数量: ${fixedFeatures.length}（展开了 $expanded 个子多边形，跳过 $skipped 条）');
    debugPrint('[MAP-DIAG-4] 处理后第一条 type 字段: ${fixedFeatures.isNotEmpty ? fixedFeatures[0]["type"] : "无数据"}');

    geoJson['features'] = fixedFeatures;
    debugPrint('[MAP-DIAG] ===== _cleanGeoJson 完成 =====');
  }

  // 异步读取解析 GeoJSON
  Future<void> _initMapData() async {
    setState(() => _isLoading = true);
    try {
      if (_isChinaView) {
        // 省份数据
        if (_chinaGeoJsonCache == null) {
          final jsonString = await rootBundle.loadString('assets/china_provinces.json');
          final geoJson = jsonDecode(jsonString) as Map<String, dynamic>;
          _cleanGeoJson(geoJson);
          _chinaGeoJsonCache = geoJson;
          _chinaProvinceBytes = Uint8List.fromList(utf8.encode(jsonEncode(geoJson)));
        }
        // 城市数据后台静默预加载（不阻塞省份显示）
        if (_chinaCityGeoJsonCache == null) {
          rootBundle.loadString('assets/china_cities.json').then((jsonString) {
            if (!mounted) return;
            final geoJson = jsonDecode(jsonString) as Map<String, dynamic>;
            _cleanGeoJson(geoJson);
            _chinaCityGeoJsonCache = geoJson;
            _chinaCityBytes = Uint8List.fromList(utf8.encode(jsonEncode(geoJson)));
            debugPrint('[MAP] 城市数据后台加载完成');
            // ★ 关键：加载完成后，如果当前缩放级别已经超过阈值，立刻切换到城市视图
            if (mounted && _isChinaView && _zoomPanBehavior.zoomLevel >= _zoomThreshold && !_isShowingCities) {
              setState(() {
                _isShowingCities = true;
              });
              _buildMapSource();
            }
          }).catchError((e) {
            debugPrint('[MAP] 城市数据加载失败: $e');
          });
        }
      } else {
        if (_worldGeoJsonCache == null) {
          final jsonString = await rootBundle.loadString('assets/world.json');
          final geoJson = jsonDecode(jsonString) as Map<String, dynamic>;
          _cleanGeoJson(geoJson);
          _worldGeoJsonCache = geoJson;
          _worldBytes = Uint8List.fromList(utf8.encode(jsonEncode(geoJson)));
        }
      }
      _buildMapSource();
    } catch (e, stack) {
      debugPrint('[MAP] ❌ 异常: $e\n$stack');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 监听缩放级别，动态切换省份/城市数据源（仅在中国视图下生效）
  void _handleZoomChanged(double zoom) {
    if (!_isChinaView) return;
    
    final bool shouldShowCities = zoom >= _zoomThreshold;
    
    // 状态没变化，直接跳过
    if (shouldShowCities == _isShowingCities) return;
    // 要切城市但数据没好，跳过
    if (shouldShowCities && _chinaCityBytes == null) return;
    // 已经有一个 postFrameCallback 在排队了，不重复注册
    if (_pendingZoomSwitch) return;
    
    _pendingZoomSwitch = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingZoomSwitch = false;
      if (!mounted) return;
      // 再次校验，防止 postFrameCallback 执行时状态已被其他操作改变
      final bool stillShouldShow = _zoomPanBehavior.zoomLevel >= _zoomThreshold;
      if (stillShouldShow == _isShowingCities) return;
      if (stillShouldShow && _chinaCityBytes == null) return;
      
      setState(() {
        _isShowingCities = stillShouldShow;
      });
      _buildMapSource();
    });
  }

  // 构建数据源，包含动态地名显示逻辑
  Future<void> _buildMapSource() async {
    final bool showCities = _isChinaView && _isShowingCities && _chinaCityGeoJsonCache != null;
    
    // 选择数据源（优先用预编码字节，完全避免重复 jsonEncode）
    final Uint8List? bytes = showCities
        ? _chinaCityBytes
        : (_isChinaView ? _chinaProvinceBytes : _worldBytes);
        
    final Map<String, dynamic>? geoJson = showCities
        ? _chinaCityGeoJsonCache
        : (_isChinaView ? _chinaGeoJsonCache : _worldGeoJsonCache);
    
    if (bytes == null || geoJson == null) return;
    
    final features = geoJson['features'] as List<dynamic>;
    
    List<_MapModel> newData;
    if (showCities) {
      // 城市数量大，丢到 isolate 避免卡主线程
      final rawData = await compute(_buildMapDataIsolate, {
        'features': features,
        'visited': _localVisitedCities.toList(),
        'isProvince': false,
        'litProvinces': <String>[],
      });
      newData = rawData.map((e) => _MapModel(
        e[0] as String,
        (e[1] as bool) ? Colors.indigo.shade500 : Colors.white.withOpacity(0.05),
      )).toList();
    } else if (_isChinaView) {
      final litProvinces = <String>{..._localVisitedProvinces};
      for (final city in _localVisitedCities) {
        final p = cityToProvinceMap[city];
        if (p != null) litProvinces.add(p);
      }
      final rawData = _buildMapDataIsolate({
        'features': features,
        'visited': <String>[],
        'isProvince': true,
        'litProvinces': litProvinces.toList(),
      });
      newData = rawData.map((e) => _MapModel(
        e[0] as String,
        (e[1] as bool) ? Colors.indigo.shade500 : Colors.white.withOpacity(0.05),
      )).toList();
    } else {
      final rawData = _buildMapDataIsolate({
        'features': features,
        'visited': _localVisitedWorld.toList(),
        'isProvince': false,
        'litProvinces': <String>[],
      });
      newData = rawData.map((e) => _MapModel(
        e[0] as String,
        (e[1] as bool) ? Colors.indigo.shade500 : Colors.white.withOpacity(0.05),
      )).toList();
    }
    
    if (!mounted) return;
    setState(() {
      _mapData = newData;
      _shapeSource = MapShapeSource.memory(
        bytes,
        shapeDataField: 'name',
        dataCount: _mapData.length,
        primaryValueMapper: (int index) => _mapData[index].region,
        shapeColorValueMapper: (int index) => _mapData[index].color,
        dataLabelMapper: (int index) => _mapData[index].region,
      );
    });
  }

  void _handleRegionTapped(int index) {
    final String tappedRegion = _mapData[index].region;

    setState(() {
      if (_isChinaView) {
        if (_isShowingCities) {
          // 城市视图：写入城市 Set
          if (_localVisitedCities.contains(tappedRegion)) {
            _localVisitedCities.remove(tappedRegion);
          } else {
            _localVisitedCities.add(tappedRegion);
          }
        } else {
          // 省份视图：写入省份 Set
          if (_localVisitedProvinces.contains(tappedRegion)) {
            _localVisitedProvinces.remove(tappedRegion);
          } else {
            _localVisitedProvinces.add(tappedRegion);
          }
        }
      } else {
        if (_localVisitedWorld.contains(tappedRegion)) {
          _localVisitedWorld.remove(tappedRegion);
        } else {
          _localVisitedWorld.add(tappedRegion);
        }
      }
    });
    _buildMapSource();

    HapticFeedback.lightImpact();
    // 合并两个集合回传给上层（保持接口不变）
    widget.onDataChanged?.call(
      [..._localVisitedProvinces, ..._localVisitedCities],
      _localVisitedWorld.toList(),
    );
  }

  void _switchView() {
    if (_isLoading) return;
    setState(() {
      _isChinaView = !_isChinaView;
      _isShowingCities = false; // 切换视图时重置城市/省份状态
      _zoomPanBehavior = MapZoomPanBehavior(
        enableDoubleTapZooming: true,
        enablePanning: true,
        enablePinching: true,
        zoomLevel: _isChinaView ? 1.0 : 1.2,
        maxZoomLevel: 30.0,
      );
    });
    _initMapData();
  }

  void _toggleFullScreen() {
    if (widget.isFullScreen) {
      Navigator.pop(context);
    } else {
      Navigator.push(
        context,
        PageRouteBuilder(
          opaque: false, 
          pageBuilder: (context, animation, secondaryAnimation) {
            return FadeTransition(
              opacity: animation,
              child: Scaffold(
                backgroundColor: Colors.black,
                body: FootprintMapWidget(
                  visitedChina: [..._localVisitedProvinces, ..._localVisitedCities],
                  visitedWorld: _localVisitedWorld.toList(),
                  isFullScreen: true,
                  initialIsChinaView: _isChinaView,
                  onDataChanged: (newChina, newWorld) {
                    setState(() {
                      // 重新分类
                      _localVisitedCities.clear();
                      _localVisitedProvinces.clear();
                      for (final name in newChina) {
                        if (cityToProvinceMap.containsKey(name)) {
                          _localVisitedCities.add(name);
                        } else {
                          _localVisitedProvinces.add(name);
                        }
                      }
                      _localVisitedWorld = Set.from(newWorld);
                    });
                    _buildMapSource();
                    widget.onDataChanged?.call(newChina, newWorld);
                  },
                ),
              ),
            );
          },
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final double safeTop = widget.isFullScreen ? MediaQuery.of(context).padding.top : 0;
    final double safeBottom = widget.isFullScreen ? MediaQuery.of(context).padding.bottom : 0;

    return Container(
      height: widget.isFullScreen ? double.infinity : 260, 
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.isFullScreen 
              ? [const Color(0xFF111111), const Color(0xFF222222)] 
              : [Colors.grey.shade900, Colors.grey.shade800]
        ),
        borderRadius: BorderRadius.circular(widget.isFullScreen ? 0 : 24),
        boxShadow: widget.isFullScreen ? [] : [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: Stack(
        children: [
          if (!_isLoading)
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: safeTop + 16, bottom: safeBottom + 60, left: 12, right: 12),
                child: SfMaps(
                  layers: [
                    MapShapeLayer(
                      source: _shapeSource,
                      strokeColor: Colors.white.withOpacity(0.15),
                      strokeWidth: 0.5,
                      showDataLabels: true,
                      // 开启 hide 防重叠，解决小国家或缩小状态下地名重叠被遮盖问题
                      dataLabelSettings: const MapDataLabelSettings(
                        overflowMode: MapLabelOverflow.hide,
                        textStyle: TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                      zoomPanBehavior: _zoomPanBehavior,
                      // 彻底找回点亮功能！通过透明样式防止内置选区污染，完美透出我们的高亮色
                      selectionSettings: const MapSelectionSettings(
                        color: Colors.transparent,
                        strokeColor: Colors.transparent,
                      ),
                      onSelectionChanged: _handleRegionTapped,
                      // 使用 onWillZoom 回调监听缩放变化
                      onWillZoom: (MapZoomDetails details) {
                        // details.newZoomLevel 是缩放后的目标级别
                        final double? newZoom = details.newZoomLevel;
                        if (newZoom != null) {
                          _handleZoomChanged(newZoom);
                        }
                        return true; // 返回 true 表示允许本次缩放
                      },
                    ),
                  ],
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: Colors.white24)),
          
          // 左上角全屏按钮
          Positioned(
            top: safeTop + 16, 
            left: 16,
            child: GestureDetector(
              onTap: _toggleFullScreen,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.white10, shape: BoxShape.circle, border: Border.all(color: Colors.white24)),
                child: Icon(widget.isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, size: 20, color: Colors.white),
              ),
            ),
          ),

          // 右上角切换按钮
          Positioned(
            top: safeTop + 16, 
            right: 16,
            child: GestureDetector(
              onTap: _switchView,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white24)),
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, size: 14, color: Colors.indigo.shade300),
                    const SizedBox(width: 4),
                    Text(_isChinaView ? "切换世界" : "切换中国", style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),

          // 左下角统计
          Positioned(
            left: 20, 
            bottom: safeBottom + 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_isChinaView ? "中国足迹地图" : "世界足迹地图", style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(width: 8),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.indigo.shade500.withOpacity(0.3), borderRadius: BorderRadius.circular(4)), child: const Text("可缩放 · 点击点亮", style: TextStyle(color: Colors.indigoAccent, fontSize: 9, fontWeight: FontWeight.bold))),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: Text("已点亮", style: TextStyle(fontSize: 12, color: Colors.grey.shade400))),
                    const SizedBox(width: 8),
                    Text("${_isChinaView ? (_localVisitedProvinces.length + _localVisitedCities.length) : _localVisitedWorld.length}", style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.indigo.shade400, height: 1.0)),
                    const SizedBox(width: 8),
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(_isChinaView ? "个省市" : "个国家", style: TextStyle(fontSize: 12, color: Colors.grey.shade400))),
                  ],
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}

class _MapModel {
  _MapModel(this.region, this.color);
  final String region;
  Color color; // 必须允许修改，以实现点亮状态的实时变更
}