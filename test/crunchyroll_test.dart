import 'dart:convert';

import 'package:lodestar/data/crunchyroll.dart';
import 'package:lodestar/data/importers.dart';
import 'package:lodestar/engine/catalog_loader.dart';
import 'package:lodestar/engine/search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('token + cursor pagination + series aggregation (mocked API)', () async {
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/auth/v1/token') {
        expect(req.headers['Cookie'], 'etp_rt=COOKIE');
        expect(req.bodyFields['grant_type'], 'etp_rt_cookie');
        return http.Response(jsonEncode({'access_token': 'AT'}), 200);
      }
      if (req.url.path == '/accounts/v1/me') return http.Response(jsonEncode({'account_id': 'ACC'}), 200);
      expect(req.headers['Authorization'], 'Bearer AT');
      final page2 = req.url.queryParameters['page'] == '2';
      Map item(String sid, String st, int ep) => {
            'date_played': '2024-05-0$ep',
            'fully_watched': true,
            'panel': {'id': 'e$ep', 'title': 'Ep $ep', 'episode_metadata': {'series_id': sid, 'series_title': st, 'episode_number': ep}}
          };
      return http.Response(
          jsonEncode(page2
              ? {'data': [item('s1', 'Mushishi', 3)], 'meta': {}}
              : {
                  'data': [item('s1', 'Mushishi', 1), item('s2', 'Monster', 2)],
                  'meta': {'next_page': '/content/v2/ACC/watch-history?page=2&page_size=100'}
                }),
          200);
    });
    final series = await CrunchyrollClient(client).fetchHistory('COOKIE');
    expect(series.length, 2);
    expect(series.firstWhere((s) => s.title == 'Mushishi').episodes, 2);

    final store = CatalogStore.open('assets/data/catalog.db');
    final res = parseCrunchyrollSeries(series, store.data, TitleSearch(store.data));
    expect(res.matched, 2);
    expect(res.hints.values.first, contains('episode'));
  });

  test('expired session gives a friendly error', () async {
    final client = MockClient((_) async => http.Response('no', 401));
    expect(CrunchyrollClient(client).fetchHistory('x'), throwsA(isA<CrunchyrollError>()));
  });
}
