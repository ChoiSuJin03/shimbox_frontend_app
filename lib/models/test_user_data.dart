// lib/models/test_user_data.dart
class UserData {
  static String? name;
  static String? email;
  static String? token;
  static String? residence;

  // ▼ 추가: 서버 driver profile 조회용
  static int? driverId;

  static int? stepCount;
  static int? heartRate;
  static String conditionStatus = '좋음';

  static DateTime? workStart;
  static DateTime? workEnd;
  static int? weeklyWorkAvgHours;

  static void clear() {
    name = null;
    email = null;
    token = null;
    residence = null;

    // 드라이버 식별자도 초기화
    driverId = null;

    // 건강 데이터 초기화
    stepCount = null;
    heartRate = null;
    conditionStatus = '좋음';

    // 근무 데이터 초기화
    workStart = null;
    workEnd = null;
    weeklyWorkAvgHours = null;
  }
}
