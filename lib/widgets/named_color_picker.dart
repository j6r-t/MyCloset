import 'package:flutter/material.dart';

import '../data/named_colors.dart';
import '../ui/theme.dart';

/// The named-color picker (design.md section 6.4): a grid of swatches from
/// the curated list, never a free color wheel - it keeps the suggestion
/// engine's color vocabulary closed.
Future<NamedColor?> showNamedColorPicker(BuildContext context) {
  return showModalBottomSheet<NamedColor>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _NamedColorPickerSheet(),
  );
}

class _NamedColorPickerSheet extends StatelessWidget {
  const _NamedColorPickerSheet();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.gutter,
          Spacing.m,
          Spacing.gutter,
          Spacing.m,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Color', style: AppText.title(context)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(AppIcons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: Spacing.m),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: Spacing.m,
                  crossAxisSpacing: Spacing.m,
                  childAspectRatio: 0.85,
                ),
                itemCount: kNamedColors.length,
                itemBuilder: (context, index) {
                  final named = kNamedColors[index];
                  return GestureDetector(
                    onTap: () => Navigator.of(context).pop(named),
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Color(
                                int.parse(
                                  named.hex.substring(1),
                                  radix: 16,
                                ),
                              ),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: c.hairline),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          named.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption(context).copyWith(
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
