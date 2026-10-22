import 'dart:convert';

import 'package:http/http.dart' as http;

/// One Crunchyroll series seen in the user's watch history.
class CrSeries {
  final String id, title;
  int episodes = 0;
  int fullyWatched = 0;
  String? lastWatched;
  CrSeries(this.id, this.title);
}

class CrunchyrollError implements Exception {
  final String message;
  CrunchyrollError(this.message);
  @override
  String toString() => message;
}

/// Reads the signed-in user's own watch history from Crunchyroll's web API, the same way the
/// official web player does (session cookie -> short-lived token -> paginated history).
/// The session cookie comes from the in-app browser the user logged into themselves; the
/// password never reaches this code, and nothing is stored or sent anywhere except crunchyroll.com.
class CrunchyrollClient {
  static const apiBase = 'https://beta-api.crunchyroll.com';
  // Public web-client id embedded in Crunchyroll's own web app (no secret).
  static const clientId = 'noaihdevm_6iyg0a8l0q';
  final http.Client _http;
  CrunchyrollClient([http.Client? client]) : _http = client ?? http.Client();

  Future<List<CrSeries>> fetchHistory(String etpRt, {void Function(String)? onProgress}) async {
    onProgress?.call('Signing in…');
    final basic = base64.encode(utf8.encode('$clientId:'));
    final tok = await _http.post(
      Uri.parse('$apiBase/auth/v1/token'),
      headers: {
        'Authorization': 'Basic $basic',
        'Cookie': 'etp_rt=$etpRt',
        'User-Agent': 'Mozilla/5.0',
      },
      body: {
        'grant_type': 'etp_rt_cookie',
        'scope': 'offline_access',
        'device_id': _uuid(),
        'device_name': 'Chrome on macOS',
        'device_type': 'com.crunchyroll.desktop.windows',
      },
    );
    if (tok.statusCode == 401 || tok.statusCode == 403) {
      throw CrunchyrollError('Crunchyroll did not accept the session — please log in again.');
    }
    if (tok.statusCode != 200) throw CrunchyrollError('Sign-in failed (HTTP ${tok.statusCode}).');
    final access = (jsonDecode(tok.body) as Map)['access_token'] as String;
    final auth = {'Authorization': 'Bearer $access', 'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'};
    final me = await _http.get(Uri.parse('$apiBase/accounts/v1/me'), headers: auth);
    if (me.statusCode != 200) throw CrunchyrollError('Could not read your account (HTTP ${me.statusCode}).');
    final account = (jsonDecode(me.body) as Map)['account_id'] as String;

    final series = <String, CrSeries>{};
    var url = '$apiBase/content/v2/$account/watch-history?page_size=100&locale=en-US';
    final seen = <String>{};
    var pages = 0, eps = 0;
    while (seen.add(url)) {
      final r = await _http.get(Uri.parse(url), headers: auth);
      if (r.statusCode != 200) {
        if (series.isNotEmpty) break; // keep what we have
        throw CrunchyrollError('History request failed (HTTP ${r.statusCode}).');
      }
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final data = (body['data'] as List?) ?? const [];
      for (final item in data.cast<Map>()) {
        final panel = (item['panel'] as Map?) ?? const {};
        if (panel.isEmpty) continue;
        final meta = (panel['episode_metadata'] as Map?) ?? const {};
        final id = '${meta['series_id'] ?? panel['id'] ?? ''}';
        final title = '${meta['series_title'] ?? panel['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        final s = series.putIfAbsent(id.isEmpty ? title : id, () => CrSeries(id, title));
        s.episodes++;
        if (item['fully_watched'] == true) s.fullyWatched++;
        final d = item['date_played'] as String?;
        if (d != null && (s.lastWatched == null || d.compareTo(s.lastWatched!) > 0)) s.lastWatched = d;
        eps++;
      }
      pages++;
      onProgress?.call('Reading history… $eps episodes, ${series.length} series');
      final next = ((body['meta'] as Map?)?['next_page'] as String?) ?? '';
      if (data.isEmpty || next.isEmpty) break;
      url = next.startsWith('http') ? next : '$apiBase$next';
      if (pages > 500) break;
    }
    return series.values.toList();
  }

  static String _uuid() {
    final r = DateTime.now().microsecondsSinceEpoch;
    String h(int n) => ((r * (n + 7919)) & 0xffff).toRadixString(16).padLeft(4, '0');
    return '${h(1)}${h(2)}-${h(3)}-4${h(4).substring(1)}-a${h(5).substring(1)}-${h(6)}${h(7)}${h(8)}';
  }
}
