part of '../server_management_view.dart';

const double _overviewSummaryCardWidth = 220;
const double _overviewSummaryCardHeight = 132;

/// The fixed 220x132 summary-card shell (D-57).
///
/// One owner for the `_GaugeCard`/`_InfoCard` Container, which were
/// textually identical: 16-padding, r12, 0.4-alpha divider border.
class _SummaryCardShell extends StatelessWidget {
  const _SummaryCardShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _overviewSummaryCardWidth,
      height: _overviewSummaryCardHeight,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
        ),
      ),
      child: child,
    );
  }
}

/// A metric shell with caller-chosen padding + border alpha (D-57).
///
/// One owner for the r10 divider-border Containers of `_CompactMetricTile`,
/// `_DualThroughputRow`, and `_UtilizationRow`. The alpha is a dumb double:
/// the tile's subtle-conditional stays at its call site.
class _MetricShell extends StatelessWidget {
  const _MetricShell({
    required this.padding,
    required this.borderAlpha,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final double borderAlpha;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: borderAlpha),
        ),
      ),
      child: child,
    );
  }
}

/// A 6px rounded throughput bar (D-57).
///
/// One owner for the dual-throughput row's bar twin: Expanded > ClipRRect
/// (r99) > LinearProgressIndicator. The background reuses [color] at 0.14
/// alpha so the pairings (primary-with-primary, green-with-green) cannot
/// cross; the clamp lives inside because both bars clamp today.
class _ThroughputBar extends StatelessWidget {
  const _ThroughputBar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          value: value.clamp(0, 1),
          minHeight: 6,
          color: color,
          backgroundColor: color.withValues(alpha: 0.14),
        ),
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.color,
  });

  final String title;
  final String subtitle;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return _SummaryCardShell(
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 7,
              color: color,
              backgroundColor: Theme.of(context).dividerColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.value,
    required this.subtitle,
  });

  final String title;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return _SummaryCardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _CompactMetricTile extends StatelessWidget {
  const _CompactMetricTile({
    required this.label,
    required this.value,
    this.subtle = false,
  });

  final String label;
  final String value;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    return _MetricShell(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      borderAlpha: subtle ? 0.25 : 0.35,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _DualThroughputRow extends StatelessWidget {
  const _DualThroughputRow({
    required this.label,
    required this.leftValueLabel,
    required this.rightValueLabel,
    required this.leftFraction,
    required this.rightFraction,
  });

  final String label;
  final String leftValueLabel;
  final String rightValueLabel;
  final double leftFraction;
  final double rightFraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _MetricShell(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderAlpha: 0.25,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                leftValueLabel,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              Text(
                rightValueLabel,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _ThroughputBar(value: leftFraction, color: scheme.primary),
              const SizedBox(width: 8),
              _ThroughputBar(value: rightFraction, color: Colors.green),
            ],
          ),
        ],
      ),
    );
  }
}

class _UtilizationRow extends StatelessWidget {
  const _UtilizationRow({
    required this.label,
    required this.subtitle,
    required this.utilization,
  });

  final String label;
  final String subtitle;
  final double utilization;

  @override
  Widget build(BuildContext context) {
    return _MetricShell(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      borderAlpha: 0.25,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: utilization.clamp(0, 1),
              minHeight: 6,
              color: utilization >= 0.85
                  ? YaruColors.red
                  : utilization >= 0.65
                  ? YaruColors.orange
                  : Colors.green,
              backgroundColor: Theme.of(
                context,
              ).dividerColor.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }
}
