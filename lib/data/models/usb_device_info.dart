class UsbEndpointInfo {
  final int address;
  final String direction; // 'in' | 'out'
  final int type;
  final int maxPacketSize;

  const UsbEndpointInfo({
    required this.address,
    required this.direction,
    required this.type,
    required this.maxPacketSize,
  });

  factory UsbEndpointInfo.fromMap(Map<dynamic, dynamic> map) => UsbEndpointInfo(
        address: map['address'] as int,
        direction: map['direction'] as String,
        type: map['type'] as int,
        maxPacketSize: map['maxPacketSize'] as int,
      );
}

class UsbInterfaceInfo {
  final int interfaceClass;
  final int interfaceSubclass;
  final int interfaceProtocol;
  final List<UsbEndpointInfo> endpoints;

  const UsbInterfaceInfo({
    required this.interfaceClass,
    required this.interfaceSubclass,
    required this.interfaceProtocol,
    required this.endpoints,
  });

  factory UsbInterfaceInfo.fromMap(Map<dynamic, dynamic> map) => UsbInterfaceInfo(
        interfaceClass: map['interfaceClass'] as int,
        interfaceSubclass: map['interfaceSubclass'] as int,
        interfaceProtocol: map['interfaceProtocol'] as int,
        endpoints: (map['endpoints'] as List<dynamic>)
            .cast<Map<dynamic, dynamic>>()
            .map(UsbEndpointInfo.fromMap)
            .toList(),
      );
}

class UsbDeviceInfo {
  final String deviceName;
  final int vendorId;
  final int productId;
  final int deviceClass;
  final int deviceSubclass;
  final int deviceProtocol;
  final String? manufacturerName;
  final String? productName;
  final String? serialNumber;
  final int interfaceCount;
  final bool hasPermission;

  const UsbDeviceInfo({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.deviceClass,
    required this.deviceSubclass,
    required this.deviceProtocol,
    required this.manufacturerName,
    required this.productName,
    required this.serialNumber,
    required this.interfaceCount,
    required this.hasPermission,
  });

  String get vendorIdHex => '0x${vendorId.toRadixString(16).padLeft(4, '0')}';
  String get productIdHex => '0x${productId.toRadixString(16).padLeft(4, '0')}';

  factory UsbDeviceInfo.fromMap(Map<dynamic, dynamic> map) => UsbDeviceInfo(
        deviceName: map['deviceName'] as String,
        vendorId: map['vendorId'] as int,
        productId: map['productId'] as int,
        deviceClass: map['deviceClass'] as int,
        deviceSubclass: map['deviceSubclass'] as int,
        deviceProtocol: map['deviceProtocol'] as int,
        manufacturerName: map['manufacturerName'] as String?,
        productName: map['productName'] as String?,
        serialNumber: map['serialNumber'] as String?,
        interfaceCount: map['interfaceCount'] as int,
        hasPermission: map['hasPermission'] as bool? ?? false,
      );
}
