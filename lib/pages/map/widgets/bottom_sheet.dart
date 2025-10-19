import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shimbox_app/utils/address_utils.dart'; // splitAddressForTwoLines
import 'package:shimbox_app/utils/navigation_helper.dart'; // ✅ 네이버 길찾기 헬퍼

class ApartmentBottomSheetGrouped extends StatelessWidget {
  final String aptName;
  final String? aptAddress;
  final List<Map<String, String>> deliveries;
  final void Function(Map<String, String> item)? onTapItem;
  final void Function(Map<String, String> item)? onTapNavigate;

  const ApartmentBottomSheetGrouped({
    super.key,
    required this.aptName,
    required this.deliveries,
    this.aptAddress,
    this.onTapItem,
    this.onTapNavigate,
  });

  // ───────── raw helpers ─────────
  String _rawDetail(Map<String, String> d) {
    final v = (d['detailAddress'] ?? '').trim();
    return (v.isEmpty || v.toLowerCase() == 'null') ? '' : v;
  }

  String _rawAddress(Map<String, String> d) {
    final v = (d['address'] ?? '').trim();
    return (v.isEmpty || v.toLowerCase() == 'null') ? '' : v;
  }

  String _pick(Map<String, String> d, String k) {
    final s = (d[k] ?? '').trim();
    return (s.isEmpty || s.toLowerCase() == 'null') ? '' : s;
  }

