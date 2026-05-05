import 'package:flutter/material.dart';
import 'theme/nsfw_theme.dart';

/// Animated placeholder tile shown in the gallery before any results stream in.
/// Uses a slow opacity pulse — light enough not to be distracting on a dense
/// grid, but enough to signal that content is loading.
class NsfwSkeletonTile extends StatefulWidget {
  final NsfwTheme? theme;
  final BorderRadius? borderRadius;

  const NsfwSkeletonTile({super.key, this.theme, this.borderRadius});

  @override
  State<NsfwSkeletonTile> createState() => _NsfwSkeletonTileState();
}

class _NsfwSkeletonTileState extends State<NsfwSkeletonTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _alpha;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _alpha = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ?? NsfwTheme.defaults();
    final radius = widget.borderRadius ?? theme.gallery.tileBorderRadius;
    final base = theme.surfaceVariant;
    return AnimatedBuilder(
      animation: _alpha,
      builder: (_, __) => ClipRRect(
        borderRadius: radius,
        child: Container(color: base.withValues(alpha: _alpha.value * 0.6)),
      ),
    );
  }
}

/// Convenience grid of skeleton tiles. Drop in while permission is pending or
/// before the first result reaches the UI.
class NsfwSkeletonGrid extends StatelessWidget {
  final int crossAxisCount;
  final int itemCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final NsfwTheme? theme;
  final EdgeInsets padding;

  const NsfwSkeletonGrid({
    super.key,
    this.crossAxisCount = 3,
    this.itemCount = 12,
    this.crossAxisSpacing = 2,
    this.mainAxisSpacing = 2,
    this.theme,
    this.padding = const EdgeInsets.all(2),
  });

  @override
  Widget build(BuildContext context) => GridView.builder(
        padding: padding,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: crossAxisSpacing,
          mainAxisSpacing: mainAxisSpacing,
        ),
        itemCount: itemCount,
        itemBuilder: (_, __) => NsfwSkeletonTile(theme: theme),
      );
}
