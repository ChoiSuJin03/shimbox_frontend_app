// - 알림 모델: 생성시간(createdAt) 포함
// - 저장/복원을 위해 toJson/fromJson 추가

class AlarmItem {
  final String title; // 예: '배송완료를 눌렀는지 확인해주세요'
  final String subtitle; // 예: 진행 중인 주소
  final DateTime createdAt;
  bool read;

  AlarmItem({
    required this.title,
    required this.subtitle,
    DateTime? createdAt,
    this.read = false,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'title': title,
    'subtitle': subtitle,
    'createdAt': createdAt.toIso8601String(),
    'read': read,
  };

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
    title: (j['title'] ?? '').toString(),
    subtitle: (j['subtitle'] ?? '').toString(),
    createdAt:
        DateTime.tryParse((j['createdAt'] ?? '').toString()) ?? DateTime.now(),
    read: (j['read'] ?? false) == true,
  );
}
