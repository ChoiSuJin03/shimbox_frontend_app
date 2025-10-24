// lib/utils/api_service.dart
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

  // -------------------- 파일 업로드 --------------------
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

  // -------------------- 배송 이미지 업로드 --------------------
  // ✅ 요구사항: 서버로 이미지 URL을 보내지 않음. 이 메서드는 no-op으로 성공 처리.
  static Future<bool> sendDeliveryImage({
    required int productId,
    required String imageUrl,
  }) async {
    debugPrint(
      '📵 [IMG] sendDeliveryImage disabled by client policy. productId=$productId, imageUrl=$imageUrl',
    );
    return true;
  }

  // lib/utils/api_service.dart (발췌)
  // PATCH /api/v1/driver/product/status
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
      // 스웨거 예시가 한글 상태이므로 한글로 정규화
      final normalized = _normalizeStatus(status);

      // ✅ 스웨거 스펙 그대로: imageUrl 없음, camelCase 사용
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
      } catch (_) {
        // 응답이 비JSON이어도 HTTP 2xx면 성공 처리
      }

      // 스웨거: statusCode==0 이면 OK. (백엔드가 200만 주는 경우도 고려)
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
  // ✅ 교체: ApiService.get()
  static Future<Map<String, dynamic>> get(String endpoint) async {
    final sep = endpoint.contains('?') ? '&' : '?';
    final url = Uri.parse(
      '$baseUrl$endpoint${sep}_ts=${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      final res = await http
          .get(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': '*/*', // 🔧 swagger 표기 맞춤
              'Authorization': 'Bearer ${localUser.UserData.token}',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
              'Expires': '0',
            },
          )
          .timeout(const Duration(seconds: 15));

      final raw = utf8.decode(res.bodyBytes);
      final body = raw.trim();

      // ✅ 절대로 throw 하지 말고 상태/메시지와 함께 반환
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
      // ✅ 네트워크 에러도 throw 대신 구조화
      return {'statusCode': 599, 'message': e.toString(), 'data': null};
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
  static Future<List<Map<String, dynamic>>> fetchDeliverySummary() async {
    final response = await get('/api/v1/driver/summary');

    final sc = response['statusCode'] ?? response['status'] ?? 500;

    // 🔐 인증/권한 문제면 UI가 안내 문구를 띄울 수 있게 빈 리스트로 넘기고 로그만 남김
    if (sc == 401 || sc == 403) {
      debugPrint('🔐 summary 인증/권한 실패(status=$sc): ${response['message']}');
      return const [];
    }

    if (sc != 200) {
      // 그 외 서버 오류 등도 UI 죽이지 말고 빈 리스트
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

  // -------------------- 건강 데이터 --------------------
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
      final ok = sc == 0 || sc == 200;
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
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/health/survey');

    final payload = <String, dynamic>{
      'finish1': finish1.trim(),
      'finish2': finish2.trim(),
      'finish3': finish3.trim(),
    };

    try {
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
}
