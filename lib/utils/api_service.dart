import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/signup_data.dart';
import '../models/login_data.dart';
import '../models/login_response.dart';
import '../models/test_user_data.dart' as localUser;
import '../models/weekly_work_stats.dart';

class ApiService {
  static const String baseUrl = 'http://116.39.208.72:26443';

  static const Map<String, String> _STATUS_TO_KOR = {
    '배송대기': '배송대기',
    '배송시작': '배송시작',
    '배송완료': '배송완료',
    '대기': '배송대기',
    '시작': '배송시작',
    '완료': '배송완료',
    'WAITING': '배송대기',
    'waiting': '배송대기',
    'STARTED': '배송시작',
    'started': '배송시작',
    'COMPLETED': '배송완료',
    'completed': '배송완료',
  };

  static String _normalizeStatus(String status) {
    final s = status.trim();
    return _STATUS_TO_KOR[s] ?? s;
  }

  static String? _fallback(String? v) {
    if (v == null) return null;
    final t = v.trim();
    if (t.isEmpty) return null;
    if (t.toLowerCase() == 'null') return null;
    return t;
  }

  // -------------------- 토큰 보장 --------------------
  static Future<void> _ensureToken() async {
    if (localUser.UserData.token != null &&
        localUser.UserData.token!.isNotEmpty) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString('token');
      if (t != null && t.isNotEmpty) {
        localUser.UserData.token = t;
      }
    } catch (_) {}
  }

  static Map<String, String> _authHeaders({
    bool json = true,
    bool acceptAny = false,
  }) {
    return {
      if (json) 'Content-Type': 'application/json; charset=utf-8',
      if (acceptAny) 'Accept': '*/*',
      'Authorization': 'Bearer ${localUser.UserData.token}',
    };
  }

  // -------------------- 공통 간단 POST --------------------
  static Future<bool> post(String endpoint, Map<String, dynamic> body) =>
      _post(endpoint, body);

  // ✅ 변경: withAuth 파라미터 추가 및 Authorization 조건부 첨부
  static Future<bool> _post(
    String endpoint,
    Map<String, dynamic> body, {
    bool withAuth = true,
  }) async {
    final url = Uri.parse('$baseUrl$endpoint');
    try {
      if (withAuth) {
        await _ensureToken();
      }
      final hasToken = (localUser.UserData.token?.isNotEmpty ?? false);

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          if (withAuth && hasToken)
            'Authorization': 'Bearer ${localUser.UserData.token}',
        },
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
  // ✅ 변경: 회원가입은 인증 없이 호출
  static Future<bool> registerUser(SignupData data) =>
      _post('/api/v1/auth/save', data.toJson(), withAuth: false);

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

  // -------------------- 파일 업로드 --------------------
  static Future<String?> uploadLicenseImage(File file) async {
    final url = Uri.parse('$baseUrl/api/v1/upload/license');
    final request = http.MultipartRequest('POST', url)
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    try {
      // 업로드에 토큰이 필요하면 주석 해제
      await _ensureToken();
      request.headers['Authorization'] = 'Bearer ${localUser.UserData.token}';

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

  // -------------------- 배송 이미지 업로드 (no-op) --------------------
  static Future<bool> sendDeliveryImage({
    required int productId,
    required String imageUrl,
  }) async {
    debugPrint(
      '📵 [IMG] sendDeliveryImage disabled by client policy. productId=$productId, imageUrl=$imageUrl',
    );
    return true;
  }

  // -------------------- 배송 상태 업데이트 --------------------
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
      await _ensureToken();
      final normalized = _normalizeStatus(status);
      final body = <String, dynamic>{
        'productId': productId,
        'status': normalized,
        if (_fallback(location) != null) 'location': location,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (_fallback(addressShort) != null) 'addressShort': addressShort,
        if (_fallback(region) != null) 'region': region,
      };

      final res = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': '*/*',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode(body),
      );

      Map<String, dynamic>? decoded;
      try {
        decoded =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>?;
      } catch (_) {}

      final statusCodeField = decoded?['statusCode'];
      final int? sc =
          (statusCodeField is num)
              ? statusCodeField.toInt()
              : int.tryParse('$statusCodeField');

      final ok =
          (sc == null && res.statusCode >= 200 && res.statusCode < 300) ||
          sc == 0 ||
          sc == 200;

      if (!ok) {
        debugPrint(
          '❌ updateProductStatus 실패: http=${res.statusCode}, api=$sc, body=${res.body} (req=$body)',
        );
      } else {
        debugPrint(
          '✅ updateProductStatus 성공: http=${res.statusCode}, api=$sc, req=$body, resp=${res.body}',
        );
      }
      return ok;
    } catch (e) {
      debugPrint('🔥 updateProductStatus 예외: $e');
      return false;
    }
  }

  // -------------------- 공통 GET/PATCH --------------------
  static Future<Map<String, dynamic>> get(String endpoint) async {
    final sep = endpoint.contains('?') ? '&' : '?';
    final url = Uri.parse(
      '$baseUrl$endpoint${sep}_ts=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      await _ensureToken();
      final res = await http
          .get(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': '*/*',
              'Authorization': 'Bearer ${localUser.UserData.token}',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
              'Expires': '0',
            },
          )
          .timeout(const Duration(seconds: 15));

      final raw = utf8.decode(res.bodyBytes);
      final body = raw.trim();

      if (res.statusCode < 200 || res.statusCode >= 300) {
        Map<String, dynamic>? decoded;
        try {
          decoded =
              body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>;
        } catch (_) {}

        return {
          'statusCode': res.statusCode,
          'message':
              decoded?['message'] ??
              decoded?['error'] ??
              (body.isEmpty ? 'empty body' : body),
          'data': decoded?['data'],
        };
      }

      if (body.isEmpty) {
        return {
          'statusCode': res.statusCode,
          'data': null,
          'message': 'empty body',
        };
      }

      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is List) return {'statusCode': 200, 'data': decoded};
      return {'statusCode': 200, 'raw': decoded};
    } catch (e) {
      debugPrint('🔥 GET 예외 [$endpoint]: $e');
      return {'statusCode': 599, 'message': e.toString(), 'data': null};
    }
  }

  static Future<Map<String, dynamic>> patch(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final url = Uri.parse('$baseUrl$endpoint');
    try {
      await _ensureToken();
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
  static Future<List<Map<String, dynamic>>> fetchDeliverySummary() async {
    final response = await get('/api/v1/driver/summary');

    final sc = response['statusCode'] ?? response['status'] ?? 500;

    if (sc == 401 || sc == 403) {
      debugPrint('🔐 summary 인증/권한 실패(status=$sc): ${response['message']}');
      return const [];
    }

    if (sc == 404) {
      // 배정이 없을 때 서버가 404를 주는 사양 → 빈 리스트가 정상
      debugPrint('ℹ️ summary: 배정 없음(404)');
      return const [];
    }

    if (sc != 200) {
      debugPrint('❌ summary 오류(status=$sc): ${response['message']}');
      return const [];
    }

    final raw = response['data'];
    if (raw is! List) return const [];

    String _clean(Object? v) {
      final s = (v?.toString() ?? '').trim();
      if (s.isEmpty || s.toLowerCase() == 'null') return '';
      return s;
    }

    String _firstNonEmpty(Map row, List<String> keys) {
      for (final k in keys) {
        if (row.containsKey(k)) {
          final v = _clean(row[k]);
          if (v.isNotEmpty) return v;
        }
      }
      return '';
    }

    String? _extractDongFromText(String? s) {
      if (s == null) return null;
      final t = _clean(s);
      if (t.isEmpty) return null;
      final m = RegExp(r'(\d+)\s*동').firstMatch(t);
      if (m != null) return '${m.group(1)}동';
      if (RegExp(r'^\d+$').hasMatch(t)) return '${t}동';
      return null;
    }

    final List<Map<String, dynamic>> normalized = [];
    for (final e in raw) {
      if (e is! Map) continue;

      final address = _firstNonEmpty(e, [
        'address',
        'shippingLocation',
        'shipping_location',
        'baseAddress',
        'shippingAddress',
      ]);

      final detailAddress = _firstNonEmpty(e, [
        'detailAddress',
        'detail_address',
        'detail',
        'subAddress',
      ]);

      final dong =
          _extractDongFromText(detailAddress) ??
          _extractDongFromText(address) ??
          _extractDongFromText(_clean(e['dong'])) ??
          _extractDongFromText(_clean(e['buildingDong'])) ??
          _extractDongFromText(_clean(e['building']));

      final row = <String, dynamic>{};
      (e as Map).forEach((k, v) => row[k.toString()] = v);
      row['address'] = address;
      row['detailAddress'] = detailAddress;
      row['detail_address'] = detailAddress;
      row['detail'] = detailAddress;
      if (dong != null) row['dong'] = dong;

      normalized.add(row);
    }

    if (normalized.isNotEmpty) {
      debugPrint('🧩 summary normalized keys: ${normalized.first.keys}');
      debugPrint(
        '🧩 sample detail/dong: detail="${normalized.first['detail']}", dong="${normalized.first['dong']}"',
      );
    }
    return normalized;
  }

  // -------------------- 건강 데이터 (실시간) --------------------
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

  static Future<bool> sendHealthData({
    required int step,
    required int heartRate,
    required String conditionStatus,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/realtime');
    try {
      await _ensureToken();
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

  // -------------------- 근태(출근/퇴근) --------------------
  static Future<bool> updateAttendanceStatus(
    String status, {
    double? latitude,
    double? longitude,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/attendance');
    try {
      await _ensureToken();
      final body = <String, dynamic>{
        'status': status.trim(),
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
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
      final ok =
          sc == 0 ||
          sc == 200 ||
          (res.statusCode >= 200 && res.statusCode < 300);
      if (!ok) {
        debugPrint('❌ updateAttendanceStatus 실패: $sc, ${res.body} (req=$body)');
      } else {
        debugPrint('✅ updateAttendanceStatus 성공: $body');
      }
      return ok;
    } catch (e) {
      debugPrint('🔥 updateAttendanceStatus 예외: $e');
      return false;
    }
  }

  // -------------------- 건강 설문 --------------------
  static Future<bool> submitHealthSurvey({
    required String finish1,
    required String finish2,
    required String finish3,
    required int step,
    required int heartRate,
    required String conditionStatus,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/health/survey');

    final payload = <String, dynamic>{
      'finish1': finish1.trim(),
      'finish2': finish2.trim(),
      'finish3': finish3.trim(),
      'step': step,
      'heartRate': heartRate,
      'conditionStatus': conditionStatus,
    };

    try {
      await _ensureToken();
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Accept': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode(payload),
      );

      Map<String, dynamic>? decoded;
      try {
        decoded =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>?;
      } catch (_) {}

      if (res.statusCode != 200) {
        debugPrint(
          '❌ submitHealthSurvey HTTP 실패: ${res.statusCode} ${res.body}',
        );
        return false;
      }

      final scRaw = decoded?['statusCode'];
      final sc =
          (scRaw is num)
              ? scRaw.toInt()
              : int.tryParse(scRaw?.toString() ?? '');
      final ok = (sc == null && res.statusCode == 200) || sc == 0 || sc == 200;

      if (!ok) {
        debugPrint(
          '❌ submitHealthSurvey 실패(statusCode=$sc): ${res.body} (req=$payload)',
        );
        return false;
      }

      debugPrint('✅ submitHealthSurvey 성공: $payload');
      return true;
    } catch (e) {
      debugPrint('🔥 submitHealthSurvey 예외: $e');
      return false;
    }
  }

  // -------------------- 주간 근무 통계 --------------------
  static Future<WeeklyWorkStats> fetchWeeklyWorkStats() async {
    final resp = await get('/api/v1/driver/my/weekly-stats');
    final sc = resp['statusCode'] ?? resp['status'] ?? 200;
    if (!(sc == 0 || sc == 200)) {
      throw Exception(resp['message'] ?? '근무 통계를 불러올 수 없습니다.');
    }
    return WeeklyWorkStats.fromResponse(resp);
  }

  // ==================== ▼▼▼ 관리자/유틸 ▼▼▼ ====================
  static Future<DriverProfileResponse> fetchDriverProfile(int driverId) async {
    final resp = await get('/api/v1/admin/driver/$driverId/profile');
    final sc = resp['statusCode'] ?? resp['status'] ?? 200;
    if (!(sc == 0 || sc == 200)) {
      throw Exception(resp['message'] ?? '기사 프로필을 불러올 수 없습니다.');
    }
    return DriverProfileResponse.fromJson(resp);
  }

  static Future<bool> updateDriverProfile({
    required int driverId,
    int? heightCm,
    int? weightKg,
    String? phone,
    String? vehicleNumber,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/admin/driver/$driverId/profile');

    final body = <String, dynamic>{
      if (heightCm != null) 'heightCm': heightCm,
      if (weightKg != null) 'weightKg': weightKg,
      if (_fallback(phone) != null) 'phone': phone,
      if (_fallback(vehicleNumber) != null) 'vehicleNumber': vehicleNumber,
    };

    if (body.isEmpty) {
      debugPrint('ℹ️ updateDriverProfile: 변경할 값이 없습니다.');
      return true;
    }

    try {
      await _ensureToken();
      final res = await http.patch(
        url,
        headers: _authHeaders(),
        body: jsonEncode(body),
      );

      Map<String, dynamic>? decoded;
      try {
        decoded =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>?;
      } catch (_) {}

      final sc = decoded?['statusCode'] ?? res.statusCode;
      final ok =
          sc == 0 ||
          sc == 200 ||
          (res.statusCode >= 200 && res.statusCode < 300);

      if (!ok) {
        debugPrint(
          '❌ updateDriverProfile 실패: http=${res.statusCode}, api=$sc, body=${res.body} (req=$body)',
        );
      } else {
        debugPrint('✅ updateDriverProfile 성공: $body');
      }
      return ok;
    } catch (e) {
      debugPrint('🔥 updateDriverProfile 예외: $e');
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> fetchDriverHealthHistory({
    required int driverId,
    DateTime? from,
    DateTime? to,
    int page = 0,
    int size = 20,
  }) async {
    String fmt(DateTime d) => d.toIso8601String().substring(0, 10);

    final params = <String, String>{
      if (from != null) 'from': fmt(from),
      if (to != null) 'to': fmt(to),
      'page': '$page',
      'size': '$size',
    };

    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    final endpoint =
        '/api/v1/admin/driver/$driverId/health/history${query.isEmpty ? '' : '?$query'}';

    final resp = await get(endpoint);
    final sc = resp['statusCode'] ?? resp['status'] ?? 500;

    if (!(sc == 0 || sc == 200)) {
      debugPrint(
        '❌ fetchDriverHealthHistory 실패(status=$sc): ${resp['message']}',
      );
      return const [];
    }

    final data = resp['data'];
    if (data is List) {
      return data
          .cast<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }

    if (data is Map && data['content'] is List) {
      final list = (data['content'] as List).cast<Map>();
      return list
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }

    return const [];
  }

  static Future<List<Map<String, dynamic>>> fetchMyAttendanceHistory({
    required DateTime from,
    required DateTime to,
  }) async {
    String fmt(DateTime d) => d.toIso8601String().substring(0, 10);

    final endpoint =
        '/api/v1/driver/attendance/history?from=${fmt(from)}&to=${fmt(to)}';

    final resp = await get(endpoint);
    final sc = resp['statusCode'] ?? resp['status'] ?? 500;

    if (!(sc == 0 || sc == 200)) {
      debugPrint(
        '❌ fetchMyAttendanceHistory 실패(status=$sc): ${resp['message']}',
      );
      return const [];
    }

    final data = resp['data'];
    if (data is List) {
      return data
          .cast<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }
    return const [];
  }

  static Future<bool> logout() async {
    final url = Uri.parse('$baseUrl/api/v1/auth/logout');
    try {
      await _ensureToken();
      final res = await http.post(url, headers: _authHeaders());

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('token');
      } catch (_) {}
      localUser.UserData.token = null;

      if (res.statusCode >= 200 && res.statusCode < 300) {
        debugPrint('👋 로그아웃 완료(서버/로컬)');
        return true;
      } else {
        debugPrint('⚠️ 서버 로그아웃 실패: ${res.statusCode} ${res.body} (로컬 토큰은 제거됨)');
        return false;
      }
    } catch (e) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('token');
      } catch (_) {}
      localUser.UserData.token = null;

      debugPrint('🔥 로그아웃 예외: $e (로컬 토큰은 제거됨)');
      return false;
    }
  }
}

// ▼ 응답 모델
class DriverProfileResponse {
  final Map<String, dynamic> data;
  final String? message;
  final int? statusCode;

  DriverProfileResponse({required this.data, this.message, this.statusCode});

  factory DriverProfileResponse.fromJson(Map<String, dynamic> json) {
    return DriverProfileResponse(
      data: (json['data'] ?? {}) as Map<String, dynamic>,
      message: json['message'] as String?,
      statusCode:
          (json['statusCode'] is num)
              ? (json['statusCode'] as num).toInt()
              : int.tryParse(json['statusCode']?.toString() ?? ''),
    );
  }
}
