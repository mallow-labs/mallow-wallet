import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/reduce_motion.dart';
import '../../../shared/theme/mallow_theme.dart';
import '../models/ohlcv_candle.dart';

/// Interactive price chart with timeframe selector.
///
/// Displays a line chart of close prices from OHLCV candles, with timeframe
/// pills below and date labels on the X axis.
class TokenPriceChart extends StatelessWidget {
  const TokenPriceChart({
    required this.candles,
    required this.timeframe,
    required this.onTimeframeChanged,
    super.key,
    this.isLoading = false,
  });

  final List<OhlcvCandle> candles;
  final ChartTimeframe timeframe;
  final ValueChanged<ChartTimeframe> onTimeframeChanged;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final showEmpty = candles.isEmpty && !isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 180,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: showEmpty
                ? KeyedSubtree(
                    key: const ValueKey('chart-empty'),
                    child: _buildEmptyChart(context),
                  )
                : _MorphingChart(
                    key: const ValueKey('chart-morph'),
                    candles: candles,
                    isLoading: isLoading,
                    timeframe: timeframe,
                  ),
          ),
        ),
        const SizedBox(height: MallowTheme.spacingSm),
        _TimeframePills(selected: timeframe, onSelected: onTimeframeChanged),
      ],
    );
  }

  Widget _buildEmptyChart(BuildContext context) {
    return Center(
      child: Text(
        'No chart data available',
        style: MallowTheme.uiCaption.copyWith(
          color: context.mallowColors.textTertiary,
        ),
      ),
    );
  }
}

/// Single `LineChart` that morphs from a shimmering gray placeholder line into
/// the real candle data once it arrives. Relies on fl_chart's built-in tween
/// between successive `LineChartData` values — by keeping the widget identity
/// stable, the spots, axis bounds, and line gradient all interpolate together
/// over the easeOutCubic duration when `isLoading` flips false.
class _MorphingChart extends StatefulWidget {
  const _MorphingChart({
    required this.candles,
    required this.isLoading,
    required this.timeframe,
    super.key,
  });

  final List<OhlcvCandle> candles;
  final bool isLoading;
  final ChartTimeframe timeframe;

  @override
  State<_MorphingChart> createState() => _MorphingChartState();
}

