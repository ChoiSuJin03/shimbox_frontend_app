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
}
