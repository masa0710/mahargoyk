import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // ★ 追加: rootBundle
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/content_item.dart';
import '../widgets/bottom_navigation.dart';
import '../widgets/header.dart';
import 'spot_detail_page.dart';

class MapPage extends StatefulWidget {
  final ContentItem? initialSpot;
  const MapPage({super.key, this.initialSpot});

  @override
  MapPageState createState() => MapPageState();
}

class MapPageState extends State<MapPage> {
  // ---- Map / Data ----
  final MapController _mapController = MapController();
  LatLng? _userLocation;
  List<ContentItem> _spots = [];
  ContentItem? _selectedSpot;

  // ---- Routing / Navigation ----
  bool _isRouteVisible = false;
  List<LatLng> _routePoints = [];
  List<dynamic> _routeSteps = [];
  int _currentStepIndex = 0;
  final FlutterTts _tts = FlutterTts();
  StreamSubscription<Position>? _posSub;

  // ---- Filters ----
  bool _showFilters = false;
  final Map<String, bool> _genreFilters = {
    '観光': false,
    'グルメ': false,
    'ショッピング': false,
    'ホテル・旅館': false,
    'お土産': false,
    'イベント': false,
    'ライフスタイル': false,
  };
  final Map<String, bool> _areaFilters = {
    '三宮・元町': false,
    '北野・新神戸': false,
    'メリケンパーク・ハーバーランド': false,
    '六甲山・摩耶山': false,
    '有馬温泉': false,
    '灘・東灘': false,
    '兵庫・長田': false,
    '須磨・垂水': false,
    'ポートアイランド・神戸空港': false,
    '西神・北神': false,
  };

  List<ContentItem> get _filteredSpots {
    final gs = _genreFilters.entries.where((e) => e.value).map((e) => e.key).toList();
    final as = _areaFilters.entries.where((e) => e.value).map((e) => e.key).toList();
    return _spots.where((s) {
      final gOk = gs.isEmpty || gs.contains(s.genre);
      final aOk = as.isEmpty || as.contains(s.area);
      return gOk && aOk;
    }).toList();
  }
  
  // ---- GTFS ----
  List<Polyline> _gtfsRoutes = []; // 路線データ
  List<Marker> _gtfsStations = []; // 駅データ
  bool _showGtfs = false; // GTFS表示切り替えフラグ

  // 路線ごとの固定色マップ
  final Map<String, Color> _colorMap = {
    'JR_KobeLine': Colors.blue,
    'Hanshin_MainLine': Colors.orange,
    'Sanyo_Line': Colors.red,
    'KoubeDentetsu_Line': Colors.green,
    'Potorain_Line': Colors.purple,
  };

  // ---- UI ----
  bool _isZoomedIn = false;
  final int _selectedIndex = 4;


