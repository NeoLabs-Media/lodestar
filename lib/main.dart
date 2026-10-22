import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'platform/splash.dart';
import 'ui/crunchyroll_page.dart';
import 'ui/feed_page.dart';
import 'ui/library_page.dart';
import 'ui/settings_page.dart';
import 'ui/taste_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addPostFrameCallback((_) => removeSplash());
  runApp(ChangeNotifierProvider(create: (_) => AppState()..init(), child: const LodestarApp()));
}

class LodestarApp extends StatelessWidget {
  const LodestarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lodestar',
      debugShowCheckedModeBanner: false,
      theme: Atlas.theme(),
      darkTheme: Atlas.theme(),
      themeMode: ThemeMode.dark,
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  bool _askedPending = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.error != null) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText('Failed to start:\n${app.error}'))));
    }
    if (!app.ready) {
      return const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading Lodestar…'),
          ]),
        ),
      );
    }
    if (!_askedPending && app.pendingCrSeries != null) {
      _askedPending = true;
      final series = app.pendingCrSeries!;
      app.pendingCrSeries = null;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Import from Crunchyroll?'),
            content: Text('Your bookmark found ${series.length} series in your Crunchyroll history. '
                'Add them as watched and rate them one by one?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
            ],
          ),
        );
        // ignore: use_build_context_synchronously
        if (ok == true && mounted) await importCrunchyrollSeries(context, app, series);
      });
    }
    final pages = [
      FeedPage(onGoLibrary: () => setState(() => tab = 1)),
      const LibraryPage(),
      const TastePage(),
      const SettingsPage(),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final dests = const [
      (Icons.auto_awesome_outlined, Icons.auto_awesome, 'For you'),
      (Icons.video_library_outlined, Icons.video_library, 'Library'),
      (Icons.insights_outlined, Icons.insights, 'Taste'),
      (Icons.settings_outlined, Icons.settings, 'Settings'),
    ];
    final body = AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: KeyedSubtree(key: ValueKey(tab), child: pages[tab]));
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: tab,
            minWidth: 76,
            labelType: NavigationRailLabelType.none,
            onDestinationSelected: (i) => setState(() => tab = i),
            leading: const Padding(padding: EdgeInsets.only(top: 22, bottom: 30), child: AtlasMark(size: 26)),
            destinations: [for (final d in dests) NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3))],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Atlas.hair))),
        child: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: [for (final d in dests) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3)],
        ),
      ),
    );
  }
}

/// The four-point guiding star from the app icon.
class AtlasMark extends StatelessWidget {
  final double size;
  const AtlasMark({super.key, this.size = 24});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MarkPainter());
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final c = s.center(Offset.zero);
    final r = s.width / 2;
    final path = Path();
    for (var i = 0; i <= 200; i++) {
      final a = 2 * math.pi * i / 200;
      final cs = math.cos(a), sn = math.sin(a);
      final x = c.dx + r * cs.sign * math.pow(cs.abs(), 2.6);
      final y = c.dy + r * sn.sign * math.pow(sn.abs(), 2.6);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()..color = Atlas.accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
