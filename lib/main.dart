import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:geolocator/geolocator.dart';
import 'package:maps_toolkit/maps_toolkit.dart' as mt;
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xml/xml.dart' as xml;
import 'package:archive/archive.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:screenshot/screenshot.dart';
import 'dart:ui' as ui;
import 'dxf_export.dart';

void main() {
  runApp(const LandAreaApp());
}

enum AppMode { area, distance, coordinate }

// Lớp lưu trữ thông tin của một điểm đo
class LandPoint {
  ll.LatLng position;
  String name;
  String branchName;
  String segmentName;
  String shapeType;
  List<String> notes;
  String? imagePath;
  int colorValue;

  LandPoint({
    required this.position, 
    required this.name, 
    this.branchName = 'Chính',
    this.segmentName = '',
    this.shapeType = 'none',
    List<String>? notes,
    this.imagePath,
    this.colorValue = 0xFFF44336, // Colors.red.value
  }) : notes = notes ?? List.filled(7, '');

  Map<String, dynamic> toJson() => {
        'lat': position.latitude,
        'lon': position.longitude,
        'name': name,
        'branchName': branchName,
        'segmentName': segmentName,
        'shapeType': shapeType,
        'notes': notes,
        'imagePath': imagePath,
        'colorValue': colorValue,
      };

  factory LandPoint.fromJson(Map<String, dynamic> json) => LandPoint(
        position: ll.LatLng(json['lat'], json['lon']),
        name: json['name'],
        branchName: json['branchName'] ?? 'Chính',
        segmentName: json['segmentName'] ?? '',
        shapeType: json['shapeType'] ?? 'none',
        notes: json['notes'] != null ? List<String>.from(json['notes']) : List.filled(7, ''),
        imagePath: json['imagePath'],
        colorValue: json['colorValue'] ?? (json['branchName'] == 'Chính' ? 0xFFF44336 : 0xFFFFFF00),
      );
}

double _calculateBearing(ll.LatLng p1, ll.LatLng p2) {
  var lat1 = p1.latitude * math.pi / 180.0;
  var lon1 = p1.longitude * math.pi / 180.0;
  var lat2 = p2.latitude * math.pi / 180.0;
  var lon2 = p2.longitude * math.pi / 180.0;

  var dLon = lon2 - lon1;

  var y = math.sin(dLon) * math.cos(lat2);
  var x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

  return math.atan2(y, x);
}

class LandAreaApp extends StatelessWidget {
  const LandAreaApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MINHGPS',
      theme: ThemeData(
        primarySwatch: Colors.green,
        useMaterial3: true,
      ),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({Key? key}) : super(key: key);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  List<LandPoint> _points = [];
  ll.LatLng? _currentLocation;
  double _calculatedAreaSqMeters = 0.0;
  bool _isLoadingLocation = false;
  AlignOnUpdate _alignPositionOnUpdate = AlignOnUpdate.never;
  
  int? _movingPointIndex;
  String _currentBranch = 'Chính';
  AppMode _currentMode = AppMode.area;
  Offset? _crosshairPos;
  Color _currentColor = Colors.red;

  final List<Color> _presetColors = [
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.yellowAccent,
    Colors.purple,
    Colors.orange,
    Colors.cyan,
    Colors.white,
  ];
  
  String? _deviceId;
  bool _isActivated = false;

