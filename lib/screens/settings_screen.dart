import 'dart:io';

import 'package:flutter/material.dart';

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
