import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

const _kDeviceId = 'device_id';
const _storage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

class DeviceIdService {
  static Future<String> getOrCreate() async {
    var id = await _storage.read(key: _kDeviceId);
    if (id == null || id.isEmpty) {
      id = 'ha_display_${const Uuid().v4().substring(0, 8)}';
      await _storage.write(key: _kDeviceId, value: id);
    }
    return id;
  }
}

final deviceIdProvider = FutureProvider<String>((ref) async {
  return DeviceIdService.getOrCreate();
});