  @override
  void initState() {
    super.initState();
    _initTts();
    if (widget.initialSpot != null) {
      _selectedSpot = widget.initialSpot;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(
          LatLng(widget.initialSpot!.latitude, widget.initialSpot!.longitude),
          15.0,
        );
      });
    }
    _loadMapData();
    _startLocationUpdates();
    _loadGtfsData(); // GTFSデータ読み込みを追加
  }

  @override
  void dispose() {
    _posSub?.cancel();
    if (!kIsWeb) _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    if (!kIsWeb) {
      await _tts.setLanguage('ja-JP');
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.5);
    }
  }

  void _startLocationUpdates() {
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen((p) {
      if (!mounted) return;
      setState(() => _userLocation = LatLng(p.latitude, p.longitude));
      if (_isRouteVisible && _userLocation != null) {
        // ナビゲーション中はマップをユーザー位置に追従させ、進行方向に回転
        _mapController.move(_userLocation!, _mapController.camera.zoom);
        if (p.heading != 0) { // headingが有効な場合のみ回転
            _mapController.rotate(-p.heading);
        }
        _checkRouteProgress();
      }
    });
  }


  Future<void> _loadMapData() async {
    try {
      final pos = await _getCurrentLocation();
      final spots = await _fetchSpots();
      if (!mounted) return;
      setState(() {
        _userLocation = LatLng(pos.latitude, pos.longitude);
        _spots = spots;
      });
    } catch (e) {
      debugPrint('マップデータ読込エラー: $e');
    }
  }

  Future<Position> _getCurrentLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) throw Exception('位置情報サービスが無効です。');

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('位置情報の権限が拒否されました。');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('位置情報の権限が永久に拒否されました。');
    }
    return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  Future<List<ContentItem>> _fetchSpots() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('spots').get();
      return snap.docs.map((d) => ContentItem.fromFirestore(d)).toList();
    } catch (e) {
      debugPrint('スポット読込エラー: $e');
      return [];
    }
  }
  

  Future<void> _loadGtfsData() async {
    try {
      await _loadGtfsShapes();   // 路線データ読み込み
      await _loadGtfsStations(); // 駅データ読み込み
      if (mounted) setState(() {});
      debugPrint('GTFSデータ読み込み完了: 路線 ${_gtfsRoutes.length}、駅 ${_gtfsStations.length}');
    } catch (e) {
      debugPrint('GTFSデータ読み込みエラー: $e');
    }
  }
  
  ///shapes.txt）を読み込み
  Future<void> _loadGtfsShapes() async {
    try {
      final data = await rootBundle.loadString('assets/gtfs/shapes.txt');
      final rows = const LineSplitter().convert(data);

      final Map<String, List<Map<String, dynamic>>> shapeMap = {};

      for (int i = 1; i < rows.length; i++) {
        final cols = rows[i].split(',');
        if (cols.length < 4) continue;

        final shapeId = cols[0].trim();
        final lat = double.tryParse(cols[1]);
        final lon = double.tryParse(cols[2]);
        final seq = int.tryParse(cols[3]);
        if (lat == null || lon == null || seq == null) continue;

        shapeMap.putIfAbsent(shapeId, () => []).add({
          'lat': lat,
          'lon': lon,
          'seq': seq,
        });
      }

      _gtfsRoutes = shapeMap.entries.map((entry) {
        // 順序番号で並び替え
        entry.value.sort((a, b) => a['seq'].compareTo(b['seq']));
        final points = entry.value.map((e) => LatLng(e['lat'], e['lon'])).toList();
        final smoothed = _smoothPolyline(points, 20);
        final color = _colorMap[entry.key] ??
            Colors.primaries[entry.key.hashCode % Colors.primaries.length];

        return Polyline(points: smoothed, strokeWidth: 4.0, color: color);
      }).toList();
    } catch (e) {
      debugPrint('GTFS shapes.txt 読み込みエラー: $e');
    }
  }

  /// 線をスムージング
  List<LatLng> _smoothPolyline(List<LatLng> points, int divisions) {
    if (points.length < 2) return points;

    final List<LatLng> smoothPoints = [];
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      smoothPoints.add(p1);

      // 区間を指定回数で補間
      for (int j = 1; j < divisions; j++) {
        final t = j / divisions;
        final lat = p1.latitude + (p2.latitude - p1.latitude) * t;
        final lon = p1.longitude + (p2.longitude - p1.longitude) * t;
        smoothPoints.add(LatLng(lat, lon));
      }
    }
    smoothPoints.add(points.last);
    return smoothPoints;
  }


  /// 駅データを読み込み
  Future<void> _loadGtfsStations() async {
    final spotFiles = [
      'assets/gtfs/JRspot.txt',
      'assets/gtfs/Hansinspot.txt',
      'assets/gtfs/Sanyospot.txt',
      'assets/gtfs/Koubedentetsuspot.txt',
      'assets/gtfs/Potorainspot.txt',
      'assets/gtfs/Seishinyamatespot.txt',
    ];

    try {
      for (String path in spotFiles) {
        final data = await rootBundle.loadString(path);
        final rows = const LineSplitter().convert(data);

        for (int i = 1; i < rows.length; i++) {
          final cols = rows[i].split(',');
          if (cols.length < 4) continue;

          final stopName = cols[1];
          final lat = double.tryParse(cols[2]);
          final lon = double.tryParse(cols[3]);
          if (lat == null || lon == null) continue;

          _gtfsStations.add(
            Marker(
              point: LatLng(lat, lon),
              width: 80,
              height: 30,
              child: Column(
                children: [

                  const Icon(Icons.train, color: Colors.blue, size: 20), 
                  Text(stopName, style: const TextStyle(fontSize: 10)),
                ],
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('GTFS 駅データ読み込みエラー: $e');
    }
  }

  void _toggleRoute() async {
    if (_userLocation == null || _selectedSpot == null) return;

    if (_isRouteVisible) {
      _endNavigation();
      return;
    }

    final start = '${_userLocation!.longitude},${_userLocation!.latitude}';
    final end = '${_selectedSpot!.longitude},${_selectedSpot!.latitude}';
    final url = Uri.parse(
      'http://router.project-osrm.org/route/v1/driving/$start;$end?overview=full&steps=true',
    );

    try {
      final res = await http.get(url);
      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['code'] == 'Ok' &&
            data['routes'] != null &&
            data['routes'].isNotEmpty) {
          final poly = PolylinePoints().decodePolyline(data['routes'][0]['geometry']);
          final steps = data['routes'][0]['legs'][0]['steps'];

          setState(() {
            _routePoints = poly.map((p) => LatLng(p.latitude, p.longitude)).toList();
            _isRouteVisible = true;
            _routeSteps = steps.map((s) => {...s, 'announced': false}).toList();
            _currentStepIndex = 0;
          });
          _mapController.move(_userLocation!, 16.0);
          _speak('ナビゲーションを開始します。');
        } else {
          setState(() => _isRouteVisible = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('経路の取得に失敗しました。ルートが見つかりません。')),
          );
        }
      } else {
        setState(() => _isRouteVisible = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('サーバーエラーにより経路の取得に失敗しました。')),
        );
      }
    } catch (e) {
      setState(() => _isRouteVisible = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('HTTPリクエストエラーが発生しました。')));
      }
    }
  }

  void _checkRouteProgress() {
    if (_userLocation == null ||
        _routePoints.isEmpty ||
        _currentStepIndex >= _routeSteps.length) return;

    final next = _routeSteps[_currentStepIndex];
    final stepLoc = LatLng(
      next['maneuver']['location'][1],
      next['maneuver']['location'][0],
    );

    final d = Geolocator.distanceBetween(
      _userLocation!.latitude,
      _userLocation!.longitude,
      stepLoc.latitude,
      stepLoc.longitude,
    );

    // 到着判定
    if (_currentStepIndex == _routeSteps.length - 1 && d < 20) {
      _speak('目的地に到着しました。ナビゲーションを終了します。');
      _endNavigation();
      return;
    }

    // 手前案内
    if (d < 50 && !_routeSteps[_currentStepIndex]['announced']) {
      final instruction = next['maneuver']['instruction'] ?? '次の案内なし';
      _speak(instruction);
      _routeSteps[_currentStepIndex]['announced'] = true;
    }

    // ステップ更新
    if (d < 5) {
      setState(() => _currentStepIndex++);
    }
  }

  Future<void> _speak(String text) async {
    if (!kIsWeb) {
      await _tts.stop();
      await _tts.speak(text);
    }
  }

  void _endNavigation() {
    if (!mounted) return;
    setState(() {
      _isRouteVisible = false;
      _routePoints = [];
      _routeSteps = [];
      _currentStepIndex = 0;
      _selectedSpot = null;
      _mapController.rotate(0); // ナビゲーション終了時にマップの回転をリセット
    });
    _speak('ナビゲーションを終了しました。');
  }


  Widget _buildFilterSection(String title, Map<String, bool> opts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: opts.keys.map((k) {
            return FilterChip(
              label: Text(k),
              selected: opts[k]!,
              onSelected: (v) => setState(() => opts[k] = v),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _navigationUi() {
    if (!_isRouteVisible || _selectedSpot == null || _userLocation == null) {
      return const SizedBox.shrink();
    }

    // ルート全体の距離を計算
    double totalDistance = 0;
    if (_routePoints.isNotEmpty) {
      for (int i = 0; i < _routePoints.length - 1; i++) {
          totalDistance += Geolocator.distanceBetween(
              _routePoints[i].latitude,
              _routePoints[i].longitude,
              _routePoints[i + 1].latitude,
              _routePoints[i + 1].longitude,
          );
      }
    }
    
    // ユーザーから目的地までの残り距離を計算
    double remainingDistance = 0;
    if (_routePoints.isNotEmpty) {
        remainingDistance = Geolocator.distanceBetween(
            _userLocation!.latitude,
            _userLocation!.longitude,
            _routePoints.last.latitude,
            _routePoints.last.longitude,
        );
        // 残り距離が総距離を上回ることはないようにする
        remainingDistance = remainingDistance.clamp(0.0, totalDistance);
    }
    
    // 進捗率を計算
    final completedDistance = (totalDistance > remainingDistance) ? totalDistance - remainingDistance : 0.0;
    final progress = (totalDistance > 0) ? (completedDistance / totalDistance).clamp(0.0, 1.0) : 0.0;
    final remainingText = remainingDistance.toStringAsFixed(1);


    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      child: Card(
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    const Icon(Icons.pin_drop, color: Colors.blue),
                    const SizedBox(width: 8),
                    Text(
                      _selectedSpot!.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ]),
                  OutlinedButton(
                    onPressed: _endNavigation,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                    ),
                    child: const Text('終了'),
                  ),
                ],
              ),
              const Divider(height: 24),
              LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.grey[200],
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
              ),
              const SizedBox(height: 8),
              Text(
                '目的地まで: $remainingText m',
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const LatLng sannomiya = LatLng(34.6946, 135.1952);

    return Scaffold(
      appBar: const AppHeader(),
      body: Stack(
        children: [
          //Map 
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: sannomiya,
              initialZoom: 15.0,
              onTap: (_, __) {
                // タップで選択解除
                setState(() {
                  _selectedSpot = null;
                  _isRouteVisible = false;
                  _routePoints = [];
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_nolabels/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
              ),
              
              // GTFSの路線レイヤーを追加
              if (_showGtfs && _gtfsRoutes.isNotEmpty)
                PolylineLayer(polylines: _gtfsRoutes),
                
              if (_isRouteVisible && _routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(points: _routePoints, color: Colors.blue, strokeWidth: 5),
                  ],
                ),
                
              MarkerLayer(
                markers: [
                  // ユーザー位置マーカー
                  if (_userLocation != null)
                    Marker(
                      point: _userLocation!,
                      width: 60,
                      height: 60,
                      child: const Icon(Icons.navigation, color: Colors.red, size: 36),
                    ),
                    
                  //  GTFSの駅マーカーを追加
                  if (_showGtfs) ..._gtfsStations,
                  
                  // スポットマーカー
                  ..._filteredSpots.map((spot) => Marker(
                        point: LatLng(spot.latitude, spot.longitude),
                        width: 72,
                        height: 64,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedSpot = spot;
                              _isRouteVisible = false;
                              _routePoints = [];
                            });
                            _mapController.move(LatLng(spot.latitude, spot.longitude), 15.0);
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.location_pin, color: Colors.blue, size: 32),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  spot.title,
                                  maxLines: 1, 
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )),
                ],
              ),
            ],
          ),


          Positioned(
            top: 16,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'filterButton',
              onPressed: () => setState(() => _showFilters = !_showFilters),
              icon: Icon(_showFilters ? Icons.close : Icons.tune),
              label: Text(_showFilters ? '閉じる' : 'フィルター'),
              backgroundColor: Colors.white,
              foregroundColor: Colors.blue,
            ),
          ),

          if (_showGtfs)
            Positioned(
              top: 80, // フィルターボタンと被らないように調整
              left: 16,
              child: Card(
                elevation: 4,
                color: Colors.white.withOpacity(0.85),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      _LegendItem(color: Colors.blue, text: 'JR神戸線'),
                      _LegendItem(color: Colors.orange, text: '阪神本線'),
                      _LegendItem(color: Colors.red, text: '山陽電鉄線'),
                      _LegendItem(color: Colors.green, text: '神戸電鉄線'),
                      _LegendItem(color: Colors.purple, text: 'ポートライナー'),
                    ],
                  ),
                ),
              ),
            ),
            
        
          Positioned(
            top: 80, // GTFS凡例と被らないように調整
            left: 12,
            right: 12,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: !_showFilters
                  ? const SizedBox.shrink()
                  : Card(
                      elevation: 6,
                      color: Colors.purple[50],
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildFilterSection('ジャンル', _genreFilters),
                            _buildFilterSection('エリア', _areaFilters),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () => setState(() {
                                  _genreFilters.updateAll((key, value) => false);
                                  _areaFilters.updateAll((key, value) => false);
                                }),
                                child: const Text('クリア'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),


          if (_selectedSpot != null && !_isRouteVisible)
            Positioned(
              right: 16,
              top: 80, // フィルターボタンと被らないように調整
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Container(
                  width: 260,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _selectedSpot!.title,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _selectedSpot = null;
                              _isRouteVisible = false;
                              _routePoints = [];
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Image.network(
                          _selectedSpot!.imageUrl,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _selectedSpot!.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => SpotDetailPage(spot: _selectedSpot!),
                                  ),
                                );
                              },
                              child: const Text('詳細を見る'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FloatingActionButton.small(
                            heroTag: 'routeButton',
                            backgroundColor: Colors.white,
                            onPressed: _toggleRoute,
                            child: const Icon(Icons.directions, color: Colors.green),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),


          _navigationUi(),


          Positioned(
            bottom: 80, // My location button の上に配置
            right: 16,
            child: FloatingActionButton(
              heroTag: 'gtfsToggle',
              onPressed: () => setState(() => _showGtfs = !_showGtfs),
              backgroundColor: _showGtfs ? Colors.blue[700] : Colors.white,
              child: Icon(Icons.directions_subway,
                  color: _showGtfs ? Colors.white : Colors.blue),
            ),
          ),


          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'userLocationButton',
              onPressed: () {
                setState(() => _isZoomedIn = !_isZoomedIn);
                if (_isZoomedIn && _userLocation != null) {
                  _mapController.move(_userLocation!, 15.0);
                } else {
                  _mapController.move(sannomiya, 15.0);
                }

                if (!_isRouteVisible) {
                    _mapController.rotate(0);
                }
              },
              backgroundColor: _isZoomedIn ? Colors.blue[700] : Colors.white,
              child: Icon(Icons.my_location,
                  color: _isZoomedIn ? Colors.white : Colors.blue),
            ),
          ),
        ],
      ),
      bottomNavigationBar: AppBottomNavigation(currentIndex: _selectedIndex),
    );
  }
}


class _LegendItem extends StatelessWidget {
  final Color color;
  final String text;
  const _LegendItem({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 20, height: 4, color: color),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}