class _MorphingChartState extends State<_MorphingChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  // Placeholder spot count matches the request limit fl_chart will receive
  // from each timeframe's `geckoPath` — keeps the morph point-to-point so
  // real candles don't warp in from a padded edge.
  static int _expectedCount(ChartTimeframe tf) {
    return switch (tf) {
      ChartTimeframe.oneHour => 60,
      ChartTimeframe.oneDay => 96,
      ChartTimeframe.oneWeek => 168,
      ChartTimeframe.oneMonth => 180,
      ChartTimeframe.oneYear => 365,
      ChartTimeframe.all => 1000,
    };
  }

  // Memoize the generated placeholder per timeframe so we don't allocate a
  // new list on every shimmer frame.
  final Map<ChartTimeframe, List<FlSpot>> _placeholderCache = {};

  List<FlSpot> _placeholderSpotsFor(ChartTimeframe tf) {
    return _placeholderCache.putIfAbsent(tf, () {
      final count = _expectedCount(tf);
      final last = (count - 1).toDouble();
      return List.generate(count, (i) {
        final t = i / last;
        final y = 0.35 + 0.43 * t + 0.06 * math.sin(t * math.pi * 3.5);
        return FlSpot(i.toDouble(), y);
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      duration: const Duration(milliseconds: 2400),
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShimmer();
  }

  @override
  void didUpdateWidget(covariant _MorphingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncShimmer();
  }

  /// Runs the shimmer sweep only while loading and Reduce Motion is off; under
  /// Reduce Motion the placeholder holds a static gradient (controller parked).
  void _syncShimmer() {
    final shouldRun = widget.isLoading && !context.reduceMotion;
    if (shouldRun && !_shimmer.isAnimating) {
      _shimmer.repeat();
    } else if (!shouldRun && _shimmer.isAnimating) {
      _shimmer.stop();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, _) {
        return LineChart(
          widget.isLoading ? _placeholderData(context) : _realData(context),
          // Shimmer drives its own per-frame animation while loading, so the
          // LineChart doesn't need to tween between consecutive placeholder
          // frames. When isLoading flips false, the longer easeOutCubic
          // duration glides spots, axis bounds, and gradient into place
          // together for the morph.
          duration: widget.isLoading
              ? Duration.zero
              : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
        );
      },
    );
  }

  LineChartData _placeholderData(BuildContext context) {
    final colors = context.mallowColors;
    final t = _shimmer.value * 3 - 1;
    final spots = _placeholderSpotsFor(widget.timeframe);
    return LineChartData(
      minY: 0,
      maxY: 1,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      titlesData: _hiddenTitles(),
      lineTouchData: const LineTouchData(enabled: false),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          // Three-stop horizontal gradient — the middle stop sweeps left to
          // right and is the bright shimmer band. Same gradient structure as
          // the real-data bar below so fl_chart's lerp transitions cleanly
          // into a solid accent gradient on swap.
          gradient: LinearGradient(
            colors: [colors.divider, colors.textTertiary, colors.divider],
            stops: [t - 0.4, t, t + 0.4],
          ),
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
        ),
      ],
    );
  }

  LineChartData _realData(BuildContext context) {
    final colors = context.mallowColors;
    final candles = widget.candles;
    final closePrices = candles.map((c) => c.close).toList();
    final minY = closePrices.reduce((a, b) => a < b ? a : b);
    final maxY = closePrices.reduce((a, b) => a > b ? a : b);
    final range = maxY - minY;
    final padding = range * 0.1;

    final spots = List.generate(
      candles.length,
      (i) => FlSpot(i.toDouble(), candles[i].close),
    );

    return LineChartData(
      minY: minY - padding,
      maxY: maxY + padding,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        topTitles: const AxisTitles(),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: _xInterval(candles.length),
            getTitlesWidget: (value, meta) {
              final index = value.toInt();
              if (index < 0 || index >= candles.length) {
                return const SizedBox.shrink();
              }
              final date = candles[index].dateTime;
              final label = _formatDateLabel(date, widget.timeframe);
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  label,
                  style: MallowTheme.uiCaption.copyWith(
                    color: colors.textTertiary,
                    fontSize: 10,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          // Three-stop solid-accent gradient mirrors the placeholder's
          // gradient structure — same begin/end/length so LinearGradient.lerp
          // can morph color and stops smoothly during the swap.
          gradient: LinearGradient(
            colors: [colors.accent, colors.accent, colors.accent],
            stops: const [0, 0.5, 1],
          ),
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              colors: [
                colors.accent.withValues(alpha: 0.15),
                colors.accent.withValues(alpha: 0.0),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
      ],
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => colors.surfaceMuted,
          // Without these, dragging near an edge draws the price box partly
          // outside the chart box and it gets clipped. fl_chart shifts the
          // tooltip rect back inside the bounds instead.
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              final index = spot.spotIndex;
              if (index < 0 || index >= candles.length) return null;
              final price = candles[index].close;
              return LineTooltipItem(
                _formatPrice(price),
                MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              );
            }).toList();
          },
        ),
      ),
    );
  }

  FlTitlesData _hiddenTitles() {
    return FlTitlesData(
      leftTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      topTitles: const AxisTitles(),
      // Reserve the same bottom strip the loaded chart uses for date labels
      // so the line area is the same height across loading and loaded — no
      // vertical reflow during the morph.
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  double _xInterval(int count) {
    if (count <= 0) return 1;
    return (count / 4).ceilToDouble().clamp(1, count.toDouble());
  }

  String _formatDateLabel(DateTime date, ChartTimeframe tf) {
    return switch (tf) {
      ChartTimeframe.oneHour => DateFormat('HH:mm').format(date),
      ChartTimeframe.oneDay => DateFormat('HH:mm').format(date),
      ChartTimeframe.oneWeek => DateFormat('d MMM').format(date),
      ChartTimeframe.oneMonth => DateFormat('d MMM').format(date),
      ChartTimeframe.oneYear => DateFormat('MMM').format(date),
      ChartTimeframe.all => DateFormat('MMM yy').format(date),
    };
  }

  String _formatPrice(double price) {
    if (price >= 1000) return '\$${(price / 1000).toStringAsFixed(1)}k';
    if (price >= 1) return '\$${price.toStringAsFixed(2)}';
    if (price >= 0.001) return '\$${price.toStringAsFixed(4)}';
    return '\$${price.toStringAsFixed(8)}';
  }
}

class _TimeframePills extends StatelessWidget {
  const _TimeframePills({required this.selected, required this.onSelected});

  final ChartTimeframe selected;
  final ValueChanged<ChartTimeframe> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.mallowColors;
    return Row(
      children: ChartTimeframe.values.map((tf) {
        final isSelected = tf == selected;
        return Expanded(
          child: GestureDetector(
            onTap: () => onSelected(tf),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(MallowTheme.radiusCircular),
                border: Border.all(
                  color: isSelected ? colors.textPrimary : colors.divider,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                tf.label,
                style: MallowTheme.uiCaption.copyWith(
                  color: colors.textPrimary,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
