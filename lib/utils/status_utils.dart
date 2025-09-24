/// - 배송 상태 관련 **순수 유틸**(집계/카운트).
/// -  (배송시작/배송완료)

int statusToInt(String status) {
  switch (status) {
    case '배송시작':
      return 1;
    case '배송완료':
      return 2;
    default:
      return 0;
  }
}

/// 여러 건 상태 집계: 모두 완료=2, 하나라도 진행=1, 전부 대기=0
int aggregateStatus(List<int> statuses) {
  if (statuses.isEmpty) return 0;
  if (statuses.every((s) => s == 2)) return 2;
  if (statuses.any((s) => s == 1)) return 1;
  return 0;
}

int countInProgress(List<int> statuses) => statuses.where((s) => s == 1).length;
bool allDone(List<int> statuses) =>
    statuses.isNotEmpty && statuses.every((s) => s == 2);
bool allWaiting(List<int> statuses) =>
    statuses.isNotEmpty && statuses.every((s) => s == 0);
