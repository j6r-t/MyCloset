import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/segmentation_service.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/shimmer.dart';
import 'cutout_review_screen.dart';

/// Screen 2 - Add item, capture. Full-bleed presentation of the two entry
/// points (camera or gallery pick), with the onboarding hint in caption size
/// (userFlow.md flow 2, step 1: permissions are requested by the picker at
/// the moment of first use).
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  bool _processing = false;

  /// Blocks pops (system back included) until the drafts are cleaned up;
  /// flipped before the programmatic pop so the PopScope handler lets it
  /// through.
  bool _canPop = false;

  /// Re-entry guard for [PopScope.onPopInvokedWithResult].
  bool _leaving = false;

  Future<void> _pick({required bool fromCamera}) async {
    if (_processing) return;
    setState(() => _processing = true);

    Uint8List? bytes;
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked != null) bytes = await picked.readAsBytes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not get the photo: $e')));
      }
    }

    if (bytes == null) {
      // User cancelled the picker.
      if (mounted) setState(() => _processing = false);
      return;
    }

    // Run the segmentation (backend.md section 3). The current stub always
    // returns null, so the flow lands on the documented fallback: keep the
    // original photo as the item image (section 3.3).
    Uint8List? cutoutPng;
    try {
      final result = await const StubSegmentationService().segment(bytes);
      cutoutPng = result?.cutoutPng;
    } catch (e) {
      debugPrint('Segmentation failed, using original: $e');
      cutoutPng = null;
    }

    if (!mounted) return;

    String? originalPath;
    String? cutoutPath;
    try {
      final storage = AppStateScope.of(context).storage;
      originalPath = await storage.saveDraft(bytes, 'draft_original.jpg');
      if (cutoutPng != null) {
        cutoutPath = await storage.saveDraft(cutoutPng, 'draft_cutout.png');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stage the photo: $e')),
        );
      }
      if (mounted) setState(() => _processing = false);
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      appRoute(
        CutoutReviewScreen(
          draftOriginalPath: originalPath,
          draftCutoutPath: cutoutPath,
        ),
      ),
    );
  }

  /// Cancel: drafts are discarded, no orphans on disk (userFlow.md flow 2,
  /// step 5). Tmp is also cleared on app start as a backstop. Runs for both
  /// the back button and the system back gesture via PopScope.
  Future<void> _cancel() async {
    if (_leaving) return;
    _leaving = true;
    final navigator = Navigator.of(context);
    try {
      await AppStateScope.of(context).storage.clearTmp();
    } catch (_) {
      // Never block the pop on a cleanup failure.
    }
    if (!mounted) return;
    setState(() => _canPop = true);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_leaving) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(AppIcons.back),
            onPressed: _cancel,
          ),
          title: const Text('Add an item'),
        ),
        body: Stack(
          children: [
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.gutter),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(flex: 2),
                    Text(
                      'Show the piece on its own.',
                      textAlign: TextAlign.center,
                      style: AppText.title(context),
                    ),
                    const SizedBox(height: Spacing.s),
                    Text(
                      'Plain background works best.',
                      textAlign: TextAlign.center,
                      style: AppText.caption(context),
                    ),
                    const Spacer(flex: 3),
                    PrimaryCaptureButton(
                      label: 'Take photo',
                      primary: true,
                      onTap: () => _pick(fromCamera: true),
                    ),
                    const SizedBox(height: Spacing.m),
                    PrimaryCaptureButton(
                      label: 'Choose from gallery',
                      onTap: () => _pick(fromCamera: false),
                    ),
                    const SizedBox(height: Spacing.m),
                  ],
                ),
              ),
            ),
            if (_processing)
              Positioned.fill(
                child: ColoredBox(
                  color: c.bg.withValues(alpha: 0.92),
                  child: const SafeArea(
                    child: Padding(
                      padding: EdgeInsets.all(Spacing.gutter),
                      child: Column(
                        children: [
                          SizedBox(height: Spacing.section * 2),
                          AspectRatio(
                            aspectRatio: 0.8,
                            child: ShimmerPlaceholder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(12),
                              ),
                            ),
                          ),
                          SizedBox(height: Spacing.m),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_processing)
              Positioned(
                left: 0,
                right: 0,
                bottom: 64,
                child: Text(
                  'Cutting the background',
                  textAlign: TextAlign.center,
                  style: AppText.caption(context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Local capture-action button (design.md section 6.2): black pill for
/// "Take photo", outlined pill for the gallery.
class PrimaryCaptureButton extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const PrimaryCaptureButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bg = primary ? c.ink : Colors.transparent;
    final fg = primary ? c.bg : c.ink;
    return Material(
      color: bg,
      shape: StadiumBorder(
        side: BorderSide(color: primary ? c.ink : c.hairline),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.section,
            vertical: 14,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.button(context).copyWith(color: fg),
          ),
        ),
      ),
    );
  }
}
