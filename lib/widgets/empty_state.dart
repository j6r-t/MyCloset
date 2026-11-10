import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// Centered ink statement plus one outlined pill action, no illustration
/// (design.md section 8: whitespace IS the illustration).
class EmptyState extends StatelessWidget {
  final String statement;
  final String? sub;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.statement,
    this.sub,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.gutter + 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              statement,
              textAlign: TextAlign.center,
              style: AppText.title(context),
            ),
            if (sub != null) ...[
              const SizedBox(height: Spacing.s),
              Text(
                sub!,
                textAlign: TextAlign.center,
                style: AppText.caption(context),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: Spacing.m),
              OutlinedButton(
                onPressed: onAction,
                child: Text(actionLabel!, style: AppText.button(context)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
