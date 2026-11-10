import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// Outlined pill chip (design.md sections 1-2): hairline border, 15/medium
/// ink text, optional trailing chevron for filter dropdowns. The active
/// state is the only strong fill allowed on pills: ink background, white
/// text - the black pill's selected variant.
class FilterChipPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final IconData? trailingIcon;
  final Color? activeColor;

  /// Optional garment swatch dot (named-color options); '#RRGGBB'.
  final String? swatchHex;

  const FilterChipPill({
    super.key,
    required this.label,
    required this.active,
    this.onTap,
    this.trailingIcon,
    this.activeColor,
    this.swatchHex,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
        decoration: BoxDecoration(
          color: active ? (activeColor ?? c.ink) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: active ? (activeColor ?? c.ink) : c.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (swatchHex != null) ...[
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(int.parse(swatchHex!.substring(1), radix: 16)),
                  border: Border.all(color: c.hairline),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: AppText.button(
                context,
                color: active ? c.bg : c.ink,
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              Icon(
                trailingIcon,
                size: 18,
                color: active ? c.bg : c.inkSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
