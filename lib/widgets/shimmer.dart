import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// Quiet loading placeholder (design.md section 7): a soft light sweep over
/// a tile-colored block - never a spinner on cream.
class ShimmerPlaceholder extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const ShimmerPlaceholder({
    super.key,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
  });

  @override
  State<ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<ShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            return Container(
              color: c.tile,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final sweep = constraints.biggest.longestSide * 0.8;
                  final start = -sweep + t * (constraints.biggest.width + 2 * sweep);
                  return Stack(
                    children: [
                      Positioned(
                        left: start,
                        top: 0,
                        width: sweep,
                        height: constraints.biggest.height,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                Colors.transparent,
                                c.surface.withValues(alpha: 0.7),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
