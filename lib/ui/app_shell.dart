import 'package:flutter/material.dart';

import '../screens/capture_screen.dart';
import '../screens/outfits_gallery_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/suggestions_screen.dart';
import '../screens/wardrobe_screen.dart';
import 'theme.dart';

/// Notifies the wardrobe grid that a just-saved item should show the
/// one-second highlight fade (userFlow.md flow 2, step 5). The add-item
/// flow starts from the shell's FAB, so the new item's id travels through
/// here rather than a Navigator result on a tab root.
final ValueNotifier<int?> newPieceHighlight = ValueNotifier<int?>(null);

/// App-level navigation shell (design.md section 5): four preserved-state
/// tab roots - Wardrobe, Outfits, Suggest, Settings - plus a floating white
/// pill nav docked bottom-center and a black circular + FAB to its right
/// that starts the add-item flow from anywhere.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  Future<void> _startAddFlow() async {
    final id = await Navigator.of(context).push<int>(
      appRoute(const CaptureScreen()),
    );
    if (id != null) newPieceHighlight.value = id;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Content scrolls beneath the floating nav (Fitted pattern).
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: const [
          WardrobeScreen(),
          OutfitsGalleryScreen(),
          SuggestionsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.gutter, 0, Spacing.gutter, 8),
          child: Row(
            children: [
              Expanded(child: _NavPill(current: _tab, onSelect: (i) => setState(() => _tab = i))),
              const SizedBox(width: 12),
              FloatingActionButton(
                onPressed: _startAddFlow,
                tooltip: 'Add item',
                child: const Icon(AppIcons.add),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The white pill with the four tabs: icon above a 13px label, active tab
/// ink, inactive ink-secondary (design.md sections 4-5). The pill carries
/// the app's single allowed soft shadow.
class _NavPill extends StatelessWidget {
  final int current;
  final ValueChanged<int> onSelect;

  const _NavPill({required this.current, required this.onSelect});

  static const _tabs = [
    (icon: AppIcons.wardrobe, label: 'Wardrobe'),
    (icon: AppIcons.outfits, label: 'Outfits'),
    (icon: AppIcons.suggest, label: 'Suggest'),
    (icon: AppIcons.settings, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: c.hairline),
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, 4),
            blurRadius: 20,
            color: Colors.black.withValues(alpha: 0.12),
          ),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _tabs[i].icon,
                      size: 22,
                      color: i == current ? c.ink : c.inkSecondary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _tabs[i].label,
                      style: AppText.caption(context).copyWith(
                        fontSize: 13,
                        color: i == current ? c.ink : c.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
