/// - 배송 상세 화면에서 쓰는 **데이터 모델** 모음.

class Product {
  final String productId;
  final String recipientName;
  final String recipientPhone;
  final String address;
  final String detailAddress;
  final String shippingStatus;

  Product({
    required this.productId,
    required this.recipientName,
    required this.recipientPhone,
    required this.address,
    required this.detailAddress,
    required this.shippingStatus,
  });

  factory Product.fromJson(Map<String, dynamic> j) => Product(
    productId: j['productId'].toString(),
    recipientName: (j['recipientName'] ?? '').toString(),
    recipientPhone: (j['recipientPhone'] ?? '').toString(),
    address: (j['address'] ?? '').toString(),
    detailAddress: (j['detailAddress'] ?? '').toString(),
    shippingStatus: (j['shippingStatus'] ?? '').toString(),
  );
}

class UnitGroup {
  final String unit; // "1002호"
  final List<Product> products;
  UnitGroup({required this.unit, required this.products});
}

class DeliveryArea {
  final String base; // "기본주소"
  final String building; // "206동"
  final List<UnitGroup> units;

  DeliveryArea({
    required this.base,
    required this.building,
    required this.units,
  });

  String get name => '$base $building';
  int get total => units.fold(0, (s, u) => s + u.products.length);
}
