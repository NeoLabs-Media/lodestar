import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart'
    show ImageRenderMethodForWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/catalog_data.dart';

class Cover extends StatelessWidget {
  /// Tests set this to render placeholders instead of loading network images.
  static bool offline = false;
  final String url;
  final double width, height;
  final double radius;
  const Cover(
    this.url, {
    super.key,
    this.width = 90,
    this.height = 130,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ph = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: cs.surfaceContainerHigh,
      ),
      child: Icon(
        Icons.movie_outlined,
        color: cs.onSurfaceVariant.withValues(alpha: .5),
      ),
    );
    if (url.isEmpty || offline) return ph;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url,
        // The image CDN sends no CORS headers; on the web fall back to a plain <img> element.
        imageRenderMethodForWeb: ImageRenderMethodForWeb.HtmlImage,
        width: width,
        height: height,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, __) => ph,
        errorWidget: (_, __, ___) => ph,
      ),
    );
  }
}

String metaLine(Show t) {
  final parts = <String>[];
  if (t.year != null) parts.add('${t.year}');
  if (t.format != null) parts.add(formatLabel(t.format!));
  if (t.episodes != null && t.episodes! > 0 && t.format != 'MOVIE') {
    parts.add('${t.episodes} ep');
  }
  return parts.join(' · ');
}

String formatLabel(String f) => switch (f) {
  'TV' => 'TV',
  'TV_SHORT' => 'Short',
  'MOVIE' => 'Movie',
  'OVA' => 'OVA',
  'ONA' => 'ONA',
  'SPECIAL' => 'Special',
  _ => f,
};

String members(int pop) {
  if (pop >= 1000000) return '${(pop / 1e6).toStringAsFixed(1)}M';
  if (pop >= 1000)
    return '${(pop / 1000).toStringAsFixed(pop >= 10000 ? 0 : 1)}k';
  return '$pop';
}

class MatchBadge extends StatelessWidget {
  final double match;
  const MatchBadge(this.match, {super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hi = match >= 85;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: hi ? cs.primary : cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${match.round()}% match',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: hi ? cs.onPrimary : cs.onSecondaryContainer,
        ),
      ),
    );
  }
}

class GemBadge extends StatelessWidget {
  final String text;
  const GemBadge(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: const Color(0xCC0D0D0C),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.diamond_outlined,
            size: 11,
            color: Color(0xFF9ED8B5),
          ),
          const SizedBox(width: 5),
          Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: .9,
              color: Color(0xFF9ED8B5),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Copies [text] and confirms with a snackbar.
Future<void> copyText(BuildContext context, String text, {String? what}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text('Copied ${what ?? '“$text”'}'),
      ),
    );
}

/// Display title plus romaji when it differs, e.g. "Frieren: Beyond Journey's End (Sousou no Frieren)".
String copyableTitle(Show t) =>
    (t.titleEn != null && t.titleEn!.isNotEmpty && t.titleEn != t.title)
    ? '${t.titleEn} (${t.title})'
    : t.title;

String kindLabel(String kind) => switch (kind) {
  'anime' => 'Anime',
  'movie' => 'Movie',
  'tv' => 'TV',
  _ => kind,
};

/// Small outlined "ANIME / MOVIE / TV" tag; shown only when the catalog mixes media kinds.
class KindBadge extends StatelessWidget {
  final String kind;
  const KindBadge(this.kind, {super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC0D0D0C),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x66ECE7DC)),
      ),
      child: Text(
        kindLabel(kind).toUpperCase(),
        style: const TextStyle(
          fontSize: 9.5,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w600,
          color: Color(0xFFECE7DC),
        ),
      ),
    );
  }
}
