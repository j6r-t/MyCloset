import 'package:flutter/material.dart';

import '../models/item.dart';
import '../ui/theme.dart';
import 'cutout_image.dart';

/// Wardrobe grid tile (design.md section 6.1): cutout floating plain on a
/// whisper tile, no label, no card border - imagery only. Tap opens the
/// item; long-press is wired by the grid (Edit / Delete sheet).
///
/// [highlight] drives the one-second border fade shown right after saving a
/// new item (design.md section 7; userFlow.md flow 2, step 5).
class ItemTile extends StatefulWidget {
  final Item item;
  final bool highlight;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ItemTile({
    super.key,
    required this.item,
    this.highlight = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<ItemTile> createState() => _ItemTileState();
}

class _ItemTileState extends State<ItemTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  bool _highlighted = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: Motion.highlightFade,
      value: widget.highlight ? 1 : 0,
    );
    _highlighted = widget.highlight;
    if (widget.highlight) {
      _fade.forward(from: 1).whenComplete(() {
        if (mounted) setState(() => _highlighted = false);
      });
    }
  }

  @override
  void didUpdateWidget(covariant ItemTile old) {
    super.didUpdateWidget(old);
    if (widget.highlight && !old.highlight) {
      _highlighted = true;
      _fade.forward(from: 1).whenComplete(() {
        if (mounted) setState(() => _highlighted = false);
      });
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _fade,
        builder: (context, child) => Container(
          // Whisper tile: barely distinguishable from the background
          // (design.md section 1). Square corners keep the grid seamless.
          decoration: BoxDecoration(
            color: c.tileWhisper,
            border: _highlighted
                ? Border.all(
                    color: c.ink.withValues(alpha: _fade.value),
                  )
                : null,
          ),
          padding: const EdgeInsets.all(8),
          child: CutoutImage(path: widget.item.cutoutPath),
        ),
      ),
    );
  }
}
