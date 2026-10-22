import '../engine/recommender.dart';
import 'user_store_native.dart' if (dart.library.js_interop) 'user_store_web.dart' as impl;

/// On-device user data (entries + settings). SQLite on native platforms, browser localStorage on web.
abstract class UserStore {
  static UserStore open(String path) => impl.openUserStore(path);

  List<UserEntry> all();
  void put(UserEntry e);
  void putAll(Iterable<UserEntry> entries);
  void clear();
  void remove(int id);
  String? setting(String key);
  void setSetting(String key, String value);
  void close();
}