  String _generateRandomDeviceId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    var rnd = math.Random();
    return String.fromCharCodes(Iterable.generate(6, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));
  }

  String _generateActivationCode(String deviceId) {
    int hash = 0;
    String input = deviceId + "MINHGPS_VIP_2026";
    for (int i = 0; i < input.length; i++) {
      hash = (31 * hash + input.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return (hash % 1000000).toString().padLeft(6, '0');
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    _checkLocationPermissionAndFetch();
    _requestStoragePermissionAndSetupTimer();
  }

  Future<void> _requestStoragePermissionAndSetupTimer() async {
    try {
      await Permission.manageExternalStorage.request();
      await Permission.storage.request();
    } catch (_) {}
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _points.map((p) => p.toJson()).toList();
    await prefs.setString('saved_points', jsonEncode(jsonList));
    await prefs.setString('current_branch', _currentBranch);
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    
    _isActivated = prefs.getBool('is_activated') ?? false;
    _deviceId = prefs.getString('device_id');
    if (_deviceId == null) {
      _deviceId = _generateRandomDeviceId();
      await prefs.setString('device_id', _deviceId!);
    }

    bool hasSeenTutorial = prefs.getBool('has_seen_tutorial') ?? false;
    if (!hasSeenTutorial) {
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          _showAboutDialog();
          prefs.setBool('has_seen_tutorial', true);
        }
      });
    }

    if (!_isActivated) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          _showActivationDialog();
        }
      });
    }

    final pointsString = prefs.getString('saved_points');
    if (pointsString != null) {
      try {
        final List<dynamic> decoded = jsonDecode(pointsString);
        setState(() {
          _points = decoded.map((e) => LandPoint.fromJson(e)).toList();
          _currentBranch = prefs.getString('current_branch') ?? 'Chính';
        });
        _calculateArea();
      } catch (_) {}
    }
  }

  void _showActivationDialog() {
    TextEditingController codeController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('Kích hoạt bản quyền VIP', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Phần mềm yêu cầu kích hoạt bản quyền để sử dụng đầy đủ tính năng.'),
                const SizedBox(height: 15),
                Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.grey[200],
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Mã thiết bị: $_deviceId', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, color: Colors.blue),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _deviceId!));
                          _showSnackBar('Đã copy Mã thiết bị!');
                        },
                      )
                    ],
                  ),
                ),
                const SizedBox(height: 15),
                const Text('Vui lòng copy Mã thiết bị và gửi cho Admin để nhận Mã kích hoạt.', style: TextStyle(fontStyle: FontStyle.italic)),
                const SizedBox(height: 15),
                TextField(
                  controller: codeController,
                  decoration: const InputDecoration(
                    labelText: 'Nhập Mã kích hoạt',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => exit(0),
                child: const Text('Thoát', style: TextStyle(color: Colors.red)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                onPressed: () async {
                  String expectedCode = _generateActivationCode(_deviceId!);
                  if (codeController.text.trim() == expectedCode) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('is_activated', true);
                    setState(() {
                      _isActivated = true;
                    });
                    if (mounted) Navigator.pop(context);
                    _showSnackBar('Kích hoạt thành công!');
                  } else {
                    _showSnackBar('Mã kích hoạt không hợp lệ!');
                  }
                },
                child: const Text('Kích hoạt'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _tryDeleteApk() async {
    try {
      List<String> dirs = [
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
        '/storage/emulated/0/Zalo',
        '/storage/emulated/0/Documents',
        '/storage/emulated/0/Pictures/Zalo',
      ];
      
      for (String dirPath in dirs) {
        final dir = Directory(dirPath);
        if (dir.existsSync()) {
          try {
            final files = dir.listSync(recursive: true);
            for (var file in files) {
              if (file is File && file.path.toLowerCase().endsWith('minhgps.apk')) {
                await file.delete();
              }
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      // Bỏ qua lỗi
    }
  }

  Future<void> _checkLocationPermissionAndFetch() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnackBar('Dịch vụ vị trí bị vô hiệu hóa. Vui lòng bật GPS.');
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnackBar('Quyền truy cập vị trí bị từ chối.');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      _showSnackBar('Quyền vị trí bị từ chối vĩnh viễn.');
      return;
    }

    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _alignPositionOnUpdate = AlignOnUpdate.always;
      _isLoadingLocation = true;
    });
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _currentLocation = ll.LatLng(position.latitude, position.longitude);
        _isLoadingLocation = false;
        _mapController.move(_currentLocation!, 18.0);
      });
    } catch (e) {
      setState(() {
        _isLoadingLocation = false;
      });
      _showSnackBar('Lỗi khi lấy vị trí: $e');
    }
  }

  void _addCurrentPoint() async {
    if (_currentLocation == null) {
      _showSnackBar('Chưa xác định được vị trí hiện tại.');
      return;
    }
    setState(() {
      _isLoadingLocation = true;
    });
    
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      ll.LatLng newPoint = ll.LatLng(position.latitude, position.longitude);
      
      setState(() {
        _currentLocation = newPoint;
        _isLoadingLocation = false;
        _mapController.move(newPoint, _mapController.camera.zoom);
      });
      _promptAndAddPoint(newPoint);
    } catch (e) {
      setState(() {
        _isLoadingLocation = false;
      });
      _showSnackBar('Không thể lấy vị trí GPS.');
    }
  }

  String _getNextPointName(String branch) {
    var branchPoints = _points.where((p) => p.branchName == branch).toList();
    if (branchPoints.isEmpty) return '';
    String lastName = branchPoints.last.name;

    if (branch != 'Chính' && branchPoints.length == 1) {
      var firstPoint = branchPoints.first;
      var parentPoint = _points.firstWhere(
        (p) => p != firstPoint && p.position.latitude == firstPoint.position.latitude && p.position.longitude == firstPoint.position.longitude, 
        orElse: () => firstPoint
      );
      
      if (parentPoint != firstPoint && RegExp(r'\d').hasMatch(parentPoint.name) && lastName == parentPoint.name) {
        return '$lastName.1';
      }
    }

    final regExp = RegExp(r'(\d+)(?!.*\d)');
    final match = regExp.firstMatch(lastName);
    if (match != null) {
      String numStr = match.group(1)!;
      int number = int.parse(numStr);
      String nextNumStr = (number + 1).toString();
      if (numStr.startsWith('0') && numStr.length > 1) {
        nextNumStr = nextNumStr.padLeft(numStr.length, '0');
      }
      return lastName.replaceRange(match.start, match.end, nextNumStr);
    }
    return '';
  }

  void _promptAndAddPoint(ll.LatLng pt) {
    TextEditingController nameController = TextEditingController(text: _getNextPointName(_currentBranch));
    TextEditingController branchController = TextEditingController(text: _currentBranch);
    TextEditingController segmentController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Thêm điểm mới'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Tên điểm', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: branchController,
                  decoration: const InputDecoration(labelText: 'Thuộc nhánh (vd: Chính, Hàng rào)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: segmentController,
                  decoration: const InputDecoration(labelText: 'Lộ và loại dây (đoạn nối tới điểm này)', border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _currentBranch = branchController.text.trim().isEmpty ? 'Chính' : branchController.text.trim();
                  _points.add(LandPoint(
                    position: pt,
                    name: nameController.text.trim(),
                    branchName: _currentBranch,
                    segmentName: segmentController.text.trim(),
                    colorValue: _currentColor.value,
                  ));
                  _calculateArea();
                });
                Navigator.pop(context);
              },
              child: const Text('Thêm'),
            ),
          ],
        );
      },
    );
  }

  void _handleMapTap(ll.LatLng tapPoint) {
    if (_movingPointIndex == null) {
      _promptAndAddPoint(tapPoint);
    }
  }

  void _showBranchOptions() {
    TextEditingController branchController = TextEditingController(text: _currentBranch == 'Chính' ? '' : _currentBranch);
    
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Tạo/Đổi Nhánh Mới'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Các điểm bạn đo tiếp theo sẽ thuộc về nhánh này. Bỏ trống để quay về viền "Chính".'),
              const SizedBox(height: 10),
              TextField(
                controller: branchController,
                decoration: const InputDecoration(
                  labelText: 'Tên nhánh (vd: Ngõ vào, Hàng rào)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _currentBranch = branchController.text.trim().isEmpty ? 'Chính' : branchController.text.trim();
                });
                Navigator.pop(context);
                _showSnackBar('Đang đo ở: $_currentBranch');
              },
              child: const Text('Chuyển nhánh'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _navigateToPoint(ll.LatLng pt) async {
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${pt.latitude},${pt.longitude}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      _showSnackBar('Không thể mở Google Maps.');
    }
  }

  Future<void> _takePictureForPoint(int index, String name, String segmentName) async {
    final point = _points[index];
    final String clipText = "${point.position.latitude.toStringAsFixed(6)}N ${point.position.longitude.toStringAsFixed(6)}E\n"
                            "${DateFormat('dd/MM/yyyy HH:mm:ss').format(DateTime.now())}\n"
                            "${segmentName}\n"
                            "#${name}";
    await Clipboard.setData(ClipboardData(text: clipText));
    _showSnackBar('Đã copy thông tin! Hãy dán (Paste) vào app Camera của bạn.', duration: const Duration(seconds: 4));

    final ImagePicker picker = ImagePicker();
    try {
      final XFile? photo = await picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Expanded(child: Text('Đang xử lý và chèn thông tin vào ảnh...')),
              ],
            ),
          ),
        );

        File watermarkedFile = await _addWatermark(File(photo.path), point, name);

        if (context.mounted) Navigator.pop(context); // close dialog

        setState(() {
          _points[index].imagePath = watermarkedFile.path;
          _saveData();
        });
        _showSnackBar('Đã lưu ảnh cho điểm ${name}');
      }
    } catch (e) {
      if (context.mounted) Navigator.pop(context); // close dialog on error
      _showSnackBar('Lỗi khi chụp ảnh: $e');
    }
  }

  Future<File> _addWatermark(File imageFile, LandPoint point, String name) async {
    String address = '';
    try {
      List<geocoding.Placemark> placemarks = await geocoding.placemarkFromCoordinates(point.position.latitude, point.position.longitude);
      if (placemarks.isNotEmpty) {
        geocoding.Placemark place = placemarks.first;
        address = place.street ?? place.name ?? '';
      }
    } catch (e) {
      // ignore geocoding errors
    }

    final Uint8List bytes = await imageFile.readAsBytes();
    final ui.Image decodedImage = await decodeImageFromList(bytes);
    double imgWidth = decodedImage.width.toDouble();
    double imgHeight = decodedImage.height.toDouble();
    
    double targetWidth = imgWidth > 1920 ? 1920 : imgWidth;
    double scale = targetWidth / imgWidth;
    double targetHeight = imgHeight * scale;

    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: targetWidth * 0.03, // Responsive font size
      fontWeight: FontWeight.bold,
      shadows: const [
        Shadow(offset: Offset(-2, -2), color: Colors.black),
        Shadow(offset: Offset(2, -2), color: Colors.black),
        Shadow(offset: Offset(2, 2), color: Colors.black),
        Shadow(offset: Offset(-2, 2), color: Colors.black),
      ],
    );

    Widget watermarkWidget = Directionality(
      textDirection: ui.TextDirection.ltr,
      child: Container(
        width: targetWidth,
        height: targetHeight,
        decoration: BoxDecoration(
          image: DecorationImage(
            image: MemoryImage(bytes),
            fit: BoxFit.cover,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              bottom: targetHeight * 0.02,
              right: targetWidth * 0.02,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${point.position.latitude.toStringAsFixed(6)}N ${point.position.longitude.toStringAsFixed(6)}E', style: textStyle),
                  if (address.isNotEmpty) Text(address, style: textStyle),
                  Text('#$name', style: textStyle),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    ScreenshotController screenshotController = ScreenshotController();
    Uint8List? capturedBytes = await screenshotController.captureFromWidget(
      watermarkWidget,
      delay: const Duration(milliseconds: 500),
      context: context,
    );

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final savedImage = File('${directory.path}/${name}_$timestamp.jpg');
    await savedImage.writeAsBytes(capturedBytes ?? bytes);
    
    return savedImage;
  }

  void _showPointOptions(int index) {
    TextEditingController nameController = TextEditingController(text: _points[index].name);
    TextEditingController branchController = TextEditingController(text: _points[index].branchName);
    TextEditingController segmentController = TextEditingController(text: _points[index].segmentName);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Tùy chỉnh điểm'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Tên điểm', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: branchController,
                  decoration: const InputDecoration(labelText: 'Thuộc nhánh', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: segmentController,
                  decoration: const InputDecoration(labelText: 'Lộ và loại dây (đoạn nối tới điểm này)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _navigateToPoint(_points[index].position);
                        },
                        icon: const Icon(Icons.directions),
                        label: const Text('Chỉ đường'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          if (nameController.text.trim().isEmpty || branchController.text.trim().isEmpty || segmentController.text.trim().isEmpty) {
                            _showSnackBar('Vui lòng nhập đầy đủ Tên điểm, Nhánh và Lộ dây trước khi chụp ảnh!');
                            return;
                          }
                          Navigator.pop(context);
                          _takePictureForPoint(index, nameController.text.trim(), segmentController.text.trim());
                        },
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Chụp ảnh', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_points[index].imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Đã có ảnh đính kèm', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.purple, foregroundColor: Colors.white),
                          onPressed: () async {
                            final path = _points[index].imagePath!;
                            if (File(path).existsSync()) {
                              showDialog(
                                context: context, 
                                builder: (c) => Dialog(
                                  child: Stack(
                                    children: [
                                      Image.file(File(path)),
                                      Positioned(
                                        right: 0,
                                        top: 0,
                                        child: IconButton(
                                          icon: const Icon(Icons.close, color: Colors.red, size: 30),
                                          onPressed: () => Navigator.pop(c),
                                        )
                                      )
                                    ]
                                  )
                                )
                              );
                            } else {
                              _showSnackBar('Không tìm thấy file ảnh');
                            }
                          },
                          child: const Text('Xem ảnh'),
                        )
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      _showNoteDialog(index);
                    },
                    icon: const Icon(Icons.note_add),
                    label: const Text('Bảng ghi chú', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(45),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() {
                      _movingPointIndex = index;
                      _mapController.move(_points[index].position, _mapController.camera.zoom);
                    });
                    _showSnackBar('Kéo bản đồ để dời điểm.');
                  },
                  icon: const Icon(Icons.pan_tool),
                  label: const Text('Di chuyển điểm'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 40)),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() {
                      _currentBranch = _points[index].branchName;
                    });
                    _showSnackBar('Tiếp tục vẽ nhánh: ${_points[index].branchName}');
                  },
                  icon: const Icon(Icons.linear_scale),
                  label: const Text('Tiếp tục vẽ nhánh này'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 40),
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _promptNewBranchFromPoint(index);
                  },
                  icon: const Icon(Icons.call_split),
                  label: const Text('Bắt đầu nhánh phụ từ điểm này'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 40),
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _points.removeAt(index);
                  _calculateArea();
                });
                Navigator.pop(context);
              },
              child: const Text('Xóa', style: TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _points[index].name = nameController.text;
                  _points[index].branchName = branchController.text.trim().isEmpty ? 'Chính' : branchController.text.trim();
                  _points[index].segmentName = segmentController.text.trim();
                  _calculateArea();
                });
                Navigator.pop(context);
              },
              child: const Text('Lưu'),
            ),
          ],
        );
      },
    );
  }

  void _promptNewBranchFromPoint(int index) {
    String parentName = _points[index].name;
    TextEditingController newBranchController = TextEditingController(text: parentName);
    
    bool hasNumber = RegExp(r'\d').hasMatch(parentName);
    String defaultPointName = hasNumber ? parentName : '';
    TextEditingController firstPointNameController = TextEditingController(text: defaultPointName);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Tạo nhánh phụ'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: newBranchController,
                decoration: const InputDecoration(labelText: 'Tên nhánh phụ mới', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: firstPointNameController,
                decoration: const InputDecoration(labelText: 'Tên điểm đầu tiên của nhánh', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
            ElevatedButton(
              onPressed: () {
                String newBranch = newBranchController.text.trim();
                String firstPointName = firstPointNameController.text.trim();
                if (newBranch.isNotEmpty) {
                  setState(() {
                    _currentBranch = newBranch;
                    _points.add(LandPoint(
                      position: _points[index].position,
                      name: firstPointName,
                      branchName: newBranch,
                      segmentName: '', 
                      colorValue: _currentColor.value,
                    ));
                  });
                  _showSnackBar('Đã bắt đầu nhánh: $newBranch');
                }
                Navigator.pop(context);
              },
              child: const Text('Tạo nhánh'),
            )
          ],
        );
      },
    );
  }

  void _calculateArea() {
    // Chỉ lấy các điểm thuộc viền 'Chính' để tính diện tích
    var mainPoints = _points.where((p) => p.branchName == 'Chính').toList();
    if (mainPoints.length < 3) {
      _calculatedAreaSqMeters = 0.0;
      _saveData();
      return;
    }

    List<mt.LatLng> mtPoints = mainPoints.map((p) {
      return mt.LatLng(p.position.latitude, p.position.longitude);
    }).toList();

    double area = mt.SphericalUtil.computeArea(mtPoints).toDouble();
    _calculatedAreaSqMeters = area;
    _saveData();
  }

  Future<void> _exportToCSV() async {
    if (_points.isEmpty) {
      _showSnackBar('Chưa có dữ liệu để xuất.');
      return;
    }

    String selectedProvince = 'Hà Nội';

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Xuất file CSV'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Chọn Tỉnh/Thành phố để nội suy VN2000:'),
                  const SizedBox(height: 10),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: selectedProvince,
                    items: VN2000Converter.provinces.keys.map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      setDialogState(() {
                        selectedProvince = newValue!;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Hủy'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Xuất File'),
                ),
              ],
            );
          }
        );
      }
    ).then((proceed) async {
      if (proceed == true) {
        double l0 = VN2000Converter.provinces[selectedProvince]!;
        
        List<List<dynamic>> rows = [];
        rows.add(["STT", "Kinh Độ", "Vĩ Độ", "Tên Điểm", "Dữ liệu vị trí", "Tên Ảnh đính kèm", "Số Đường Tròn", "Số Hình Vuông", "Nhánh", "X (VN2000)", "Y (VN2000)", "Lộ và loại dây", "Khoảng cách (m)"]);

        for (int i = 0; i < _points.length; i++) {
          var p = _points[i];
          double dist = 0.0;
          String segmentName = "-";
          
          var prevPoints = _points.sublist(0, i).where((x) => x.branchName == p.branchName).toList();
          if (prevPoints.isNotEmpty) {
            var prev = prevPoints.last;
            segmentName = p.segmentName.isNotEmpty ? p.segmentName : "-";
            dist = Geolocator.distanceBetween(
                prev.position.latitude, prev.position.longitude,
                p.position.latitude, p.position.longitude);
          }
          
          var vn2000 = VN2000Converter.wgs84ToVn2000(p.position.latitude, p.position.longitude, l0);
          
          String combinedNotes = p.notes.map((n) {
            String txt = n.trim();
            if (txt.length < 15) txt = txt.padRight(15, ' ');
            return txt;
          }).join('\n');

          int numCircles = 0;
          int numSquares = 0;
          
          if (p.shapeType.contains('cột đôi tròn')) {
            numCircles = 2;
          } else if (p.shapeType.contains('cột tròn')) {
            numCircles = 1;
          }
          if (p.shapeType.contains('cột đôi')) {
            numSquares = 2;
          } else if (p.shapeType.contains('cột vuông')) {
            numSquares = 1;
          }

          String imageName = p.imagePath != null ? p.imagePath!.split('/').last.split('\\').last : "";

          rows.add([i + 1, p.position.longitude, p.position.latitude, p.name, combinedNotes, imageName, numCircles, numSquares, p.branchName, vn2000[0].toStringAsFixed(3), vn2000[1].toStringAsFixed(3), segmentName, dist.toStringAsFixed(2)]);
        }

        String csv = const ListToCsvConverter().convert(rows);
        String csvWithBOM = '\uFEFF$csv'; 

        final directory = await getTemporaryDirectory();
        final path = '${directory.path}/du_lieu_do_dat_$selectedProvince.csv';
        final file = File(path);
        await file.writeAsString(csvWithBOM);

        List<String> shareFiles = [path];
        for (var p in _points) {
          if (p.imagePath != null && File(p.imagePath!).existsSync()) {
            shareFiles.add(p.imagePath!);
          }
        }

        await _handleFileExport(shareFiles, 'File Excel (CSV) và các ảnh đính kèm dữ liệu đo đạc tại $selectedProvince');
      }
    });
  }

  Future<void> _handleFileExport(List<String> paths, String shareText) async {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xuất file thành công!', style: TextStyle(color: Colors.green)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Bạn muốn làm gì với các file này?'),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Lưu vào điện thoại'),
                onPressed: () async {
                  Navigator.pop(context);
                  if (paths.length == 1) {
                    String fileName = paths.first.split('/').last.split('\\').last;
                    Uint8List bytes = await File(paths.first).readAsBytes();
                    String? result = await FilePicker.platform.saveFile(
                      dialogTitle: 'Chọn vị trí lưu file',
                      fileName: fileName,
                      bytes: bytes,
                    );
                    if (result != null) {
                      _showSnackBar('Đã lưu file thành công!');
                    }
                  } else {
                    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                    if (selectedDirectory != null) {
                      int successCount = 0;
                      for (String path in paths) {
                        String fileName = path.split('/').last.split('\\').last;
                        try {
                          await File(path).copy('$selectedDirectory/$fileName');
                          successCount++;
                        } catch (e) {
                          // ignore
                        }
                      }
                      _showSnackBar('Đã lưu $successCount file vào thư mục đã chọn!');
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green, 
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 45)
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                icon: const Icon(Icons.share),
                label: const Text('Chia sẻ (Zalo, Drive...)'),
                onPressed: () {
                  Navigator.pop(context);
                  Share.shareXFiles(paths.map((p) => XFile(p)).toList(), text: shareText);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent, 
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 45)
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _exportToKMZ() async {
    if (_points.isEmpty) {
      _showSnackBar('Chưa có dữ liệu để xuất.');
      return;
    }

    String modeFileName = '';
    String modeDisplayName = '';
    if (_currentMode == AppMode.area) {
      modeFileName = 'dien_tich';
      modeDisplayName = 'Diện Tích';
    } else if (_currentMode == AppMode.distance) {
      modeFileName = 'khoang_cach';
      modeDisplayName = 'Khoảng Cách';
    } else {
      modeFileName = 'toa_do';
      modeDisplayName = 'Tọa Độ';
    }

    StringBuffer kml = StringBuffer();
    kml.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    kml.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
    kml.writeln('<Document>');
    kml.writeln('  <name>Du Lieu Do Dat - $modeDisplayName</name>');

    var archive = Archive();

    String toKmlColor(int colorValue) {
      String hex = colorValue.toRadixString(16).padLeft(8, '0');
      String aa = hex.substring(0, 2);
      String rr = hex.substring(2, 4);
      String gg = hex.substring(4, 6);
      String bb = hex.substring(6, 8);
      return '$aa$bb$gg$rr';
    }

    for (var p in _points) {
      kml.writeln('  <Placemark>');
      kml.writeln('    <name>${p.name} (${p.branchName})</name>');
      
      kml.writeln('    <Style>');
      kml.writeln('      <IconStyle>');
      kml.writeln('        <color>${toKmlColor(p.colorValue)}</color>');
      kml.writeln('        <scale>1.2</scale>');
      if (p.shapeType.contains('tròn')) {
         kml.writeln('        <Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon>');
      } else if (p.shapeType.contains('vuông')) {
         kml.writeln('        <Icon><href>http://maps.google.com/mapfiles/kml/shapes/polygon.png</href></Icon>');
      } else if (p.shapeType.contains('trạm')) {
         kml.writeln('        <Icon><href>http://maps.google.com/mapfiles/kml/shapes/info-i.png</href></Icon>');
      } else {
         kml.writeln('        <Icon><href>http://maps.google.com/mapfiles/kml/pushpin/ylw-pushpin.png</href></Icon>');
      }
      kml.writeln('      </IconStyle>');
      kml.writeln('      <LabelStyle><color>${toKmlColor(p.colorValue)}</color></LabelStyle>');
      kml.writeln('    </Style>');

      kml.writeln('    <description><![CDATA[');
      String notesStr = p.notes.where((n) => n.trim().isNotEmpty).join(', ');
      if (notesStr.isNotEmpty) kml.writeln('      Ghi chú: $notesStr <br/>');
      if (p.imagePath != null && File(p.imagePath!).existsSync()) {
        String fileName = p.imagePath!.split('/').last.split('\\').last;
        kml.writeln('      <img src="images/$fileName" width="400" /><br/>');
        List<int> imageBytes = File(p.imagePath!).readAsBytesSync();
        archive.addFile(ArchiveFile('images/$fileName', imageBytes.length, imageBytes));
      }
      kml.writeln('    ]]></description>');

      kml.writeln('    <ExtendedData>');
      kml.writeln('      <Data name="segmentName"><value>${p.segmentName}</value></Data>');
      kml.writeln('      <Data name="shapeType"><value>${p.shapeType}</value></Data>');
      kml.writeln('      <Data name="colorValue"><value>${p.colorValue}</value></Data>');
      if (p.imagePath != null && File(p.imagePath!).existsSync()) {
        String fileName = p.imagePath!.split('/').last.split('\\').last;
        kml.writeln('      <Data name="imagePath"><value>images/$fileName</value></Data>');
      }
      for (int i = 0; i < p.notes.length; i++) {
        if (p.notes[i].trim().isNotEmpty) {
          kml.writeln('      <Data name="GhiChu_${i+1}"><value>${p.notes[i]}</value></Data>');
        }
      }
      kml.writeln('    </ExtendedData>');

      kml.writeln('    <Point>');
      kml.writeln('      <coordinates>${p.position.longitude},${p.position.latitude},0</coordinates>');
      kml.writeln('    </Point>');
      kml.writeln('  </Placemark>');
    }

    var mainPoints = _points.where((p) => p.branchName == 'Chính').toList();

    if (_currentMode == AppMode.area && mainPoints.length >= 3) {
      kml.writeln('  <Placemark>');
      kml.writeln('    <name>Mảnh Đất Chính</name>');
      kml.writeln('    <Style><LineStyle><color>ff0000ff</color><width>2</width></LineStyle><PolyStyle><color>400000ff</color></PolyStyle></Style>');
      kml.writeln('    <Polygon>');
      kml.writeln('      <outerBoundaryIs><LinearRing><coordinates>');
      for (var p in mainPoints) {
        kml.write('${p.position.longitude},${p.position.latitude},0 ');
      }
      kml.write('${mainPoints.first.position.longitude},${mainPoints.first.position.latitude},0');
      kml.writeln('      </coordinates></LinearRing></outerBoundaryIs>');
      kml.writeln('    </Polygon>');
      kml.writeln('  </Placemark>');
    }

    var allBranches = _points.map((e) => e.branchName).toSet().toList();
    for (var b in allBranches) {
      var bPoints = _points.where((p) => p.branchName == b).toList();
      if (bPoints.length >= 2) {
        List<LandPoint> linePoints = List.from(bPoints);
        if (b != 'Chính' && mainPoints.isNotEmpty) {
           var closest = mainPoints.reduce((curr, next) => 
               Geolocator.distanceBetween(curr.position.latitude, curr.position.longitude, bPoints.first.position.latitude, bPoints.first.position.longitude) < 
               Geolocator.distanceBetween(next.position.latitude, next.position.longitude, bPoints.first.position.latitude, bPoints.first.position.longitude) ? curr : next);
           linePoints.insert(0, closest);
        }

        kml.writeln('  <Placemark>');
        kml.writeln('    <name>${b == 'Chính' ? 'Đường Đo Chính' : 'Nhánh: $b'}</name>');
        kml.writeln('    <Style><LineStyle><color>${toKmlColor(bPoints.first.colorValue)}</color><width>3</width></LineStyle></Style>');
        kml.writeln('    <LineString>');
        kml.writeln('      <coordinates>');
        for (var p in linePoints) {
          kml.write('${p.position.longitude},${p.position.latitude},0 ');
        }
        kml.writeln('      </coordinates>');
        kml.writeln('    </LineString>');
        kml.writeln('  </Placemark>');

        for (int i = 0; i < linePoints.length - 1; i++) {
          double dist = Geolocator.distanceBetween(
            linePoints[i].position.latitude, linePoints[i].position.longitude,
            linePoints[i+1].position.latitude, linePoints[i+1].position.longitude,
          );
          double midLat = (linePoints[i].position.latitude + linePoints[i+1].position.latitude) / 2;
          double midLon = (linePoints[i].position.longitude + linePoints[i+1].position.longitude) / 2;
          String segName = linePoints[i+1].segmentName;
          String labelText = '${dist.toStringAsFixed(2)}m';
          if (segName.isNotEmpty) labelText += ' - $segName';

          kml.writeln('  <Placemark>');
          kml.writeln('    <name>$labelText</name>');
          kml.writeln('    <ExtendedData><Data name="isDistanceLabel"><value>true</value></Data></ExtendedData>');
          kml.writeln('    <Style>');
          kml.writeln('      <IconStyle><scale>0</scale></IconStyle>');
          kml.writeln('      <LabelStyle><color>ff00ffff</color><scale>1.0</scale></LabelStyle>');
          kml.writeln('    </Style>');
          kml.writeln('    <Point>');
          kml.writeln('      <coordinates>$midLon,$midLat,0</coordinates>');
          kml.writeln('    </Point>');
          kml.writeln('  </Placemark>');
        }
      }
    }

    kml.writeln('</Document>');
    kml.writeln('</kml>');

    List<int> kmlBytes = utf8.encode(kml.toString());
    archive.addFile(ArchiveFile('doc.kml', kmlBytes.length, kmlBytes));
    List<int>? kmzBytes = ZipEncoder().encode(archive);

    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/du_lieu_do_dat_$modeFileName.kmz';
    final file = File(path);
    await file.writeAsBytes(kmzBytes!);

    await _handleFileExport([path], 'File Google Earth (KMZ) dữ liệu đo đạc ($modeDisplayName)');
  }

  Future<void> _exportToDXFUI() async {
    if (_points.isEmpty) {
      _showSnackBar('Chưa có dữ liệu để xuất.');
      return;
    }

    String selectedProvince = 'Hà Nội';

    bool proceed = await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Xuất file Bản Vẽ CAD (.dxf)'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Chọn Tỉnh/Thành phố để nội suy hệ tọa độ VN2000 chuẩn:'),
                  const SizedBox(height: 10),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: selectedProvince,
                    items: VN2000Converter.provinces.keys.map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      setDialogState(() {
                        selectedProvince = newValue!;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Hủy'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                  child: const Text('Tạo DXF'),
                ),
              ],
            );
          },
        );
      },
    ) ?? false;

    if (proceed) {
      String? path = await exportToDXF(context, _points, selectedProvince);
      if (path != null) {
        await _handleFileExport([path], 'Bản vẽ CAD dữ liệu đo đạc tại $selectedProvince');
      }
    }
  }

  void _showSnackBar(String message, {Duration duration = const Duration(seconds: 2)}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: duration),
    );
  }

  bool _pointExists(List<LandPoint> list, ll.LatLng pt) {
    for (var p in list) {
      if ((p.position.latitude - pt.latitude).abs() < 0.000001 &&
          (p.position.longitude - pt.longitude).abs() < 0.000001) {
        return true;
      }
    }
    return false;
  }

  Future<void> _importKML() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['kml', 'kmz'],
      );

      if (result != null) {
        String path = result.files.single.path!;
        String fileName = path.toLowerCase();
        
        String xmlString = '';

        Map<String, List<int>> extractedImages = {};
        if (fileName.endsWith('.kmz')) {
          final bytes = File(path).readAsBytesSync();
          final archive = ZipDecoder().decodeBytes(bytes);
          for (final file in archive) {
            if (file.name.toLowerCase().endsWith('.kml')) {
              xmlString = utf8.decode(file.content);
            } else if (file.name.toLowerCase().startsWith('images/')) {
              extractedImages[file.name] = file.content as List<int>;
            }
          }
        } else {
          xmlString = await File(path).readAsString();
        }

        if (xmlString.isEmpty) {
          _showSnackBar('File không hợp lệ hoặc rỗng.');
          return;
        }

        final document = xml.XmlDocument.parse(xmlString);
        
        var docNameNode = document.findAllElements('Document').firstOrNull?.findElements('name').firstOrNull;
        String docName = docNameNode?.innerText.toLowerCase() ?? '';

        AppMode? importedMode;
        if (fileName.contains('dien_tich') || fileName.contains('area') || docName.contains('dien tich') || docName.contains('diện tích')) {
          importedMode = AppMode.area;
        } else if (fileName.contains('khoang_cach') || fileName.contains('distance') || docName.contains('khoang cach') || docName.contains('khoảng cách')) {
          importedMode = AppMode.distance;
        } else if (fileName.contains('toa_do') || fileName.contains('coordinate') || docName.contains('toa do') || docName.contains('tọa độ')) {
          importedMode = AppMode.coordinate;
        }

        final placemarks = document.findAllElements('Placemark');
        
        List<LandPoint> importedPoints = [];
        final directory = await getApplicationDocumentsDirectory();
        
        for (var placemark in placemarks) {
          String rawName = placemark.findElements('name').firstOrNull?.innerText ?? 'Điểm';
          String name = rawName;
          String branch = 'Chính';
          if (name.contains('(') && name.endsWith(')')) {
            int openParen = name.lastIndexOf('(');
            branch = name.substring(openParen + 1, name.length - 1);
            name = name.substring(0, openParen).trim();
          }

          String segmentName = '';
          String shapeType = 'none';
          List<String> notes = List.filled(7, '');
          String? localImagePath;

          var extData = placemark.findElements('ExtendedData').firstOrNull;
          bool isDistance = false;
          int colorValue = branch == 'Chính' ? 0xFFF44336 : 0xFFFFFF00;

          if (extData != null) {
            var dataNodes = extData.findElements('Data');
            for (var data in dataNodes) {
              var nameAttr = data.getAttribute('name');
              var value = data.findElements('value').firstOrNull?.innerText ?? '';
              if (nameAttr == 'isDistanceLabel' && value == 'true') {
                isDistance = true;
              }
              else if (nameAttr == 'colorValue' && value.isNotEmpty) {
                colorValue = int.tryParse(value) ?? colorValue;
              }
              else if (nameAttr == 'segmentName') segmentName = value;
              else if (nameAttr == 'shapeType') shapeType = value;
              else if (nameAttr == 'imagePath' && value.isNotEmpty) {
                if (extractedImages.containsKey(value)) {
                  final timestamp = DateTime.now().millisecondsSinceEpoch;
                  final imageName = value.split('/').last;
                  final savedImage = File('${directory.path}/${timestamp}_$imageName');
                  await savedImage.writeAsBytes(extractedImages[value]!);
                  localImagePath = savedImage.path;
                }
              }
              else if (nameAttr != null && nameAttr.startsWith('GhiChu_')) {
                int? idx = int.tryParse(nameAttr.split('_')[1]);
                if (idx != null && idx >= 1 && idx <= 7) {
                  notes[idx - 1] = value;
                }
              }
            }
          }
          
          if (isDistance) continue;
          
          var pointNodes = placemark.findAllElements('Point');
          for (var pointNode in pointNodes) {
            var coordsNode = pointNode.findAllElements('coordinates').firstOrNull;
            if (coordsNode != null) {
              var coords = coordsNode.innerText.trim().split(',');
              if (coords.length >= 2) {
                var pt = ll.LatLng(double.parse(coords[1]), double.parse(coords[0]));
                if (!_pointExists(_points, pt) && !_pointExists(importedPoints, pt)) {
                  importedPoints.add(LandPoint(
                    position: pt,
                    name: name,
                    branchName: branch,
                    segmentName: segmentName,
                    shapeType: shapeType,
                    notes: notes,
                    imagePath: localImagePath,
                    colorValue: colorValue,
                  ));
                }
              }
            }
          }
          
          var lineNodes = placemark.findAllElements('LineString');
          for (var lineNode in lineNodes) {
            var coordsNode = lineNode.findAllElements('coordinates').firstOrNull;
            if (coordsNode != null) {
              var coordsList = coordsNode.innerText.trim().split(RegExp(r'\s+'));
              for (int i = 0; i < coordsList.length; i++) {
                if (coordsList[i].trim().isEmpty) continue;
                var coords = coordsList[i].split(',');
                if (coords.length >= 2) {
                  var pt = ll.LatLng(double.parse(coords[1]), double.parse(coords[0]));
                  if (!_pointExists(_points, pt) && !_pointExists(importedPoints, pt)) {
                    importedPoints.add(LandPoint(
                      position: pt,
                      name: '${name}_L$i',
                      branchName: branch,
                      segmentName: segmentName,
                      shapeType: shapeType,
                      notes: notes,
                      imagePath: localImagePath,
                    ));
                  }
                }
              }
            }
          }

          var polyNodes = placemark.findAllElements('Polygon');
          for (var polyNode in polyNodes) {
            var coordsNode = polyNode.findAllElements('coordinates').firstOrNull;
            if (coordsNode != null) {
              var coordsList = coordsNode.innerText.trim().split(RegExp(r'\s+'));
              for (int i = 0; i < coordsList.length; i++) {
                if (coordsList[i].trim().isEmpty) continue;
                var coords = coordsList[i].split(',');
                if (coords.length >= 2) {
                  var pt = ll.LatLng(double.parse(coords[1]), double.parse(coords[0]));
                  if (!_pointExists(_points, pt) && !_pointExists(importedPoints, pt)) {
                    importedPoints.add(LandPoint(
                      position: pt,
                      name: '${name}_P$i',
                      branchName: branch,
                      segmentName: segmentName,
                      shapeType: shapeType,
                      notes: notes,
                      imagePath: localImagePath,
                    ));
                  }
                }
              }
            }
          }
        }
        
        if (importedPoints.isNotEmpty) {
          setState(() {
            _points.addAll(importedPoints);
            if (importedMode != null) {
              _currentMode = importedMode;
            }
          });
          _calculateArea();
          _mapController.move(importedPoints.first.position, 14.0);
          _showSnackBar('Đã nhập ${importedPoints.length} điểm từ KML.');
        } else {
          _showSnackBar('Không tìm thấy điểm tọa độ mới nào trong file.');
        }
      }
    } catch (e) {
      _showSnackBar('Lỗi khi nhập file: $e');
    }
  }

  void _clearAllPoints() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xác nhận xóa'),
          content: const Text('Bạn có chắc chắn muốn xóa toàn bộ điểm đang có trên bản đồ để bắt đầu bản vẽ mới không?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () {
                setState(() {
                  _points.clear();
                  _currentBranch = 'Chính';
                });
                _calculateArea();
                Navigator.pop(context);
                _showSnackBar('Đã xóa toàn bộ điểm.');
              },
              child: const Text('Xóa toàn bộ'),
            ),
          ],
        );
      },
    );
  }

  void _showAdminPanel() {
    TextEditingController deviceIdController = TextEditingController();
    String generatedCode = '';
    
    showDialog(
      context: context,
      builder: (c) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('BẢNG QUẢN TRỊ ADMIN', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Nhập Mã thiết bị (Device ID) của khách hàng để tạo Mã kích hoạt VIP.'),
                  const SizedBox(height: 15),
                  TextField(
                    controller: deviceIdController,
                    decoration: const InputDecoration(
                      labelText: 'Mã thiết bị của khách',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 15),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                    onPressed: () {
                      if (deviceIdController.text.trim().isNotEmpty) {
                        setDialogState(() {
                          generatedCode = _generateActivationCode(deviceIdController.text.trim());
                        });
                      }
                    },
                    child: const Text('TẠO MÃ KÍCH HOẠT'),
                  ),
                  if (generatedCode.isNotEmpty) ...[
                    const SizedBox(height: 15),
                    Container(
                      padding: const EdgeInsets.all(10),
                      color: Colors.yellow[100],
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('Mã Kích Hoạt:\n$generatedCode', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.red)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, color: Colors.blue),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: generatedCode));
                              _showSnackBar('Đã copy Mã kích hoạt!');
                            },
                          )
                        ],
                      ),
                    ),
                  ]
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('ĐÓNG'),
                ),
              ],
            );
          }
        );
      }
    );
  }

  void _showAboutDialog() {
    int adminTapCount = 0;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('HƯỚNG DẪN SỬ DỤNG MINHGPS - V', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 18)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    adminTapCount++;
                    if (adminTapCount >= 10) {
                      adminTapCount = 0;
                      Navigator.pop(context); // Đóng bảng Hướng dẫn
                      _showAdminPanel(); // Mở Bảng quản trị
                    }
                  },
                  child: Container(
                    color: Colors.transparent, // Bắt sự kiện tốt hơn
                    child: const Text('Tác giả:', style: TextStyle(fontSize: 14)),
                  ),
                ),
                const Text('Vũ Tiến Vĩnh, Lê Minh Hiếu, Trần Văn Đại', style: TextStyle(fontSize: 16, color: Colors.green, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('1. CÁC THAO TÁC CƠ BẢN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue)),
                const Text('• Chấm điểm: Chạm vào bản đồ để tạo điểm.\n• Chọn Tỉnh/Thành phố ở góc trên cùng bên phải để xuất hệ tọa độ VN2000 cực chuẩn.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                const Text('2. QUẢN LÝ ĐIỂM (NÚT BẤM)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue)),
                const Text('• Mũi tên (Undo): Xóa điểm vừa chấm.\n• Thùng rác: Xóa sạch bản vẽ.\n• Cành cây (Tạo Nhánh): Tách đường nhánh phụ (không dính líu vào đường Chính).', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                const Text('3. KÝ HIỆU HÌNH HỌC THÔNG MINH\n(Nhấn giữ vào điểm để hiện Menu)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue)),
                const Text('Các ký hiệu cột/trạm được chọn tại menu điểm.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                const Text('4. NHẬP GHI CHÚ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue)),
                const Text('• Sử dụng Bảng Ghi Chú để nhập liệu.\n• Có thể đính kèm ảnh chụp có thông tin tọa độ.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                const Text('5. BẢNG THỐNG KÊ (VUỐT LÊN)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue)),
                const Text('• Diện tích khép kín đường Chính.\n• Tổng chiều dài các đường nhánh.', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
                const Text('6. XUẤT EXCEL & KMZ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue)),
                const Text('• Xuất CSV hỗ trợ VN2000 và tính toán tự động.\n• Xuất KMZ để xem trực tiếp trên Google Earth.', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ĐÃ HIỂU & ĐÓNG', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
            ),
          ],
        );
      },
    );
  }

  void _showStatsBottomSheet() {
    Map<String, double> branchDistances = {};
    var allBranchNames = _points.map((e) => e.branchName).toSet().toList();
    for (var b in allBranchNames) {
      double dist = 0.0;
      var bPoints = _points.where((p) => p.branchName == b).toList();
      for (int i = 0; i < bPoints.length - 1; i++) {
        dist += Geolocator.distanceBetween(
          bPoints[i].position.latitude, bPoints[i].position.longitude,
          bPoints[i+1].position.latitude, bPoints[i+1].position.longitude,
        );
      }
      branchDistances[b] = dist;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Thống kê đo đạc', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.square_foot, color: Colors.green),
                  title: const Text('Diện tích viền chính'),
                  trailing: Text('${_calculatedAreaSqMeters.toStringAsFixed(2)} m²', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
                ),
                ...branchDistances.entries.map((e) => ListTile(
                  leading: const Icon(Icons.straighten, color: Colors.blue),
                  title: Text(e.key == 'Chính' ? 'Tổng chiều dài chính' : 'Tổng chiều dài ${e.key}'),
                  trailing: Text('${e.value.toStringAsFixed(2)} m', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
                )).toList(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      }
    );
  }

  void _showShapeSelectionPanel(int index) {
    final List<String> shapes = ['none', 'cột tròn', 'cột vuông', 'cột đôi tròn ngang', 'cột đôi dọc', 'cột đôi V-N', 'cột đôi V-D', 'trạm hợp bộ', 'trạm 1 cột', 'trạm treo'];
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Tùy Chỉnh Ký Hiệu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: shapes.map((s) => ChoiceChip(
                  label: Text(s == 'none' ? 'Bỏ chọn' : s),
                  selected: _points[index].shapeType == s,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _points[index].shapeType = s;
                        _saveData();
                      });
                      Navigator.pop(context);
                    }
                  },
                )).toList(),
              ),
            ],
          ),
        );
      }
    );
  }

  void _showNoteDialog(int index) {
    List<TextEditingController> controllers = List.generate(
      7, (i) => TextEditingController(text: _points[index].notes.length > i ? _points[index].notes[i] : '')
    );

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Bảng Ghi Chú (Tối đa 15 ký tự/dòng)', style: TextStyle(fontSize: 14)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(7, (i) {
                return TextField(
                  controller: controllers[i],
                  maxLength: 15,
                  decoration: const InputDecoration(
                    counterText: '',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                );
              }),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _points[index].notes = controllers.map((c) => c.text).toList();
                  _saveData();
                });
                Navigator.pop(context);
              },
              child: const Text('Lưu'),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    // Tách riêng điểm chính để vẽ đa giác (Polygon)
    var mainPolygonPoints = _points.where((p) => p.branchName == 'Chính').map((e) => e.position).toList();
    
    // Tách riêng các nhánh để vẽ đường kẻ
    var allBranchNames = _points.map((e) => e.branchName).toSet().toList();
    
    List<Polyline> branchPolylines = [];
    List<Polyline> redPolylines = [];
    List<Marker> distanceMarkers = [];
    double totalDistance = 0.0;
    
    var mainPoints = _points.where((p) => p.branchName == 'Chính').toList();

    for (var b in allBranchNames) {
      var bPoints = _points.where((p) => p.branchName == b).toList();
      if (bPoints.length >= 2) {
        List<ll.LatLng> latLngs = bPoints.map((e) => e.position).toList();

        if (mainPoints.isNotEmpty && bPoints.isNotEmpty) {
           var closest = mainPoints.reduce((curr, next) => 
               Geolocator.distanceBetween(curr.position.latitude, curr.position.longitude, bPoints.first.position.latitude, bPoints.first.position.longitude) < 
               Geolocator.distanceBetween(next.position.latitude, next.position.longitude, bPoints.first.position.latitude, bPoints.first.position.longitude) ? curr : next);
           latLngs.insert(0, closest.position);
        }

        if (b != 'Chính') {
          // Find the first segment's color or use the default branch color
          Color polyColor = Color(bPoints.first.colorValue);
          branchPolylines.add(Polyline(
            points: latLngs,
            strokeWidth: 3.0,
            color: polyColor,
          ));
        }

        List<ll.LatLng> distanceLinePoints = latLngs;

        // Draw segments with individual colors
        for (int i = 0; i < distanceLinePoints.length - 1; i++) {
          Color segColor = b == 'Chính' ? Colors.red : Colors.yellowAccent;
          if (i == 0 && distanceLinePoints.length > bPoints.length) {
            // This is the auto-connect segment from main to branch. Use the branch's first point color.
            segColor = Color(bPoints.first.colorValue);
          } else {
            // Find the point corresponding to distanceLinePoints[i+1]
            int idx = i;
            if (distanceLinePoints.length > bPoints.length) idx = i - 1;
            if (idx >= 0 && idx + 1 < bPoints.length) {
               segColor = Color(bPoints[idx + 1].colorValue);
            }
          }

          redPolylines.add(Polyline(
            points: [distanceLinePoints[i], distanceLinePoints[i+1]],
            strokeWidth: 3.0,
            color: segColor,
          ));
        }

        for (int i = 0; i < distanceLinePoints.length - 1; i++) {
          double dist = Geolocator.distanceBetween(
            distanceLinePoints[i].latitude, distanceLinePoints[i].longitude,
            distanceLinePoints[i+1].latitude, distanceLinePoints[i+1].longitude,
          );
          totalDistance += dist;
          
          ll.LatLng mid = ll.LatLng(
            (distanceLinePoints[i].latitude + distanceLinePoints[i+1].latitude) / 2,
            (distanceLinePoints[i].longitude + distanceLinePoints[i+1].longitude) / 2,
          );
          
          double bearing = _calculateBearing(distanceLinePoints[i], distanceLinePoints[i+1]);
          double angle = bearing - math.pi / 2;
          
          if (angle < -math.pi / 2 || angle > math.pi / 2) {
             angle += math.pi;
          }

          String segName = bPoints[i+1].segmentName;

          distanceMarkers.add(Marker(
            point: mid,
            width: 150,
            height: 80,
            child: Transform.rotate(
              angle: angle,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${dist.toStringAsFixed(2)} m',
                    style: const TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold, backgroundColor: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  if (segName.isNotEmpty)
                    Text(
                      segName,
                      style: const TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.bold, backgroundColor: Colors.white70),
                    ),
                ],
              ),
            ),
          ));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('MINHGPS', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green[700],
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white),
            onPressed: _showAboutDialog,
            tooltip: 'Hướng dẫn & Tác giả',
          ),
          IconButton(
            icon: const Icon(Icons.my_location, color: Colors.white),
            onPressed: _getCurrentLocation,
            tooltip: 'Đến vị trí hiện tại',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.share, color: Colors.white),
            onSelected: (value) {
              if (value == 'csv') _exportToCSV();
              if (value == 'kml') _exportToKMZ();
              if (value == 'dxf') _exportToDXFUI();
              if (value == 'import') _importKML();
              if (value == 'clear') _clearAllPoints();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear',
                child: Text('🗑 Xóa toàn bộ điểm', style: TextStyle(color: Colors.red)),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Text('📥 Nhập file KML/KMZ'),
              ),
              const PopupMenuItem(
                value: 'csv',
                child: Text('📤 Xuất file Excel (.csv)'),
              ),
              const PopupMenuItem(
                value: 'dxf',
                child: Text('📤 Xuất bản vẽ CAD (.dxf)'),
              ),
              const PopupMenuItem(
                value: 'kml',
                child: Text('🌍 Xuất Google Earth (.kmz)'),
              ),
            ],
          )
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const ll.LatLng(14.0583, 108.2772),
              initialZoom: 6.0,
              onTap: (tapPosition, point) => _handleMapTap(point),
              onPositionChanged: (camera, hasGesture) {
                if (hasGesture && _alignPositionOnUpdate == AlignOnUpdate.always) {
                  setState(() {
                    _alignPositionOnUpdate = AlignOnUpdate.never;
                  });
                }
                if (_movingPointIndex != null && hasGesture) {
                  setState(() {
                    _points[_movingPointIndex!].position = camera.center!;
                    _calculateArea();
                  });
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}',
                userAgentPackageName: 'com.example.land_area_app',
              ),
              CurrentLocationLayer(
                alignPositionOnUpdate: _alignPositionOnUpdate,
                positionStream: const LocationMarkerDataStreamFactory().defaultPositionStream().handleError((_) {}),
                headingStream: FlutterCompass.events?.handleError((_) {}).map((CompassEvent e) => LocationMarkerHeading(
                  heading: (e.heading ?? 0) * (math.pi / 180),
                  accuracy: (e.accuracy ?? 0) * (math.pi / 180),
                )),
              ),
              if (_currentMode == AppMode.area && mainPolygonPoints.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: mainPolygonPoints,
                      color: Colors.blue.withOpacity(0.4),
                      borderColor: Colors.blue,
                      borderStrokeWidth: 2.0,
                      isFilled: true,
                    ),
                  ],
                ),
              if (_currentMode == AppMode.area && branchPolylines.isNotEmpty)
                PolylineLayer(
                  polylines: branchPolylines,
                ),
              if (_currentMode == AppMode.distance && redPolylines.isNotEmpty)
                PolylineLayer(
                  polylines: redPolylines,
                ),
              if (_currentMode == AppMode.distance && distanceMarkers.isNotEmpty)
                MarkerLayer(
                  markers: distanceMarkers,
                ),
              MarkerLayer(
                markers: _points.asMap().entries.map((entry) {
                  int index = entry.key;
                  LandPoint point = entry.value;
                  bool isMoving = _movingPointIndex == index;
                  bool isBranch = point.branchName != 'Chính';
                  
                  double angle = 0.0;
                  if (point.shapeType != 'none' && point.shapeType != 'bảng trống') {
                    var branchPoints = _points.where((p) => p.branchName == point.branchName).toList();
                    int bIndex = branchPoints.indexOf(point);
                    if (branchPoints.length > 1) {
                      LandPoint p1, p2;
                      if (bIndex < branchPoints.length - 1) {
                        p1 = point;
                        p2 = branchPoints[bIndex + 1];
                      } else {
                        p1 = branchPoints[bIndex - 1];
                        p2 = point;
                      }
                      angle = math.atan2(p1.position.latitude - p2.position.latitude, p2.position.longitude - p1.position.longitude);
                    }
                  }
                  
                  return Marker(
                    point: point.position,
                    width: _currentMode == AppMode.coordinate ? 180 : 160,
                    height: 160,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        if (point.shapeType != 'none')
                          IgnorePointer(
                            child: CustomPaint(
                              size: const Size(100, 100),
                              painter: ShapePainter(point.shapeType, angle, Color(point.colorValue)),
                            ),
                          ),
                        GestureDetector(
                          onTap: () => _showPointOptions(index),
                          onLongPress: () => _showShapeSelectionPanel(index),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 80,
                                height: 30,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.center,
                                  children: [
                                    Icon(
                                      Icons.location_on,
                                      color: isMoving ? Colors.orange : Color(point.colorValue),
                                      size: 30,
                                    ),
                                    if (point.notes.any((n) => n.isNotEmpty))
                                      Positioned(
                                        right: -10,
                                        child: GestureDetector(
                                          onTap: () => _showNoteDialog(index),
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              color: Colors.white,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(Icons.edit_note, color: Colors.blue, size: 24),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.8),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: _currentMode == AppMode.coordinate
                                  ? Text(
                                      '${point.name}${isBranch ? " ("+point.branchName+")" : ""}\n${point.position.latitude.toStringAsFixed(6)}, ${point.position.longitude.toStringAsFixed(6)}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isMoving ? Colors.orange : Colors.black,
                                      ),
                                      textAlign: TextAlign.center,
                                    )
                                  : Text(
                                      '${point.name}${isBranch ? " ("+point.branchName+")" : ""}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: isMoving ? Colors.orange : Colors.black,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
              // Removed manual marker layer to fix stuck location marker
            ],
          ),
          if (_isLoadingLocation)
            const Center(
              child: CircularProgressIndicator(),
            ),
          
          if (_movingPointIndex != null)
            Positioned(
              top: 10,
              left: 20,
              right: 20,
              child: Card(
                color: Colors.orange,
                elevation: 6,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Dùng tay kéo bản đồ để dời điểm.\nDiện tích sẽ cập nhật theo.',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.orange,
                        ),
                        onPressed: () {
                          setState(() {
                            _movingPointIndex = null;
                          });
                          _showSnackBar('Đã cập nhật vị trí mới.');
                        },
                        child: const Text('XONG', style: TextStyle(fontWeight: FontWeight.bold)),
                      )
                    ],
                  ),
                ),
              ),
            ),

          Positioned(
            top: _movingPointIndex != null ? 80 : 20,
            left: 10,
            right: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SegmentedButton<AppMode>(
                    segments: const [
                      ButtonSegment(value: AppMode.area, label: Text('Diện tích', style: TextStyle(fontSize: 12))),
                      ButtonSegment(value: AppMode.distance, label: Text('Khoảng cách', style: TextStyle(fontSize: 12))),
                      ButtonSegment(value: AppMode.coordinate, label: Text('Tọa độ', style: TextStyle(fontSize: 12))),
                    ],
                    selected: <AppMode>{_currentMode},
                    onSelectionChanged: (Set<AppMode> newSelection) {
                      setState(() {
                        _currentMode = newSelection.first;
                      });
                    },
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.9),
                      selectedBackgroundColor: Colors.green.withOpacity(0.8),
                      selectedForegroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<Color>(
                  icon: Icon(Icons.palette, color: _currentColor),
                  tooltip: 'Chọn Màu Ghi Chú/Dây',
                  onSelected: (Color color) {
                    setState(() {
                      _currentColor = color;
                    });
                  },
                  itemBuilder: (context) {
                    return _presetColors.map((Color color) {
                      return PopupMenuItem<Color>(
                        value: color,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.grey),
                          ),
                        ),
                      );
                    }).toList();
                  },
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  heroTag: "stats",
                  mini: true,
                  onPressed: _showStatsBottomSheet,
                  backgroundColor: Colors.white.withOpacity(0.9),
                  child: const Icon(Icons.analytics, color: Colors.green),
                ),
              ],
            ),
          ),
          // Dấu thập trôi nổi, có thể kéo thả
          Builder(
            builder: (context) {
              Offset pos = _crosshairPos ?? Offset(MediaQuery.of(context).size.width / 2, (MediaQuery.of(context).size.height - kToolbarHeight) / 2);
              return Positioned(
                left: pos.dx - 30, // 30 là nửa kích thước (60/2)
                top: pos.dy - 30,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      _crosshairPos = pos + details.delta;
                    });
                  },
                  onTap: () {
                    var pt = _mapController.camera.pointToLatLng(math.Point(pos.dx, pos.dy));
                    if (pt != null) {
                      _handleMapTap(pt);
                    }
                  },
                  child: Container(
                    width: 60,
                    height: 60,
                    color: Colors.transparent, // Phải có màu để bắt sự kiện vuốt/chạm
                    child: CustomPaint(
                      painter: CrosshairPainter(),
                    ),
                  ),
                ),
              );
            }
          ),
        ],
      ),
    );
  }
}

class CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    
    final center = Offset(size.width / 2, size.height / 2);
    
    // Vòng tròn tâm 2mm (~12px, radius 6px)
    canvas.drawCircle(center, 6.0, paint);
    
    // Dấu thập 10mm (~60px), trừ đi phần tâm (6px)
    canvas.drawLine(Offset(center.dx, center.dy - 30), Offset(center.dx, center.dy - 6), paint);
    canvas.drawLine(Offset(center.dx, center.dy + 6), Offset(center.dx, center.dy + 30), paint);
    canvas.drawLine(Offset(center.dx - 30, center.dy), Offset(center.dx - 6, center.dy), paint);
    canvas.drawLine(Offset(center.dx + 6, center.dy), Offset(center.dx + 30, center.dy), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class VN2000Converter {
  static const double a = 6378137.0;
  static const double invf = 298.257223563;
  static const double f = 1.0 / invf;
  static const double b = a * (1.0 - f);
  static const double e2 = 1.0 - (b * b) / (a * a);
  static const double ep2 = e2 / (1.0 - e2);

  static const double dx = 191.90441429;
  static const double dy = 39.30318279;
  static const double dz = 111.4503283;
  static const double rx = 0.00928836 * math.pi / 180.0 / 3600.0;
  static const double ry = -0.01975479 * math.pi / 180.0 / 3600.0;
  static const double rz = 0.00427372 * math.pi / 180.0 / 3600.0;
  static const double ds = -0.000000000000252906277;

  static const double fe = 500000.0;
  static const double fn = 0.0;
  static const double k0 = 0.9999;

  static double _meridianArc(double a, double e2, double lat) {
    double e4 = e2 * e2;
    double e6 = e4 * e2;
    
    double term1 = (1.0 - e2 / 4.0 - 3.0 * e4 / 64.0 - 5.0 * e6 / 256.0) * lat;
    double term2 = (3.0 * e2 / 8.0 + 3.0 * e4 / 32.0 + 45.0 * e6 / 1024.0) * math.sin(2.0 * lat);
    double term3 = (15.0 * e4 / 256.0 + 45.0 * e6 / 1024.0) * math.sin(4.0 * lat);
    double term4 = (35.0 * e6 / 3072.0) * math.sin(6.0 * lat);
    
    return a * (term1 - term2 + term3 - term4);
  }

  static List<double> wgs84ToVn2000(double lat, double lon, double l0) {
    double latR = lat * math.pi / 180.0;
    double lonR = lon * math.pi / 180.0;
    double l0R = l0 * math.pi / 180.0;
    
    double n0 = a / math.sqrt(1.0 - e2 * math.pow(math.sin(latR), 2));
    double xw = n0 * math.cos(latR) * math.cos(lonR);
    double yw = n0 * math.cos(latR) * math.sin(lonR);
    double zw = ((1.0 - e2) * n0) * math.sin(latR);

    double xv = dx + (1.0 + ds) * (xw + rz * yw - ry * zw);
    double yv = dy + (1.0 + ds) * (-rz * xw + yw + rx * zw);
    double zv = dz + (1.0 + ds) * (ry * xw - rx * yw + zw);

    double p = math.sqrt(xv * xv + yv * yv);
    double theta = math.atan2(zv * a, p * b);
    
    double latVn = math.atan2(
      zv + ep2 * b * math.pow(math.sin(theta), 3),
      p - e2 * a * math.pow(math.cos(theta), 3)
    );
    double lonVn = math.atan2(yv, xv);

    double sinLat = math.sin(latVn);
    double cosLat = math.cos(latVn);
    double n = a / math.sqrt(1.0 - e2 * math.pow(sinLat, 2));
    double tan2 = math.pow(math.tan(latVn), 2).toDouble();
    double c = ep2 * math.pow(cosLat, 2);
    double aa = (lonVn - l0R) * cosLat;
    
    double a2 = aa * aa;
    double a3 = a2 * aa;
    double a4 = a2 * a2;
    double a5 = a4 * aa;
    double a6 = a4 * a2;
    
    double m = _meridianArc(a, e2, latVn);
    
    double east = fe + k0 * n * (
      aa +
      (a3 / 6.0) * (1.0 - tan2 + c) +
      (a5 / 120.0) * (5.0 - 18.0 * tan2 + tan2 * tan2 + 72.0 * c - 58.0 * ep2)
    );
    
    double north = fn + k0 * (
      m +
      n * math.tan(latVn) * (
        (a2 / 2.0) +
        (a4 / 24.0) * (5.0 - tan2 + 9.0 * c + 4.0 * c * c) +
        (a6 / 720.0) * (61.0 - 58.0 * tan2 + tan2 * tan2 + 600.0 * c - 330.0 * ep2)
      )
    );
    
    return [east, north];
  }

  static const Map<String, double> provinces = {
    'Lai Châu': 103.00, 'Điện Biên': 103.00, 'Sơn La': 104.00,
    'Lào Cai': 104.75, 'Yên Bái': 104.75, 'Hà Giang': 105.50,
    'Tuyên Quang': 106.00, 'Phú Thọ': 104.75, 'Vĩnh Phúc': 105.00,
    'Cao Bằng': 105.75, 'Lạng Sơn': 107.25, 'Bắc Kạn': 106.50,
    'Thái Nguyên': 106.50, 'Bắc Giang': 107.00, 'Bắc Ninh': 105.50,
    'Quảng Ninh': 107.75, 'TP. Hải Phòng': 105.75, 'Hải Dương': 105.50,
    'Hưng Yên': 105.50, 'Hà Nội': 105.00, 'Hòa Bình': 106.00,
    'Hà Nam': 105.00, 'Nam Định': 105.50, 'Thái Bình': 105.50,
    'Ninh Bình': 105.00, 'Thanh Hóa': 105.00, 'Nghệ An': 104.75,
    'Hà Tĩnh': 105.50, 'Quảng Bình': 106.00, 'Quảng Trị': 106.25,
    'Thừa Thiên Huế': 107.00, 'Đà Nẵng': 107.75, 'Quảng Nam': 107.75,
    'Quảng Ngãi': 108.00, 'Bình Định': 108.25, 'Kon Tum': 107.50,
    'Gia Lai': 108.50, 'Đắk Lắk': 108.50, 'Đắk Nông': 108.50,
    'Phú Yên': 108.50, 'Khánh Hòa': 108.25, 'Ninh Thuận': 108.25,
    'Bình Thuận': 108.50, 'Lâm Đồng': 107.75, 'Bình Dương': 105.75,
    'Bình Phước': 106.25, 'Đồng Nai': 107.75, 'Bà Rịa - Vũng Tàu': 107.75,
    'Tây Ninh': 105.50, 'Long An': 105.75, 'Tiền Giang': 105.75,
    'Bến Tre': 105.75, 'Đồng Tháp': 105.00, 'Vĩnh Long': 105.50,
    'Trà Vinh': 105.50, 'An Giang': 104.75, 'Kiên Giang': 104.50,
    'Cần Thơ': 105.00, 'Hậu Giang': 105.00, 'Sóc Trăng': 105.50,
    'Bạc Liêu': 105.00, 'Cà Mau': 104.50, 'TP. Hồ Chí Minh': 105.75,
  };
}

class ShapePainter extends CustomPainter {
  final String shapeType;
  final double angle;
  final Color color;

  ShapePainter(this.shapeType, this.angle, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (shapeType == 'none' || shapeType == 'bảng trống') return;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    
    final center = Offset(size.width / 2, size.height / 2);
    final r = 8.0; // Kích thước lớn gấp đôi
    final spacing = r; // Khoảng cách bằng r để 2 hình dính sát vào nhau

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    switch (shapeType) {
      case 'cột tròn':
        canvas.drawCircle(Offset.zero, r, paint);
        break;
      case 'cột vuông':
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: r * 2, height: r * 2), paint);
        break;
      case 'cột đôi tròn ngang':
        canvas.drawCircle(Offset(0, -spacing), r, paint);
        canvas.drawCircle(Offset(0, spacing), r, paint);
        break;
      case 'cột đôi dọc':
        canvas.drawCircle(Offset(-spacing, 0), r, paint);
        canvas.drawCircle(Offset(spacing, 0), r, paint);
        break;
      case 'cột đôi V-N':
        canvas.drawRect(Rect.fromCenter(center: Offset(0, -spacing), width: r * 2, height: r * 2), paint);
        canvas.drawRect(Rect.fromCenter(center: Offset(0, spacing), width: r * 2, height: r * 2), paint);
        break;
      case 'cột đôi V-D':
        canvas.drawRect(Rect.fromCenter(center: Offset(-spacing, 0), width: r * 2, height: r * 2), paint);
        canvas.drawRect(Rect.fromCenter(center: Offset(spacing, 0), width: r * 2, height: r * 2), paint);
        break;
      case 'trạm hợp bộ':
      case 'trạm 1 cột':
      case 'trạm treo':
        final r2 = 12.0; // To gấp 3 lần (bình thường là 4.0)
        final strokePaint = Paint()
          ..color = color
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        
        // Vẽ khung hình vuông viền đỏ
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: r2 * 2, height: r2 * 2), strokePaint);
        
        // Vẽ tam giác đặc đỏ (cân, đỉnh chạm mép trên, đáy chạm mép dưới)
        final redPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        Path path = Path();
        path.moveTo(0, -r2); // Đỉnh chạm mép trên
        path.lineTo(r2, r2); // Góc phải dưới
        path.lineTo(-r2, r2); // Góc trái dưới
        path.close();
        canvas.drawPath(path, redPaint);

        // Vẽ vòng tròn viền đỏ
        final circleR = r2 * 0.4; // Đường kính gần bằng 1/3 cạnh
        
        if (shapeType == 'trạm treo') {
          // 2 vòng tròn 2 bên mép trái, phải (ở giữa theo chiều dọc)
          canvas.drawCircle(Offset(-r2 - circleR, 0), circleR, strokePaint); // Trái
          canvas.drawCircle(Offset(r2 + circleR, 0), circleR, strokePaint); // Phải
        } else if (shapeType == 'trạm 1 cột') {
          // 1 vòng tròn ở mép dưới (ở giữa theo chiều ngang)
          canvas.drawCircle(Offset(0, r2 + circleR), circleR, strokePaint); // Dưới
        }
        break;
    }
    
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ShapePainter oldDelegate) {
    return oldDelegate.shapeType != shapeType || oldDelegate.angle != angle || oldDelegate.color != color;
  }
}
