import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/backup_service.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';

/// Screen 9 - Settings (tab root, design.md section 6.9): a plain hairline
/// list - Export backup, Restore, About. Minimal.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = AppStateScope.of(context);
      final zipPath = await state.createBackup();
      await state.shareBackup(zipPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup created')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    if (_busy) return;
    final state = AppStateScope.of(context);

    // Restore picks from backups previously exported into the app's
    // backups directory (userFlow.md flow 7; a system file picker is not
    // part of the MVP package set).
    List<String> backups;
    try {
      backups = await state.listBackups();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not list backups: $e')),
        );
      }
      return;
    }
    if (!mounted) return;
    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No backups yet - export one first'),
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Choose a backup', style: AppText.title(sheetContext)),
              const SizedBox(height: Spacing.m),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: backups.length,
                  itemBuilder: (context, index) {
                    final path = backups[index];
                    final name = path
                        .split(Platform.pathSeparator)
                        .last;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        AppIcons.archive,
                        size: 20,
                        color: AppColors.of(sheetContext).inkSecondary,
                      ),
                      title: Text(name, style: AppText.value(sheetContext)),
                      onTap: () => Navigator.of(sheetContext).pop(path),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;

    setState(() => _busy = true);
    try {
      // Validate first (backend.md section 6).
      final preview = await state.validateBackup(selected);
      if (!preview.valid) {
        throw BackupException(preview.error ?? 'Invalid backup');
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Restore this backup?'),
          content: Text(
            'This replaces your current closet - ${preview.itemCount} items '
            'will be removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await state.restoreBackup(selected);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Closet restored')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final state = AppStateScope.of(context);
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tab-root title.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.gutter,
              Spacing.m,
              Spacing.gutter,
              0,
            ),
            child: Text('Settings', style: AppText.title(context)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Spacing.gutter),
              children: [
                _SettingsRow(
                  icon: AppIcons.archive,
                  title: 'Export backup',
                  subtitle: 'Zips the closet database and all images, then '
                      'opens the share sheet.',
                  onTap: _export,
                  enabled: !_busy,
                ),
                _SettingsRow(
                  icon: AppIcons.restore,
                  title: 'Restore',
                  subtitle: 'Replaces your closet with a backup exported '
                      'here. Nothing to undo.',
                  onTap: _restore,
                  enabled: !_busy,
                ),
                const SizedBox(height: Spacing.section),
                // Theme (System / Light / Dark). The choice applies
                // immediately and persists in the app_settings table.
                _ThemeRow(
                  mode: state.themeMode,
                  onSelect: (mode) => state.setThemeMode(mode),
                ),
                const SizedBox(height: Spacing.section),
                // Online identification keys (the app's only networked
                // feature). Stored in app_settings; the UI only ever shows
                // Set/Not set - never the value.
                Text(
                  'Online identification',
                  style: AppText.label(context),
                ),
                const SizedBox(height: Spacing.s),
                Text(
                  'Optional. Lets the details form look up a garment online '
                  'when you ask it to. Keys stay on this phone.',
                  style: AppText.caption(context),
                ),
                const SizedBox(height: Spacing.m),
                _ApiKeyField(
                  label: 'SerpAPI key',
                  whereToGet: 'serpapi.com - sign in, then API key page.',
                  isSet: state.serpApiKeySet,
                  onSave: (value) => state.setSerpApiKey(value),
                ),
                _ApiKeyField(
                  label: 'Cloud Vision key',
                  whereToGet:
                      'Google Cloud Console - APIs & Services - Credentials.',
                  isSet: state.visionApiKeySet,
                  onSave: (value) => state.setVisionApiKey(value),
                ),
                const SizedBox(height: Spacing.s),
                Text(
                  'Free tiers: SerpApi 100 searches/month, Cloud Vision '
                  '1,000 calls/month. Each lookup uses at most one per key.',
                  style: AppText.caption(context),
                ),
                const SizedBox(height: Spacing.section),
                _SettingsRow(
                  icon: AppIcons.info,
                  title: 'About',
                  subtitle: 'MyCloset - a personal wardrobe app. Everything '
                      'stays on this phone.',
                  onTap: () {
                    showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('MyCloset'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Version 1.0.0',
                              style: AppText.value(dialogContext),
                            ),
                            const SizedBox(height: Spacing.s),
                            Text(
                              'Personal use only. No account, no server - '
                              'the database and images live on this phone. '
                              'Keep your exported backups somewhere safe.',
                              style: AppText.caption(dialogContext),
                            ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    );
                  },
                  enabled: true,
                ),
                if (_busy)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.section),
                    child: Text(
                      'Working…',
                      textAlign: TextAlign.center,
                      style: AppText.caption(context, color: c.inkSecondary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Theme settings row: a hairline row naming the preference with a
/// three-option pill selector (System / Light / Dark) - active pill filled
/// with ink, content on it (design.md section 1 pill styles; the primary
/// pairing inverts itself per brightness through the tokens).
class _ThemeRow extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onSelect;

  const _ThemeRow({required this.mode, required this.onSelect});

  static const _options = [
    (mode: ThemeMode.system, label: 'System'),
    (mode: ThemeMode.light, label: 'Light'),
    (mode: ThemeMode.dark, label: 'Dark'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.m),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.light_mode, size: 22, color: c.inkSecondary),
          const SizedBox(width: Spacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Theme', style: AppText.label(context)),
                const SizedBox(height: 2),
                Text(
                  'Applies to the whole app and stays after a restart.',
                  style: AppText.caption(context),
                ),
                const SizedBox(height: Spacing.s),
                Wrap(
                  spacing: Spacing.s,
                  runSpacing: Spacing.s,
                  children: [
                    for (final option in _options)
                      _ThemePill(
                        label: option.label,
                        active: option.mode == mode,
                        onTap: () => onSelect(option.mode),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One selectable pill in the theme row: ink fill with on-ink content when
/// active, hairline outline otherwise.
class _ThemePill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ThemePill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
        decoration: BoxDecoration(
          color: active ? c.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: active ? c.ink : c.hairline),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppText.button(context, color: active ? c.bg : c.ink),
        ),
      ),
    );
  }
}

/// One hairline row: icon, title, subtitle.
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: Spacing.m),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.hairline)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: c.inkSecondary),
            const SizedBox(width: Spacing.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.label(context)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.caption(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One API key row (Settings > Online identification): obscured, paste-friendly
/// input saved on submit. The stored value is never shown - only a "Set" /
/// "Not set" caption - and the field always starts empty, so even a shared
/// screen or screenshot never reveals the key.
class _ApiKeyField extends StatefulWidget {
  final String label;
  final String whereToGet;
  final bool isSet;
  final Future<void> Function(String value) onSave;

  const _ApiKeyField({
    required this.label,
    required this.whereToGet,
    required this.isSet,
    required this.onSave,
  });

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      // Clear the entry field after saving; the stored value is never shown.
      _controller.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the key: $e')),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.m),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: AppText.label(context)),
          const SizedBox(height: 2),
          Text(widget.whereToGet, style: AppText.caption(context)),
          const SizedBox(height: Spacing.s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  // Paste works normally; the field just hides what is in it.
                  onSubmitted: (_) => _save(),
                  style: AppText.value(context),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.isSet ? 'Key saved' : 'Paste key',
                    hintStyle: AppText.caption(context),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: c.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: c.ink),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.s),
              GestureDetector(
                onTap: _save,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    _saving ? AppIcons.check : Symbols.save,
                    size: 22,
                    color: c.inkSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.s),
          Text(
            widget.isSet ? 'Set' : 'Not set',
            style: AppText.caption(
              context,
              color: widget.isSet ? c.money : c.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
