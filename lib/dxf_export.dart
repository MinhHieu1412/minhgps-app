import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'main.dart'; 

Future<void> exportToDXF(BuildContext context, List<LandPoint> points, String selectedProvince) async {
  if (points.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chưa có dữ liệu để xuất.')));
    return;
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Đang tải bản đồ từ OpenStreetMap và tạo file DXF...')),
        ],
      ),
    ),
  );

  try {
    double centerLat = 0;
    double centerLon = 0;
    for (var p in points) {
      centerLat += p.position.latitude;
      centerLon += p.position.longitude;
    }
    centerLat /= points.length;
    centerLon /= points.length;

    double l0 = VN2000Converter.provinces[selectedProvince]!;

    String query = '''
      [out:json][timeout:25];
      (
        way["highway"](around:500,$centerLat,$centerLon);
        way["building"](around:500,$centerLat,$centerLon);
        way["waterway"](around:500,$centerLat,$centerLon);
        way["natural"="water"](around:500,$centerLat,$centerLon);
      );
      out geom;
    ''';
    
    var response = await http.post(
      Uri.parse('https://overpass-api.de/api/interpreter'),
      body: {'data': query},
      headers: {'User-Agent': 'MinhGPS/1.0'},
    );

    List<List<List<double>>> mapWays = []; 

    if (response.statusCode == 200) {
      var data = jsonDecode(response.body);
      var elements = data['elements'] as List;
      for (var el in elements) {
        if (el['type'] == 'way' && el['geometry'] != null) {
          List<List<double>> wayPts = [];
          for (var pt in el['geometry']) {
            var vn2000 = VN2000Converter.wgs84ToVn2000(pt['lat'], pt['lon'], l0);
            wayPts.add(vn2000);
          }
          mapWays.add(wayPts);
        }
      }
    }

    StringBuffer dxf = StringBuffer();
    void writePair(int code, dynamic val) {
      dxf.writeln(code);
      dxf.writeln(val);
    }

    dxf.write('''  0
SECTION
  2
HEADER
  0
ENDSEC
  0
SECTION
  2
TABLES
  0
TABLE
  2
LAYER
  70
5
  0
LAYER
  2
MAP_500M
  62
8
  0
LAYER
  2
DUONG_CHINH
  62
1
  0
LAYER
  2
DUONG_NHANH
  62
2
  0
LAYER
  2
KY_HIEU_CO_BAN
  62
5
  0
LAYER
  2
KY_HIEU_PHUC_HOP
  62
1
  0
ENDTAB
  0
ENDSEC
  0
SECTION
  2
ENTITIES
''');

    for (var way in mapWays) {
      if (way.length < 2) continue;
      for (int i = 0; i < way.length - 1; i++) {
        writePair(0, 'LINE');
        writePair(8, 'MAP_500M');
        writePair(10, way[i][0]);
        writePair(20, way[i][1]);
        writePair(11, way[i+1][0]);
        writePair(21, way[i+1][1]);
      }
    }

    var allBranches = points.map((e) => e.branchName).toSet().toList();
    for (var branch in allBranches) {
      var bPoints = points.where((p) => p.branchName == branch).toList();
      if (bPoints.length < 2) continue;
      
      bool isChinh = branch == 'Chính';
      String layer = isChinh ? 'DUONG_CHINH' : 'DUONG_NHANH';
      
      for (int i = 0; i < bPoints.length - 1; i++) {
        var xy1 = VN2000Converter.wgs84ToVn2000(bPoints[i].position.latitude, bPoints[i].position.longitude, l0);
        var xy2 = VN2000Converter.wgs84ToVn2000(bPoints[i+1].position.latitude, bPoints[i+1].position.longitude, l0);
        writePair(0, 'LINE');
        writePair(8, layer);
        writePair(10, xy1[0]); writePair(20, xy1[1]);
        writePair(11, xy2[0]); writePair(21, xy2[1]);
      }
      
      if (isChinh && bPoints.length >= 3) {
        var xy1 = VN2000Converter.wgs84ToVn2000(bPoints.last.position.latitude, bPoints.last.position.longitude, l0);
        var xy2 = VN2000Converter.wgs84ToVn2000(bPoints.first.position.latitude, bPoints.first.position.longitude, l0);
        writePair(0, 'LINE');
        writePair(8, layer);
        writePair(10, xy1[0]); writePair(20, xy1[1]);
        writePair(11, xy2[0]); writePair(21, xy2[1]);
      }
    }

    for (var p in points) {
      var xy = VN2000Converter.wgs84ToVn2000(p.position.latitude, p.position.longitude, l0);
      double x = xy[0];
      double y = xy[1];
      double size = 2.0; 

      String shape = p.shapeType;
      if (shape.contains('tròn')) { 
        writePair(0, 'CIRCLE');
        writePair(8, shape.contains('đỏ') ? 'KY_HIEU_PHUC_HOP' : 'KY_HIEU_CO_BAN');
        writePair(10, x);
        writePair(20, y);
        writePair(40, size);
      }
      if (shape.contains('vuông') || shape.contains('tg đỏ')) {
        String layer = shape.contains('đỏ') ? 'KY_HIEU_PHUC_HOP' : 'KY_HIEU_CO_BAN';
        // Line 1: left-bottom to right-bottom
        writePair(0, 'LINE'); writePair(8, layer);
        writePair(10, x - size); writePair(20, y - size);
        writePair(11, x + size); writePair(21, y - size);
        // Line 2: right-bottom to right-top
        writePair(0, 'LINE'); writePair(8, layer);
        writePair(10, x + size); writePair(20, y - size);
        writePair(11, x + size); writePair(21, y + size);
        // Line 3: right-top to left-top
        writePair(0, 'LINE'); writePair(8, layer);
        writePair(10, x + size); writePair(20, y + size);
        writePair(11, x - size); writePair(21, y + size);
        // Line 4: left-top to left-bottom
        writePair(0, 'LINE'); writePair(8, layer);
        writePair(10, x - size); writePair(20, y + size);
        writePair(11, x - size); writePair(21, y - size);

        if (shape.contains('tg đỏ')) {
          writePair(0, 'SOLID');
          writePair(8, 'KY_HIEU_PHUC_HOP');
          writePair(10, x - size); writePair(20, y - size); 
          writePair(11, x + size); writePair(21, y - size); 
          writePair(12, x); writePair(22, y + size);        
          writePair(13, x); writePair(23, y + size);        
        }
      }

      writePair(0, 'TEXT');
      writePair(8, 'KY_HIEU_CO_BAN');
      writePair(10, x + 2);
      writePair(20, y + 2);
      writePair(40, 2.0); 
      writePair(1, p.name);

      double noteY = y - 2;
      for (var note in p.notes) {
        if (note.trim().isNotEmpty) {
          writePair(0, 'TEXT');
          writePair(8, 'KY_HIEU_CO_BAN');
          writePair(10, x + 2);
          writePair(20, noteY);
          writePair(40, 1.5);
          writePair(1, note);
          noteY -= 2;
        }
      }
    }

    dxf.write('''  0
ENDSEC
  0
EOF
''');

    final dir = await getApplicationDocumentsDirectory();
    final String path = '${dir.path}/MINHGPS_BanVe.dxf';
    final file = File(path);
    await file.writeAsString(dxf.toString());

    if (context.mounted) Navigator.pop(context); 

    await OpenFilex.open(path);

  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi xuất DXF: $e')));
    }
  }
}
