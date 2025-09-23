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
import 'package:shimbox_app/models/map/map_poi.dart';

class ApiService {
  static const String baseUrl = 'http://116.39.208.72:26443';

  static Future<bool> post(String endpoint, Map<String, dynamic> body) {
    return _post(endpoint, body);
  }

  static Future<bool> registerUser(SignupData data) {
    return _post('/api/v1/auth/save', data.toJson());
  }

  static Future<LoginResponse?> loginUser(LoginData data) async {
    final url = Uri.parse('$baseUrl/api/v1/auth/login');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data.toJson()),
    );

    if (response.statusCode == 200) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      print('✅ 로그인 응답: $decoded');

      final loginResponse = LoginResponse.fromJson(decoded);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', loginResponse.data.accessToken ?? '');

      localUser.UserData.token = loginResponse.data.accessToken;

      return loginResponse;
    } else {
      print('❌ 로그인 실패: ${response.statusCode}, ${response.body}');
      return null;
    }
  }

  static Future<String?> uploadLicenseImage(File file) async {
    final url = Uri.parse('$baseUrl/api/v1/upload/license');
    final request = http.MultipartRequest('POST', url);
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    try {
      final response = await request.send();

      if (response.statusCode == 200) {
        final body = await response.stream.bytesToString();
        final result = jsonDecode(body);
        print('✅ 이미지 업로드 성공: ${result['url']}');
        return result['url'];
      } else {
        print('❌ 이미지 업로드 실패: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('🔥 이미지 업로드 에러: $e');
      return null;
    }
  }

  static Future<bool> _post(String endpoint, Map<String, dynamic> body) async {
    final url = Uri.parse('$baseUrl$endpoint');

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        print('✅ 요청 성공: $endpoint');
        return true;
      } else {
        print('❌ 실패 [$endpoint]: ${response.statusCode}, ${response.body}');
        return false;
      }
    } catch (e) {
      print('🔥 예외 발생 [$endpoint]: $e');
      return false;
    }
  }

  static Future<bool> sendDeliveryImage({
    required int productId,
    required String imageUrl,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/delivery/image');

    print('📤 이미지 전송 요청: productId=$productId, imageUrl=$imageUrl');

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode({'productId': productId, 'imageUrl': imageUrl}),
      );

      print('📥 서버 응답: ${response.statusCode}, ${response.body}');

      return response.statusCode == 200;
    } catch (e) {
      print('❌ 이미지 전송 실패: $e');
      return false;
    }
  }

  static Future<bool> updateAttendanceStatus(String status) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/attendance');

    print('📤 근태 상태 요청: $status');
    print('📤 토큰: ${localUser.UserData.token}');

    try {
      final response = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode({'status': status}),
      );

      print('📥 응답 코드: ${response.statusCode}');
      print('📥 응답 바디: ${response.body}');

      if (response.statusCode == 200) {
        print('✅ 근태 상태 업데이트 성공');
        return true;
      } else {
        print('❌ 근태 상태 업데이트 실패: ${response.statusCode}, ${response.body}');
        return false;
      }
    } catch (e) {
      print('🔥 근태 상태 업데이트 예외 발생: $e');
      return false;
    }
  }

  /// ✅ 설문 + 건강 데이터 동시 전송
  static Future<bool> submitHealthSurvey({
    required String finish1,
    required String finish2,
    required String finish3,
    required int step,
    required int heartRate,
    required String conditionStatus,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/health/survey');
    print('📤 설문 + 건강 데이터 제출 시작');
    print('📤 토큰: ${localUser.UserData.token}');

    try {
      final response = await http.post(
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

      print('📥 응답 코드: ${response.statusCode}');
      print('📥 응답 바디: ${response.body}');

      return response.statusCode == 200;
    } catch (e) {
      print('🔥 설문 제출 중 에러 발생: $e');
      return false;
    }
  }

  static Future<List<dynamic>> fetchDeliverySummary() async {
    final response = await get('/api/v1/driver/summary');
    if (response['statusCode'] == 200) {
      return response['data'];
    } else {
      throw Exception(response['message'] ?? '배송 정보를 불러올 수 없습니다.');
    }
  }

  static Future<bool> updateProductStatus(int productId, String status) async {
    final body = {"productId": productId, "status": status};
    final response = await patch('/api/v1/driver/product/status', body);

    final isSuccess =
        response['statusCode'] == 0 || response['statusCode'] == 200;
    if (!isSuccess) {
      print('❌ 배송 상태 변경 실패: ${response['statusCode']}, ${response['message']}');
    }
    return isSuccess;
  }

  static Future<bool> createDummyHealthRecord() async {
    return sendHealthData(
      step: localUser.UserData.stepCount ?? 0,
      heartRate: localUser.UserData.heartRate ?? 0,
      conditionStatus: localUser.UserData.conditionStatus,
    );
  }

  static Future<bool> sendHealthData({
    required int step,
    required int heartRate,
    required String conditionStatus,
  }) async {
    final url = Uri.parse('$baseUrl/api/v1/driver/realtime');

    try {
      final response = await http.post(
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

      if (response.statusCode == 200) {
        print('✅ 건강 데이터 전송 성공');
        return true;
      } else {
        print('❌ 건강 데이터 전송 실패: ${response.statusCode}, ${response.body}');
        return false;
      }
    } catch (e) {
      print('🔥 건강 데이터 전송 예외 발생: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>> get(String endpoint) async {
    final url = Uri.parse('$baseUrl$endpoint');

    try {
      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
      );

      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      print('🔥 GET 요청 실패 [$endpoint]: $e');
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> patch(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final url = Uri.parse('$baseUrl$endpoint');

    try {
      final response = await http.patch(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${localUser.UserData.token}',
        },
        body: jsonEncode(body),
      );

      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      print('🔥 PATCH 요청 실패 [$endpoint]: $e');
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // 지도 API
  // ------------------------------------------------------------------

  // ApiService 클래스 내부 어디 위쪽에 추가 (예: 지도 API 섹션 위)
  static Future<int> _resolveDriverId({int? override}) async {
    if (override != null && override > 0) return override;

    final prefs = await SharedPreferences.getInstance();
    // 흔한 키 이름들을 순서대로 조회
    final candidates = ['driverId', 'userId', 'id'];
    for (final key in candidates) {
      final v = prefs.get(key);
      if (v is int && v > 0) return v;
      if (v is String) {
        final parsed = int.tryParse(v) ?? 0;
        if (parsed > 0) return parsed;
      }
    }
    return 0; // 못 찾으면 0 (드라이버 미지정)
  }

  /// 지도용 상품 목록 가져오기
  /// // ================== 주소만 가져오기 (상품 -> 주소 문자열 리스트) ==================

  static Future<List<String>> fetchAddressStrings({int? driverId}) async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ${localUser.UserData.token}', // 불필요하면 제거
    };

    // GET 후보들 (driverId가 필요할 수 있으니 쿼리/패스 모두 시도)
    final List<Uri> getTries = [
      if (driverId != null && driverId > 0)
        Uri.parse('$baseUrl/api/v1/driver/$driverId/products'),
      if (driverId != null && driverId > 0)
        Uri.parse('$baseUrl/api/v1/product/list?driverId=$driverId'),
      if (driverId != null && driverId > 0)
        Uri.parse('$baseUrl/api/v1/driver/product/list?driverId=$driverId'),

      // 드라이버 없이도 열려 있을 수 있는 목록
      Uri.parse('$baseUrl/api/v1/driver/products'),
      Uri.parse('$baseUrl/api/v1/driver/product/list'),
      Uri.parse('$baseUrl/api/v1/product/list'),
      Uri.parse('$baseUrl/api/v1/product'),
      Uri.parse('$baseUrl/api/v1/product/all'),
      Uri.parse('$baseUrl/api/v1/product/today'),
    ];

    // POST 후보 (검색형 – 드라이버/날짜 필터가 필요할 수 있음)
    final List<(Uri uri, Map<String, dynamic> body, String label)> postTries = [
      if (driverId != null && driverId > 0)
        (
          Uri.parse('$baseUrl/api/v1/product/search'),
          {'driverId': driverId, 'date': 'today'},
          'product/search with driverId',
        ),
      if (driverId != null && driverId > 0)
        (
          Uri.parse('$baseUrl/api/v1/driver/products/search'),
          {'driverId': driverId, 'date': 'today'},
          'driver/products/search with driverId',
        ),
      (
        Uri.parse('$baseUrl/api/v1/product/search'),
        {'date': 'today'},
        'product/search',
      ),
    ];

    List _unwrap(dynamic decoded) {
      if (decoded is List) return decoded;
      if (decoded is Map) {
        final keys = ['data', 'content', 'items', 'list', 'results', 'rows'];
        for (final k in keys) {
          if (decoded[k] is List) return decoded[k] as List;
        }
      }
      return const [];
    }

    List<String> _extractAddresses(List list) {
      final out = <String>[];
      for (final item in list) {
        if (item is! Map) continue;

        final base =
            (item['address'] ??
                    item['baseAddress'] ??
                    item['shippingAddress'] ??
                    '')
                .toString()
                .trim();

        final detail =
            (item['detailAddress'] ??
                    item['addressDetail'] ??
                    item['detail_address'] ??
                    '')
                .toString()
                .trim();

        if (base.isEmpty) continue;

        final full = detail.isNotEmpty ? '$base $detail' : base;
        out.add(full);
      }
      return out;
    }

    // 1) GET 시도
    for (final uri in getTries) {
      try {
        debugPrint('GET $uri');
        final res = await http.get(uri, headers: headers);
        debugPrint(' -> ${res.statusCode}');
        if (res.statusCode == 200) {
          final decoded = json.decode(utf8.decode(res.bodyBytes));
          final list = _unwrap(decoded);
          final addrs = _extractAddresses(list);
          if (addrs.isNotEmpty) {
            debugPrint(
              '✅ addresses via GET: ${uri.path} (count=${addrs.length})',
            );
            return addrs;
          }
        }
      } catch (e) {
        debugPrint('GET error $uri -> $e');
      }
    }

    // 2) POST 시도
    for (final t in postTries) {
      try {
        debugPrint('POST ${t.$1} [${t.$3}] body=${t.$2}');
        final res = await http.post(
          t.$1,
          headers: headers,
          body: json.encode(t.$2),
        );
        debugPrint(' -> ${res.statusCode}');
        if (res.statusCode == 200) {
          final decoded = json.decode(utf8.decode(res.bodyBytes));
          final list = _unwrap(decoded);
          final addrs = _extractAddresses(list);
          if (addrs.isNotEmpty) {
            debugPrint(
              '✅ addresses via POST: ${t.$1.path} (count=${addrs.length})',
            );
            return addrs;
          }
        }
      } catch (e) {
        debugPrint('POST error ${t.$1} -> $e');
      }
    }

    // 모두 실패 시 에러 반환
    throw Exception('주소 목록 API를 찾지 못했습니다.');
  }

  // ============== 폴백: summary에서 지역명만 (주소 대용) ==============
  static Future<List<String>> fetchSummaryLocations() async {
    try {
      final data = await fetchDeliverySummary(); // 기존 함수 재사용
      final out = <String>{}; // 중복 제거
      for (final a in data) {
        final s = (a['shippingLocation'] ?? '').toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out.toList();
    } catch (_) {
      return const [];
    }
  }

  // ApiService 클래스 안에 추가
  static Future<List<Map<String, dynamic>>> fetchProductsForMap() async {
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer ${localUser.UserData.token}', // 필요없으면 제거
    };

    List<Map<String, dynamic>> _extractList(dynamic decoded) {
      if (decoded is List) return decoded.cast<Map<String, dynamic>>();
      if (decoded is Map) {
        for (final k in [
          'data',
          'content',
          'items',
          'list',
          'results',
          'rows',
        ]) {
          final v = decoded[k];
          if (v is List) return v.cast<Map<String, dynamic>>();
        }
      }
      return const [];
    }

    // 주소 필드가 있는 아이템만 남기기
    List<Map<String, dynamic>> _filterHasAddress(
      List<Map<String, dynamic>> list,
    ) {
      return list.where((p) {
        final a =
            (p['address'] ?? p['baseAddress'] ?? p['shippingAddress'] ?? '')
                .toString()
                .trim();
        return a.isNotEmpty;
      }).toList();
    }

    // 후보 GET 엔드포인트 (필요한 것만 시도)
    final getTries = <Uri>[
      Uri.parse('$baseUrl/api/v1/driver/products'),
      Uri.parse('$baseUrl/api/v1/driver/product/list'),
      Uri.parse('$baseUrl/api/v1/product/list'),
      Uri.parse('$baseUrl/api/v1/product/today'),
      Uri.parse('$baseUrl/api/v1/order/list'),
    ];

    for (final uri in getTries) {
      try {
        debugPrint('GET $uri');
        final res = await http.get(uri, headers: headers);
        debugPrint(' -> ${res.statusCode}');
        if (res.statusCode == 200) {
          final decoded = json.decode(utf8.decode(res.bodyBytes));
          final list = _filterHasAddress(_extractList(decoded));
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }

    // 후보 POST(검색)
    final postTries = <(Uri, Map<String, dynamic>)>[
      (Uri.parse('$baseUrl/api/v1/product/search'), {'date': 'today'}),
      (Uri.parse('$baseUrl/api/v1/driver/products/search'), {'date': 'today'}),
    ];
    for (final t in postTries) {
      try {
        debugPrint('POST ${t.$1} body=${t.$2}');
        final res = await http.post(
          t.$1,
          headers: headers,
          body: json.encode(t.$2),
        );
        debugPrint(' -> ${res.statusCode}');
        if (res.statusCode == 200) {
          final decoded = json.decode(utf8.decode(res.bodyBytes));
          final list = _filterHasAddress(_extractList(decoded));
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }

    throw Exception('상품 목록 API를 찾지 못했습니다.');
  }
}
