import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_maps/maps.dart';

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
  
  late Set<String> _localVisitedChina;
  late Set<String> _localVisitedWorld;

  late MapZoomPanBehavior _zoomPanBehavior;

  // 🚨 核心修复 1：将缓存类型从 Model 列表改为 Map，直接缓存清洗后的安全 GeoJSON
  static Map<String, dynamic>? _chinaGeoJsonCache;
  static Map<String, dynamic>? _worldGeoJsonCache;

  @override
  void initState() {
    super.initState();
    _isChinaView = widget.initialIsChinaView;
    _localVisitedChina = Set.from(widget.visitedChina);
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

  // 🚨 核心修复 2：数据大清洗 + MultiPolygon 展开
  // world.json 中 91 个国家是 MultiPolygon 类型（如澳大利亚、美国等）。
  // Syncfusion SfMaps 渲染 MultiPolygon 时会将子多边形展开，导致实际渲染数量（1083）
  // 远超 dataCount（217），造成 mapper index 越界，整张地图空白渲染失败。
  // 修复：将所有 MultiPolygon 展开为独立的 Polygon feature，确保一一对应。
  void _cleanGeoJson(Map<String, dynamic> geoJson) {
    if (geoJson['features'] == null) return;

    final features = geoJson['features'] as List<dynamic>;
    final List<dynamic> cleanedFeatures = [];

    for (final feature in features) {
      final props = feature['properties'];
      final geom = feature['geometry'];

      // 过滤无效 feature：props 为空、name 为 null 或空字符串、geometry 为空
      if (props == null) continue;
      final name = props['name'];
      if (name == null || name.toString().trim().isEmpty) continue;
      if (geom == null || geom['coordinates'] == null) continue;

      final String geomType = geom['type'].toString();

      if (geomType == 'Polygon') {
        // Polygon 直接保留
        cleanedFeatures.add(feature);
      } else if (geomType == 'MultiPolygon') {
        // ✅ 关键修复：将 MultiPolygon 的每个子多边形展开为独立 Polygon feature
        // 保留相同的 properties（name 相同），Syncfusion 会按 name 归组渲染
        final List<dynamic> subPolygons = geom['coordinates'] as List<dynamic>;
        for (final polyCoords in subPolygons) {
          cleanedFeatures.add({
            'type': 'Feature',
            'properties': Map<String, dynamic>.from(props as Map),
            'geometry': {
              'type': 'Polygon',
              'coordinates': polyCoords,
            },
          });
        }
      }
      // 其他类型（Point、LineString 等）直接忽略
    }

    geoJson['features'] = cleanedFeatures;
  }

  // 异步读取解析 GeoJSON
  Future<void> _initMapData() async {
    setState(() => _isLoading = true);
    try {
      if (_isChinaView && _chinaGeoJsonCache == null) {
        final jsonString = await rootBundle.loadString('assets/china.json');
        final geoJson = jsonDecode(jsonString);
        _cleanGeoJson(geoJson); // 洗牌
        _chinaGeoJsonCache = geoJson;
      }
      if (!_isChinaView && _worldGeoJsonCache == null) {
        final jsonString = await rootBundle.loadString('assets/world.json');
        final geoJson = jsonDecode(jsonString);
        _cleanGeoJson(geoJson); // 洗牌
        _worldGeoJsonCache = geoJson;
      }
      _buildMapSource();
    } catch (e) {
      debugPrint("地图数据初始化失败: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 🚨 核心修复 3：直接删除原本的 _extractMapData 方法，完全用不上了！

  // 构建数据源，包含动态地名显示逻辑
  void _buildMapSource() {
    final geoJson = _isChinaView ? _chinaGeoJsonCache! : _worldGeoJsonCache!;
    final currentVisited = _isChinaView ? _localVisitedChina : _localVisitedWorld;

    // 1. 基于展开后的 features 数组构建渲染数据（与 features 数组完全一一对应）
    // MultiPolygon 已展开：同一国家多条 feature 同 name，Syncfusion 按 name 归组显示
    _mapData = (geoJson['features'] as List<dynamic>).map((feature) {
      final String regionName = feature['properties']['name'].toString();
      final bool isLit = currentVisited.contains(regionName);
      return _MapModel(regionName, isLit ? Colors.indigo.shade500 : Colors.white.withOpacity(0.05));
    }).toList();

    // 2. 将清洗后的 Map 字典编码为 Uint8List 字节流
    final Uint8List mapBytes = Uint8List.fromList(utf8.encode(jsonEncode(geoJson)));

    // 3. 传入字节流给引擎
    _shapeSource = MapShapeSource.memory(
      mapBytes,
      shapeDataField: 'name', 
      dataCount: _mapData.length,
      primaryValueMapper: (int index) => _mapData[index].region,
      shapeColorValueMapper: (int index) => _mapData[index].color,
      // 直接映射文字，利用插件自带的 MapLabelOverflow.hide 防止杂乱
      dataLabelMapper: (int index) => _mapData[index].region,
    );
  }

  // 🚨 极速响应的点亮功能！
  void _handleRegionTapped(int index) {
    final String tappedRegion = _mapData[index].region;
    
    setState(() {
      // 维护点亮与取消点亮的集合状态，并立刻修改颜色的 MapModel
      if (_isChinaView) {
        if (_localVisitedChina.contains(tappedRegion)) {
          _localVisitedChina.remove(tappedRegion);
        } else {
          _localVisitedChina.add(tappedRegion);
        }
      } else {
        if (_localVisitedWorld.contains(tappedRegion)) {
          _localVisitedWorld.remove(tappedRegion);
        } else {
          _localVisitedWorld.add(tappedRegion);
        }
      }
      
      // 重新构建数据源以刷新地图视图
      _buildMapSource();
    });

    HapticFeedback.lightImpact();
    // 数据回传到上一层状态
    widget.onDataChanged?.call(_localVisitedChina.toList(), _localVisitedWorld.toList());
  }

  void _switchView() {
    if (_isLoading) return; // 防连点
    setState(() {
      _isChinaView = !_isChinaView;
      // 🚨 核心修复：不要直接修改 _zoomPanBehavior.zoomLevel (会引发销毁冲突崩溃)
      // 直接重新实例化一个全新的控制器，彻底切断与旧图层（即将被 loading 销毁）的联系
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
                  visitedChina: _localVisitedChina.toList(),
                  visitedWorld: _localVisitedWorld.toList(),
                  isFullScreen: true,
                  initialIsChinaView: _isChinaView,
                  onDataChanged: (newChina, newWorld) {
                    setState(() {
                      _localVisitedChina = Set.from(newChina);
                      _localVisitedWorld = Set.from(newWorld);
                      _buildMapSource();
                    });
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
                    Text("${_isChinaView ? _localVisitedChina.length : _localVisitedWorld.length}", style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.indigo.shade400, height: 1.0)),
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