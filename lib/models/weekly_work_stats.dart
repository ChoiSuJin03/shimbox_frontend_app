// lib/models/weekly_work_stats.dart
class WeeklyWorkStats {
  final int driverId;
  final String driverName;
  final DateTime startDate;
  final DateTime endDate;
  final List<DailyWorkStat> dailyStats;
  final int totalWorkMinutes;
  final int totalDeliveryCount;
  final double averageDailyWorkMinutes;
  final double averageDailyDeliveryCount;

  WeeklyWorkStats({
    required this.driverId,
    required this.driverName,
    required this.startDate,
    required this.endDate,
    required this.dailyStats,
    required this.totalWorkMinutes,
    required this.totalDeliveryCount,
    required this.averageDailyWorkMinutes,
    required this.averageDailyDeliveryCount,
  });

  factory WeeklyWorkStats.fromResponse(Map<String, dynamic> json) {
    // 서버 공통 래핑: { data: {...}, message, statusCode }
    final data = (json['data'] ?? json) as Map<String, dynamic>;

    return WeeklyWorkStats(
      driverId: (data['driverId'] as num? ?? 0).toInt(), // ✅ 널 안전
      driverName: data['driverName']?.toString() ?? '',
      startDate: DateTime.parse(data['startDate'].toString()),
      endDate: DateTime.parse(data['endDate'].toString()),
      dailyStats:
          (data['dailyStats'] as List<dynamic>? ?? const [])
              .map((e) => DailyWorkStat.fromJson(e as Map<String, dynamic>))
              .toList(),
      totalWorkMinutes: (data['totalWorkMinutes'] as num? ?? 0).toInt(),
      totalDeliveryCount: (data['totalDeliveryCount'] as num? ?? 0).toInt(),
      averageDailyWorkMinutes:
          (data['averageDailyWorkMinutes'] as num? ?? 0).toDouble(),
      averageDailyDeliveryCount:
          (data['averageDailyDeliveryCount'] as num? ?? 0).toDouble(),
    );
  }
}

class DailyWorkStat {
  final DateTime date; // YYYY-MM-DD
  final int workMinutes; // 하루 총 근무 분
  final int deliveryCount;
  final DateTime? workStartTime; // ISO
  final DateTime? workEndTime; // ISO (퇴근 전이면 null일 수도)

  DailyWorkStat({
    required this.date,
    required this.workMinutes,
    required this.deliveryCount,
    this.workStartTime,
    this.workEndTime,
  });

  factory DailyWorkStat.fromJson(Map<String, dynamic> json) {
    return DailyWorkStat(
      date: DateTime.parse(json['date'].toString()),
      workMinutes: (json['workMinutes'] as num? ?? 0).toInt(),
      deliveryCount: (json['deliveryCount'] as num? ?? 0).toInt(),
      workStartTime:
          json['workStartTime'] == null
              ? null
              : DateTime.parse(json['workStartTime'].toString()),
      workEndTime:
          json['workEndTime'] == null
              ? null
              : DateTime.parse(json['workEndTime'].toString()),
    );
  }
}
