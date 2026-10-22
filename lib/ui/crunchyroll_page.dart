import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../data/crunchyroll.dart';
import '../data/importers.dart';
import 'rating_tour.dart';

/// "Connect Crunchyroll": the user signs in inside an embedded browser (credentials go only to
/// crunchyroll.com), then one tap imports the watch history and starts the rating tour.
class CrunchyrollPage extends StatefulWidget {
  const CrunchyrollPage({super.key});
  @override
  State<CrunchyrollPage> createState() => _CrunchyrollPageState();
}

class _CrunchyrollPageState extends State<CrunchyrollPage> {
  InAppWebViewController? web;
  String status = '';
  bool busy = false;
  double progress = 0;
  String host = '';

  Future<String?> _cookie() async {
    for (final host in ['https://www.crunchyroll.com', 'https://crunchyroll.com', 'https://beta-api.crunchyroll.com']) {
      final cs = await CookieManager.instance().getCookies(url: WebUri(host));
      for (final c in cs) {
        if (c.name == 'etp_rt' && '${c.value}'.isNotEmpty) return '${c.value}';
      }
    }
    return null;
  }

  Future<void> _import() async {
    final app = context.read<AppState>();
    setState(() {
      busy = true;
      status = 'Checking your login…';
    });
    try {
      final cookie = await _cookie();
      if (cookie == null) {
        setState(() => status = 'Not signed in yet — log in on the page above first, then tap again.');
        return;
      }
      final series = await CrunchyrollClient().fetchHistory(cookie, onProgress: (s) => setState(() => status = s));
      if (series.isEmpty) {
        setState(() => status = 'Your Crunchyroll history is empty.');
        return;
      }
      setState(() => status = 'Matching ${series.length} series…');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (!mounted) return;
      await importCrunchyrollSeries(context, app, series, replaceRoute: true);
    } on CrunchyrollError catch (e) {
      setState(() => status = e.message);
    } catch (e) {
      setState(() => status = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect Crunchyroll'),
        actions: [IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => web?.reload())],
        bottom: progress > 0 && progress < 1
            ? PreferredSize(preferredSize: const Size.fromHeight(3), child: LinearProgressIndicator(value: progress, minHeight: 3))
            : null,
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: cs.primaryContainer.withValues(alpha: .5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Text('Log in to Crunchyroll below as usual — your password goes only to crunchyroll.com, '
              'never to this app. Then tap “Import my history”.', style: TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri('https://www.crunchyroll.com/login')),
            initialSettings: InAppWebViewSettings(javaScriptEnabled: true, userAgent: null),
            onWebViewCreated: (c) => web = c,
            onLoadStop: (_, u) => setState(() => host = u?.host ?? ''),
            onProgressChanged: (_, p) => setState(() => progress = p / 100),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(children: [
              Expanded(
                child: Text(status.isNotEmpty ? status : (host.isEmpty ? 'Loading…' : '🔒 $host'), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: busy ? null : _import,
                icon: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_done),
                label: const Text('Import my history'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Matches Crunchyroll series to the catalog, adds them as watched/unrated, reports what was
/// found and starts the rating tour. Shared by the in-app login (native) and the web bookmarklet.
Future<void> importCrunchyrollSeries(BuildContext context, AppState app, List<CrSeries> series, {bool replaceRoute = false}) async {
  final nav = Navigator.of(context);
  final res = parseCrunchyrollSeries(series, app.data, app.search);
  app.addMany(res.entries);
  app.importHints.addAll(res.hints);
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('Found ${res.matched} of ${series.length} series'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Next: a quick tour to rate them, so recommendations know what you actually loved.'),
          if (res.unmatched.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('${res.unmatched.length} not in the catalog (shorts, specials, adult or very new titles):', style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 4),
            Flexible(child: SingleChildScrollView(child: Text(res.unmatched.take(40).join('\n'), style: const TextStyle(fontSize: 12)))),
          ],
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Start rating tour'))],
    ),
  );
  final route = MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ChangeNotifierProvider.value(value: app, child: const RatingTourPage()),
  );
  if (replaceRoute) {
    nav.pushReplacement(route);
  } else {
    nav.push(route);
  }
}
