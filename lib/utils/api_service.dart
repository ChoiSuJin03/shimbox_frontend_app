import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/signup_data.dart';
import '../models/login_data.dart';
import '../models/login_response.dart';
import '../models/test_user_data.dart' as localUser;

class ApiService {
  static const String baseUrl = 'http://116.39.208.72:26443';

  // 서버 규격(한글 상태)으로 표준화
  static const Map<String, String> _STATUS_MAP = {
    '배송대기': '배송대기',
    '배송시작': '배송시작',
    '배송완료': '배송완료',
    'WAITING': '배송대기',
    'STARTED': '배송시작',
    'COMPLETED': '배송완료',
    '대기': '배송대기',
    '시작': '배송시작',
    '완료': '배송완료',
  };
  static String _normalizeStatus(String status) {
    return _STATUS_MAP[status.trim()] ?? status.trim();
  }

  // -------------------- 공통 간단 POST --------------------
  static Future<bool> post(String endpoint, Map<String, dynamic> body) =>
      _post(endpoint, body);

  static Future<bool> _post(String endpoint, Map<String, dynamic> body) async {
    final url = Uri.parse('$baseUrl$endpoint');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) return true;
      debugPrint(
        '❌ POST 실패 [$endpoint]: ${response.statusCode} ${response.body}',
      );
      return false;
    } catch (e) {
      debugPrint('🔥 POST 예외 [$endpoint]: $e');
      return false;
    }
  }

  // -------------------- 인증 --------------------
  static Future<bool> registerUser(SignupData data) =>
      _post('/api/v1/auth/save', data.toJson());

  static Future<LoginResponse?> loginUser(LoginData data) async {
    final url = Uri.parse('$baseUrl/api/v1/auth/login');
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data.toJson()),
    );
    if (response.statusCode != 200) {
      debugPrint('❌ 로그인 실패: ${response.statusCode} ${response.body}');
      return null;
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final loginResponse = LoginResponse.fromJson(decoded);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', loginResponse.data.accessToken ?? '');
    localUser.UserData.token = loginResponse.data.accessToken;
    return loginResponse;
  }

  // -------------------- 파일 업로드(면허증 예시) --------------------
  static Future<String?> uploadLicenseImage(File file) async {
    final url = Uri.parse('$baseUrl/api/v1/upload/license');
    final request = http.MultipartRequest('POST', url)
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    try {
      final response = await request.send();
      if (response.statusCode != 200) return null;
      final body = await response.stream.bytesToString();
      final result = jsonDecode(body);
      return result['url'];
    } catch (e) {
      debugPrint('🔥 이미지 업로드 에러: $e');
      return null;
    }
  }

  // -------------------- 배송 관련 (이미지/상태) --------------------
  /// 배송도착 이미지 저장
  static Future<bool> sendDeliveryImage({
    required int productId,
    required String imageUrl,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/delivery/image');
    try {
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode({'productId': productId, 'imageUrl': imageUrl}),
      );
      debugPrint('📥 sendDeliveryImage: ${res.statusCode} ${res.body}');
      if (res.statusCode != 200) return false;

      try {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          final sc = decoded['statusCode'] ?? 200;
          return sc == 0 || sc == 200;
        }
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('❌ sendDeliveryImage 실패: $e');
      return false;
    }
  }

  /// 배송 상태 변경 (PATCH /api/v1/driver/product/status)
  /// Swagger 예시: productId, status, (선택) location/lat/lng/addressShort/region
  static Future<bool> updateProductStatus(
    int productId,
    String status, {
    String? location,
    double? latitude,
    double? longitude,
    String? addressShort,
    String? region,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/product/status');
    try {
      final normalized = _normalizeStatus(status);
      final body = <String, dynamic>{
        "productId": productId,
        "status": normalized,
        if (location != null && location.trim().isNotEmpty)
          "location": location,
        if (latitude != null) "latitude": latitude,
        if (longitude != null) "longitude": longitude,
        if (addressShort != null && addressShort.trim().isNotEmpty)
          "addressShort": addressShort,
        if (region != null && region.trim().isNotEmpty) "region": region,
      };

      final res = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode(body),
      );

      Map<String, dynamic>? decoded;
      try {
        decoded =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>?;
      } catch (_) {}

      final sc = decoded?['statusCode'] ?? res.statusCode;
      final ok = sc == 0 || sc == 200;
      if (!ok) {
        debugPrint('❌ updateProductStatus 실패: $sc, ${res.body} (req=$body)');
      } else {
        debugPrint('✅ updateProductStatus 성공: $body');
      }
      return ok;
    } catch (e) {
      debugPrint('🔥 updateProductStatus 예외: $e');
      return false;
    }
  }

  // -------------------- 근태/건강 --------------------
  static Future<bool> updateAttendanceStatus(String status) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/attendance');
    try {
      final res = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode({'status': status}),
      );
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('🔥 attendance 예외: $e');
      return false;
    }
  }

  static Future<bool> submitHealthSurvey({
    required String finish1,
    required String finish2,
    required String finish3,
    required int step,
    required int heartRate,
    required String conditionStatus,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/health/survey');
    try {
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode({
          'finish1': finish1,
          'finish2': finish2,
          'finish3': finish3,
          'step': step,
          'heartRate': heartRate,
          'conditionStatus': conditionStatus,
        }),
      );
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('🔥 submitHealthSurvey 예외: $e');
      return false;
    }
  }

  static Future<bool> sendHealthData({
    required int step,
    required int heartRate,
    required String conditionStatus,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/realtime');
    try {
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode({
          'step': step,
          'heartRate': heartRate,
          'conditionStatus': conditionStatus,
        }),
      );
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('🔥 sendHealthData 예외: $e');
      return false;
    }
  }

  // -------------------- 공통 GET/PATCH (캐시 무효화) --------------------
  static Future<Map<String, dynamic>> get(String endpoint) async {
    final sep = endpoint.contains('?') ? '&' : '?';
    final url = Uri.parse(
      '$baseUrl$endpoint${sep}_ts=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final res = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      );
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (e) {
      debugPrint('🔥 GET 실패 [$endpoint]: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> patch(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final url = Uri.parse('$baseUrl$endpoint');
    try {
      final res = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode(body),
      );
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (e) {
      debugPrint('🔥 PATCH 실패 [$endpoint]: $e');
      rethrow;
    }
  }

  // -------------------- 배송 요약 --------------------
  static Future<List<dynamic>> fetchDeliverySummary() async {
    final response = await get('/api/v1/driver/summary');
    if (response['statusCode'] == 200) {
      return response['data'];
    } else {
      throw Exception(response['message'] ?? '배송 정보를 불러올 수 없습니다.');
    }
  }

  /// 홈에서 더미 건강데이터 1회 전송용 (기존 코드 호환)
  static Future<bool> createDummyHealthRecord() async {
    try {
      final step = localUser.UserData.stepCount ?? 0;
      final hr = localUser.UserData.heartRate ?? 0;
      final cond = localUser.UserData.conditionStatus ?? '미정';
      return await sendHealthData(
        step: step,
        heartRate: hr,
        conditionStatus: cond,
      );
    } catch (_) {
      return false;
    }
  }
}