  // 주소 끝의 “동/호” 덩어리 제거 (표시용 베이스 만들기)
  String _stripDongHo(String s) {
    var t = s;
    t = t.replaceAll(RegExp(r'[,/]\s*\d+\s*동(\s*\d+\s*호)?\s*$'), '');
    t = t.replaceAll(RegExp(r'\s*\d+\s*동(\s*\d+\s*호)?\s*$'), '');
    t = t.replaceAll(RegExp(r'\s*\d+\s*호\s*$'), '');
    t = t.replaceAll(RegExp(r'\s*[\(\[\{]\s*\d+\s*호\s*[\)\]\}]\s*$'), '');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Map<String, String> _parseDongHoFromText(String? s) {
    final out = <String, String>{};
    if (s == null) return out;
    final t = s.trim();
    if (t.isEmpty || t.toLowerCase() == 'null') return out;
    final mDong = RegExp(r'(\d+)\s*동').firstMatch(t);
    final mHo = RegExp(r'(\d+)\s*호').firstMatch(t);
    if (mDong != null) out['dong'] = '${mDong.group(1)}동';
    if (mHo != null) out['ho'] = '${mHo.group(1)}호';
    return out;
  }

  // detail 문자열 생성: detailAddress > (dong/ho) > unit > address에서 추출
  String _buildDetailString(Map<String, String> d, {required String baseRaw}) {
    final rawDetail = _rawDetail(d);
    if (rawDetail.isNotEmpty) return rawDetail;

    final directDong = [
      _pick(d, 'dong'),
      _pick(d, 'buildingDong'),
      _pick(d, 'building'),
      _pick(d, 'region'),
    ].firstWhere((e) => e.isNotEmpty, orElse: () => '');
    final directHo = _pick(d, 'ho');
    if (directDong.isNotEmpty || directHo.isNotEmpty) {
      return [
        if (directDong.isNotEmpty) directDong,
        if (directHo.isNotEmpty) directHo,
      ].join(' ').trim();
    }

    final unit = _pick(d, 'unit');
    if (unit.isNotEmpty) return unit;

    final fromAddr = _parseDongHoFromText(baseRaw);
    if (fromAddr.isNotEmpty) {
      return [
        if (fromAddr['dong'] != null) fromAddr['dong']!,
        if (fromAddr['ho'] != null) fromAddr['ho']!,
      ].join(' ').trim();
    }
    return '';
  }

  String _composeNavAddr({
    required String line1,
    required String line2,
    required String detail,
  }) {
    return [
      line1,
      if (line2.trim().isNotEmpty) line2.trim(),
      if (detail.trim().isNotEmpty) detail.trim(),
    ].join(' ');
  }

  String _digitsOrSelf(String s) {
    final m = RegExp(r'\d+').firstMatch(s);
    return m?.group(0) ?? s;
  }

  // detail에서 "###동"만 제거
  String _removeDongToken(String s) {
    return s
        .replaceAll(RegExp(r'\b\d+\s*동\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 1) 각 아이템에서 dong/ho를 뽑아 중간모델로 변환
    final items =
        deliveries.map((d) {
          final baseRaw = _rawAddress(d).isNotEmpty ? _rawAddress(d) : aptName;
          final base = _stripDongHo(baseRaw);

          final split = splitAddressForTwoLines(base);
          final line1 = (split['line1'] ?? base).toString();
          final line2Base = (split['line2'] ?? '').toString().trim();

          final detail = _buildDetailString(d, baseRaw: baseRaw);
          // 동/호 개별 추출
          final parsedFromDetail = _parseDongHoFromText(detail);
          String dong = parsedFromDetail['dong'] ?? '';
          String ho = parsedFromDetail['ho'] ?? '';

          // 혹시 detail에 없으면 baseRaw에서 보조 추출
          if (dong.isEmpty || (ho.isEmpty && detail.isEmpty)) {
            final fromAddr = _parseDongHoFromText(baseRaw);
            dong = dong.isNotEmpty ? dong : (fromAddr['dong'] ?? '');
            ho = ho.isNotEmpty ? ho : (fromAddr['ho'] ?? '');
          }

          // 표시용 line2 (기존 방식)
          final displayLine2 =
              [
                if (line2Base.isNotEmpty) line2Base,
                if (detail.isNotEmpty) detail,
              ].join(' ').trim();

          final navAddr = _composeNavAddr(
            line1: line1,
            line2: line2Base,
            detail: detail,
          );

          return _ItemInfo(
            original: d,
            base: base, // 한 줄 주소(동/호 제거된)
            line1: line1,
            line2Base: line2Base,
            displayLine2: displayLine2,
            dong: dong, // "102동" 형태 또는 빈 문자열
            ho: ho, // "1007호" 형태 또는 빈 문자열
            navAddr: navAddr,
          );
        }).toList();

    // 2) 동 단위로 그룹핑
    final Map<String, List<_ItemInfo>> byDong = {};
    for (final it in items) {
      final key = it.dong.trim();
      if (key.isEmpty) continue;
      byDong.putIfAbsent(key, () => []);
      byDong[key]!.add(it);
    }

    // 3) 그룹 결과 + 단일 항목을 최종 rows로 변환
    final List<_RowViewModel> rows = [];

    // (a) 동 그룹: 같은 동이 2개 이상일 때만 묶어서 한 행으로 생성
    final groupedDongKeys =
        byDong.keys.toList()..sort(
          (a, b) => (int.tryParse(_digitsOrSelf(a)) ?? 0).compareTo(
            int.tryParse(_digitsOrSelf(b)) ?? 0,
          ),
        );
    for (final dong in groupedDongKeys) {
      final list = byDong[dong]!;
      if (list.length < 2) continue; // 두 개 이상일 때만 그룹 처리

      // 대표 base는 첫 아이템 기준(같은 단지 내라 동일할 확률이 큼)
      final base = list.first.base;

      // ho 목록만 뽑아 ‘1007호 / 1008호’로 만들기 (없으면 detail에서 보조)
      final hos = <String>[];
      for (final it in list) {
        String ho = it.ho.trim();
        if (ho.isEmpty) {
          // displayLine2에서 보조 추출
          final m = RegExp(r'(\d+)\s*호').firstMatch(it.displayLine2);
          if (m != null) ho = '${m.group(1)}호';
        }
        if (ho.isNotEmpty) hos.add(ho);
      }
      // 중복 제거 + 정렬(숫자 기준)
      final seen = <String>{};
      final uniqueHos = <String>[];
      for (final h in hos) {
        final key = _digitsOrSelf(h);
        if (seen.add(key)) uniqueHos.add(h);
      }
      uniqueHos.sort(
        (a, b) => int.tryParse(
          _digitsOrSelf(a),
        )!.compareTo(int.tryParse(_digitsOrSelf(b))!),
      );

      final hoJoined = uniqueHos.isNotEmpty ? uniqueHos.join(' / ') : '';
      final line1 = dong; // 굵게 보여줄 "102동"

      // ✅ grouped line2에서 동 제거: base + (호들) 만 표시
      final line2 = [base, if (hoJoined.isNotEmpty) hoJoined].join(' ').trim();

      rows.add(
        _RowViewModel(
          original: list.first.original,
          line1: line1,
          line2: line2,
          navAddr: list.first.navAddr,
          isDongGroup: true,
        ),
      );
    }

    // (b) 단일/비그룹 항목: dong이 없거나 동에 1개뿐인 것
    for (final it in items) {
      final inMultiDongGroup =
          it.dong.isNotEmpty &&
          byDong.containsKey(it.dong) &&
          byDong[it.dong]!.length >= 2;
      if (inMultiDongGroup) continue; // 이미 그룹으로 표시됨

      // 동이 1개인 것도 제목에 동을 올리고, 얇은 줄에서는 동을 제거
      if (it.dong.isNotEmpty) {
        // displayLine2 = line2Base + detail. detail만 뽑아서 동 제거
        String detailPart = it.displayLine2;
        if (it.line2Base.isNotEmpty && detailPart.startsWith(it.line2Base)) {
          detailPart = detailPart.substring(it.line2Base.length).trim();
        }
        // ho가 있으면 ho만, 없으면 detail에서 "###동"만 제거
        final detailSansDong =
            it.ho.isNotEmpty ? it.ho : _removeDongToken(detailPart);

        final line1 = it.dong; // 굵은 줄에 동
        final line2 =
            [
              it.base, // 얇은 줄은 base
              if (detailSansDong.isNotEmpty) detailSansDong, // 동은 제외
            ].join(' ').trim();

        rows.add(
          _RowViewModel(
            original: it.original,
            line1: line1,
            line2: line2,
            navAddr: it.navAddr,
            isDongGroup: false,
          ),
        );
      } else {
        // 동 정보가 없으면 기존 방식
        rows.add(
          _RowViewModel(
            original: it.original,
            line1: it.line1,
            line2: it.displayLine2,
            navAddr: it.navAddr,
            isDongGroup: false,
          ),
        );
      }
    }

    // 보기 좋게 정렬: 동 그룹(숫자 오름) 먼저, 그 뒤 기존 규칙
    int _numFrom(String s, String label) {
      final m = RegExp(r'(\d+)\s*' + label).firstMatch(s);
      return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
    }

    rows.sort((a, b) {
      // 동 그룹 우선
      if (a.isDongGroup != b.isDongGroup) {
        return a.isDongGroup ? -1 : 1;
      }
      if (a.isDongGroup && b.isDongGroup) {
        // "102동" 숫자 비교
        final ad = _numFrom(a.line1, '동');
        final bd = _numFrom(b.line1, '동');
        if (ad != bd) return ad.compareTo(bd);
        return a.line2.compareTo(b.line2);
      }
      // 일반 항목은 기존 규칙
      final c1 = a.line1.compareTo(b.line1);
      if (c1 != 0) return c1;
      final ad = _numFrom(a.line2, '동');
      final bd = _numFrom(b.line2, '동');
      if (ad != bd) return ad.compareTo(bd);
      final ah = _numFrom(a.line2, '호');
      final bh = _numFrom(b.line2, '호');
      if (ah != bh) return ah.compareTo(bh);
      return a.line2.compareTo(b.line2);
    });

    // ====== 스크롤 조건: 3개 이상이면 스크롤, 2개 이하면 내용만큼 ======
    final bool useScroll = rows.length >= 3;
    const maxSheetRatio = 0.9;
    final screenH = MediaQuery.of(context).size.height;
    final maxSheetH = screenH * maxSheetRatio;

    Widget buildList({required bool scroll}) {
      final base = ListView.separated(
        shrinkWrap: !scroll,
        physics:
            scroll
                ? const BouncingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder:
            (_, __) => const Divider(height: 1, color: Color(0xFFEDEDED)),
        itemBuilder: (context, index) {
          final r = rows[index];
          return InkWell(
            onTap: () => onTapItem?.call(Map<String, String>.from(r.original)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 14.5,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // line1: 일반은 주소 1줄, 동그룹/단일동이면 "102동"이 굵게
                        Text(
                          r.line1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: r.isDongGroup ? 16 : 15,
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (r.line2.isNotEmpty)
                          Text(
                            r.line2,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color: const Color.fromARGB(255, 58, 58, 58),
                              fontSize: 13.5,
                              height: 1.2,
                            ),
                          ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      // 기존 콜백도 유지
                      onTapNavigate?.call({
                        ...r.original,
                        'navAddr': r.navAddr,
                      });
                      // ✅ 네이버 길찾기 호출 (주소 문자열 전달)
                      startNaviToAddressWithNaver(r.navAddr);
                    },
                    child: SvgPicture.asset(
                      'assets/images/home/marker.svg',
                      width: 30,
                      height: 30,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFF61D5AB),
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

      if (!scroll) return base;
      return SizedBox(height: maxSheetH * 0.3, child: base);
    }

    // 전체 시트: 화면 90% 제한 + 손잡이/헤더 고정(기존 스타일 유지)
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetH),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Material(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 15),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(100),
                      ),
                    ),
                  ),
                  const SizedBox(height: 17),

                  // 헤더(검정 마커 + 주소 + 총 N건)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SvgPicture.asset(
                              'assets/images/home/marker.svg',
                              width: 30,
                              height: 30,
                              colorFilter: const ColorFilter.mode(
                                Colors.black,
                                BlendMode.srcIn,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    aptName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '총 ${rows.length}건',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall?.copyWith(
                                      color: Colors.black45,
                                      fontSize: 12.5,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Divider(height: 1, color: Color(0xFFEDEDED)),
                      ],
                    ),
                  ),

                  // 리스트
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: buildList(scroll: useScroll),
                  ),

                  if (useScroll) const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 내부 가공 모델: 동/호 포함
class _ItemInfo {
  final Map<String, String> original;
  final String base; // "서울시 성북구 보문사길 111" (동/호 제거된 한 줄)
  final String line1; // 분할 1줄
  final String line2Base; // 분할 2줄 베이스
  final String displayLine2; // 기존 표시 "line2Base + detail"
  final String dong; // "102동"
  final String ho; // "1007호"
  final String navAddr;

  _ItemInfo({
    required this.original,
    required this.base,
    required this.line1,
    required this.line2Base,
    required this.displayLine2,
    required this.dong,
    required this.ho,
    required this.navAddr,
  });
}

class _RowViewModel {
  final Map<String, String> original;
  final String line1; // 일반: 주소 1줄 / 동그룹·단일동: "102동"
  final String line2; // 일반: 분할2 + detail / 동그룹·단일동: "베이스 + 호들(or 호)"
  final String navAddr; // 길찾기 주소
  final bool isDongGroup;

  _RowViewModel({
    required this.original,
    required this.line1,
    required this.line2,
    required this.navAddr,
    this.isDongGroup = false,
  });
}
