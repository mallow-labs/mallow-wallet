import 'package:flutter/material.dart';

import '../services/browser_domain_policy.dart';

/// The registrable domain of [host]: `jup.ag` for `app.jup.ag`, `bbc.co.uk`
/// for `www.bbc.co.uk`. The bundled public suffix list includes private rules.
/// Unknown suffixes, IP addresses, and single labels stay whole.
String browserRegistrableDomain(String host) =>
    BrowserDomainPolicy.registrableDomain(host);

/// Shortens [host] to fit [maxWidth] by eliding from the start, so the end
/// of the host (the registrable domain that says whose site it is) always
/// stays visible: `jup.ag.claim-verify.xyz` becomes `…claim-verify.xyz`,
/// never `jup.ag.claim-ve…`. The registrable domain itself is never cut, so
/// the result can still be wider than [maxWidth].
@visibleForTesting
String browserElideHost(
  String host,
  TextStyle style,
  TextScaler scaler,
  double maxWidth,
) {
  if (!maxWidth.isFinite) return host;
  double width(String text) => _lineWidth(text, style, scaler);

  // A pixel of slack: rounding must never clip the end that matters.
  final limit = maxWidth - 1;
  if (width(host) <= limit) return host;
  // Smallest cut that fits, but never into the registrable domain: past
  // that point the caller scales the text down instead.
  final domain = browserRegistrableDomain(host);
  final floor = host.toLowerCase().endsWith(domain)
      ? host.length - domain.length
      : host.length - 1;
  if (floor <= 0) return host;
  var low = 1, high = floor;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (width('…${host.substring(mid)}') <= limit) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  // "…claim-verify.xyz", not "….claim-verify.xyz".
  if (host[low] == '.' && low < floor) low++;
  return '…${host.substring(low)}';
}

double _lineWidth(String text, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// One line naming a website by its [host], with an optional [detail] (a page
/// title, a path) after it. The host always wins the width: [detail] gets
/// only what is left, and a host too long for the line is elided from the
/// start, keeping its registrable domain in view.
///
/// Pass only a natively committed host here, never page-supplied text.
class BrowserHostText extends StatelessWidget {
  const BrowserHostText(
    this.host, {
    this.style,
    this.detail,
    this.detailStyle,
    this.separator = ' · ',
    super.key,
  });

  final String host;
  final TextStyle? style;
  final String? detail;
  final TextStyle? detailStyle;
  final String separator;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    final detail = this.detail?.trim();
    return Semantics(
      label: detail == null || detail.isEmpty ? host : '$host, $detail',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shown = browserElideHost(
            host,
            base,
            scaler,
            constraints.maxWidth,
          );
          // A registrable domain wider than the line shrinks rather than
          // losing characters.
          final hostText = FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(shown, maxLines: 1, softWrap: false, style: base),
          );
          // The detail only gets room the whole host leaves over.
          final fits =
              shown == host &&
              (!constraints.maxWidth.isFinite ||
                  _lineWidth(host, base, scaler) <= constraints.maxWidth - 1);
          if (detail == null || detail.isEmpty || !fits) return hostText;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              hostText,
              Flexible(
                child: Text(
                  '$separator$detail',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: base.merge(detailStyle),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
