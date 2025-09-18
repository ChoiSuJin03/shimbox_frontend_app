import 'dart:convert';
import 'dart:io';
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

  /// ✅ 수정된 통합 버전: 설문 + 건강 데이터 동시 전송
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

  // 현재 위치 기준 k-NN Top-9 (폴백 없이, 서버 데이터만)
  static Future<List<MapPOI>> fetchNearestPOIs({
    required double lat,
    required double lng,
    int limit = 9,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/map/nearest?lat=$lat&lng=$lng&limit=$limit',
    );

    final res = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${localUser.UserData.token}', // 필요 없으면 제거
      },
    );

    if (res.statusCode != 200) {
      throw Exception('nearest fetch fail: ${res.statusCode} ${res.body}');
    }

    final List data = json.decode(res.body);
    // 서버가 빈 배열을 주면 그대로 빈 배열 반환(= 마커 없음)
    return data.map((e) => MapPOI.fromJson(e)).toList();
  }
}
