import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// One hairline metadata row (design.md sections 6.4-6.5): label at 15
/// regular ink-secondary on the left, the value at 16 regular ink in a
/// fixed column after it, optional trailing pencil edit with a 44px touch
/// target - the Fitted details look.
class MetadataRow extends StatelessWidget {
  final String label;
  final Widget value;

  /// Swatches or a pill selector placed between the label and the value.
  final Widget? leading;

  /// Shows the trailing pencil edit affordance.
  final bool editable;

  /// Overrides the pencil glyph (e.g. a dropdown chevron on picker rows,
  /// like Fitted's Garment Type row). Only used when [editable] is true.
  final IconData? trailingIcon;
  final VoidCallback? onEdit;

  const MetadataRow({
    super.key,
    required this.label,
    required this.value,
    this.leading,
    this.editable = false,
    this.trailingIcon,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 116,
            child: Text(label, style: AppText.fieldLabel(context)),
          ),
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 8),
          ],
          Expanded(child: value),
          if (editable)
            GestureDetector(
              onTap: onEdit,
              behavior: HitTestBehavior.opaque,
              // 44px hit area around the 20px glyph (accessibility floor).
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Icon(
                    trailingIcon ?? AppIcons.edit,
                    size: 20,
                    color: c.inkSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
