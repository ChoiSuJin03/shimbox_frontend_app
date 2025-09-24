/// - 주소 파싱/표시 전용

Map<String, String> splitDetail(String? detail) {
  final raw = (detail ?? '').trim();
  if (raw.isEmpty) return {'building': '', 'unit': ''};
  final parts = raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  final building = parts.isNotEmpty ? parts[0] : '';
  final unit = parts.length > 1 ? parts[1] : '';
  return {'building': building, 'unit': unit};
}

/// 제목 2줄용: “…구/군/시” 까지를 1줄, 나머지를 2줄
Map<String, String> splitAddressForTwoLines(String base) {
  final b = base.trim();
  final patterns = [
    RegExp(r'^(.+?구)\s*(.*)$'),
    RegExp(r'^(.+?군)\s*(.*)$'),
    RegExp(r'^(.+?시)\s*(.*)$'),
  ];
  for (final re in patterns) {
    final m = re.firstMatch(b);
    if (m != null) {
      return {'line1': m.group(1) ?? b, 'line2': m.group(2) ?? ''};
    }
  }
  return {'line1': b, 'line2': ''};
}
