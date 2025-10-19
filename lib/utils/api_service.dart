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

  // 서버가 허용하는 상태는 한글만: [배송대기, 배송시작, 배송완료]
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
    return _STATUS_TO_KOR[s] ?? s; // 모르면 그대로
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

  static Future<bool> updateProductStatus(
    int productId,
    String status, {
    String? location,
    double? latitude,
    double? longitude,
    String? addressShort,
    String? region,
    String? imageUrl,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/product/status');
    try {
      final normalized = _normalizeStatus(status);
      final body = <String, dynamic>{
        "productId": productId,
        "status": normalized,
        if (_fallback(location) != null) "location": location,
        if (latitude != null) "latitude": latitude,
        if (longitude != null) "longitude": longitude,
        if (_fallback(addressShort) != null) "addressShort": addressShort,
        // region은 비우지 않도록 기본값
        "region": _fallback(region) ?? '미지정',
        if (_fallback(imageUrl) != null) "imageUrl": imageUrl,
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
  static Future<List<Map<String, dynamic>>> fetchDeliverySummary() async {
    final response = await get('/api/v1/driver/summary');

    // 상태코드 가드
    final sc = response['statusCode'] ?? response['status'] ?? 500;
    if (sc != 200) {
      throw Exception(response['message'] ?? '배송 정보를 불러올 수 없습니다.');
    }

    final raw = response['data'];
    if (raw is! List) return const [];

    // 유틸
    String _clean(Object? v) {
      final s = (v?.toString() ?? '').trim();
      if (s.isEmpty) return '';
      if (s.toLowerCase() == 'null') return '';
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

      // 주소/상세주소 키 후보에서 안전 추출
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

      // ✅ dong은 detailAddress에서 우선 추출, 없으면 address에서 보조
      final dong =
          _extractDongFromText(detailAddress) ??
          _extractDongFromText(address) ??
          _extractDongFromText(_clean(e['dong'])) ??
          _extractDongFromText(_clean(e['buildingDong'])) ??
          _extractDongFromText(_clean(e['building']));

      // ✅ 원본 행을 String 키로만 새 맵에 복사
      final Map<String, dynamic> row = {};
      (e as Map).forEach((k, v) => row[k.toString()] = v);

      // ✅ 정규화 키 세팅
      row['address'] = address;
      row['detailAddress'] = detailAddress; // 원본 키 유지
      row['detail_address'] = detailAddress; // snake_case도 유지
      row['detail'] = detailAddress; // 🔥 모달/그룹핑이 읽는 키 (핵심)
      if (dong != null) row['dong'] = dong;

      normalized.add(row);
    }

    if (normalized.isNotEmpty) {
      debugPrint('🧩 summary normalized keys: ${normalized.first.keys}');
      debugPrint(
        '🧩 sample detail/dong: '
        'detail="${normalized.first['detail']}", dong="${normalized.first['dong']}"',
      );
    }

    return normalized;
  }

  // (옵션) 건강 데이터 더미
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
  /// 출근/퇴근 상태 업데이트
  /// status: "출근" 또는 "퇴근"
  static Future<bool> updateAttendanceStatus(
    String status, {
    double? latitude,
    double? longitude,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/attendance');
    try {
      final body = <String, dynamic>{
        'status': status.trim(), // "출근" | "퇴근"
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

  // -------------------- 건강 설문(자가체크) --------------------
  /// home.dart에서 넘기는 파라미터 이름을 그대로 지원합니다.
  /// - finish1/finish2/finish3: 체크박스/라디오 같은 완료 항목(불린/정수/문자 모두 허용)
  /// - step: 걸음 수
  /// - heartRate: 심박수
  /// - conditionStatus: 컨디션(문자)
  // -------------------- 건강 설문(퇴근 전 설문) --------------------
  static Future<bool> submitHealthSurvey({
    required String finish1, // ex) '적었다' | '비슷했다' | '많았다'
    required String finish2, // ex) '전혀 아니다' | '약간 그렇다' | '매우 그렇다'
    required String finish3, // ex) '적게' | '평소대로' | '더 많이'
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

      // HTTP 레벨 먼저 체크
      if (res.statusCode != 200) {
        debugPrint(
          '❌ submitHealthSurvey HTTP 실패: ${res.statusCode} ${res.body}',
        );
        return false;
      }

      // 비즈니스 레벨(statusCode) 체크
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
}
