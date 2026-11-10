// Screen 3.5 - Add item, online identification. The explicit loading page
// between the cutout review and the details form: the user asked to SEE the
// lookup happen instead of a silent background auto-fill.
//
// Opened from the cutout review's Continue. When neither identification API
// key is set the screen skips itself immediately (no visual pass-through) -
// the details form carries the setup caption instead. Otherwise a full-page
// state runs AppState.runIdentification over the draft photo (cutout
// preferred):
//   - ok     -> the details form opens (pushReplacement) with the result as
//               its prefill; only EMPTY fields take the suggestions there.
//   - not ok -> the outcome state: search_off icon, a clear "Couldn't
//               identify this piece" title, the result's per-step reason as
//               a caption, and two actions: "Fill in manually" (form) and
//               one "Try again" retry that re-runs the pipeline once.
// The 15s per-request worst case lives in the identification services; this
// screen only renders the phases.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/enums.dart';
import '../services/identification_pipeline.dart';
import '../ui/app_state.dart';
import '../ui/theme.dart';
import '../widgets/cutout_image.dart';
import '../widgets/shimmer.dart';
import 'details_form_screen.dart';

/// Screen 3.5 - Add item, online identification.
class IdentificationScreen extends StatefulWidget {
  /// Draft original path from the capture flow (always present).
  final String draftOriginalPath;

  /// Draft cutout path, or null when segmentation fell back to the original.
  final String? draftCutoutPath;

  const IdentificationScreen({
    super.key,
    required this.draftOriginalPath,
    this.draftCutoutPath,
  });

  @override
  State<IdentificationScreen> createState() => _IdentificationScreenState();
}

class _IdentificationScreenState extends State<IdentificationScreen> {
  /// Whether the lookup is in flight (false shows the not-found outcome).
  bool _loading = true;

  /// The not-found result, once a run finished without anything usable.
  IdentificationResult? _failure;

  /// One retry after a failed run (task spec: retry once); consumed by the
  /// outcome's "Try again" pill, which disappears afterwards.
  bool _retryLeft = true;

  /// Blocks pops (system back included) until the drafts are cleaned up;
  /// flipped before the programmatic pop so the PopScope handler lets it
  /// through.
  bool _canPop = false;

  /// Re-entry guard for the PopScope handler.
  bool _leaving = false;

  /// One-shot AppState read without registering a dependency (safe from
  /// initState's post-frame kickoff).
  AppState? get _stateMaybe =>
      context.getInheritedWidgetOfExactType<AppStateScope>()?.notifier;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// Runs the lookup once. Keyless: skips straight to the form (the form's
  /// setup caption explains why nothing was looked up).
  Future<void> _run() async {
    if (!mounted) return;
    final state = _stateMaybe;
    if (state == null || !(state.serpApiKeySet || state.visionApiKeySet)) {
      _goToForm();
      return;
    }
    setState(() {
      _loading = true;
      _failure = null;
    });
    IdentificationResult result;
    try {
      result = await state.runIdentification(
        imagePath: widget.draftCutoutPath ?? widget.draftOriginalPath,
        // The form's defaults at this point in the flow; used only as the
        // text-search hint when Lens found nothing.
        categoryLabel: Category.top.name,
      );
    } catch (e) {
      debugPrint('Identification run failed: $e');
      result = IdentificationResult.unavailable(
        const ['Identification failed.'],
      );
    }
    if (!mounted) return;
    if (result.ok) {
      _goToForm(result);
      return;
    }
    setState(() {
      _loading = false;
      _failure = result;
    });
  }

  /// One manual retry after a failed run; afterwards the pill is gone.
  void _retry() {
    if (!_retryLeft) return;
    _retryLeft = false;
    unawaited(_run());
  }

  /// Leaves this screen for the details form, handing over the draft paths
  /// and, on a successful lookup, the result to prefill the empty fields.
  void _goToForm([IdentificationResult? prefill]) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      appRoute(
        DetailsFormScreen(
          draftOriginalPath: widget.draftOriginalPath,
          draftCutoutPath: widget.draftCutoutPath,
          prefill: prefill,
        ),
      ),
    );
  }

  /// Exit the flow: drafts are discarded (userFlow.md flow 2, step 5 - no
  /// orphans on disk). Same contract as the cutout review's back: runs for
  /// both the back button and the system back gesture via PopScope.
  Future<void> _discardAndExit() async {
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
    final thumbPath = widget.draftCutoutPath ?? widget.draftOriginalPath;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_leaving) _discardAndExit();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(AppIcons.back),
            onPressed: _discardAndExit,
          ),
        ),
        body: SafeArea(
          child: Center(
            child: _loading
                ? _LoadingView(thumbPath: thumbPath)
                : _OutcomeView(
                    failure: _failure,
                    retryLeft: _retryLeft,
                    onManual: () => _goToForm(),
                    onRetry: _retry,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The in-flight state: the garment cutout floating on its tile backdrop,
/// the title, and three shimmer lines standing in for brand / type / price.
class _LoadingView extends StatelessWidget {
  final String thumbPath;

  const _LoadingView({required this.thumbPath});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 220,
          height: 220,
          padding: const EdgeInsets.all(Spacing.m),
          decoration: BoxDecoration(
            color: AppColors.of(context).tile,
            borderRadius: BorderRadius.circular(16),
          ),
          child: CutoutImage(path: thumbPath, iconSize: 40),
        ),
        const SizedBox(height: Spacing.section),
        Text('Looking up this piece...', style: AppText.title(context)),
        const SizedBox(height: Spacing.m),
        // One shimmer line per auto-fillable field (brand / type / price).
        const ShimmerPlaceholder(width: 260, height: 12),
        const SizedBox(height: Spacing.s),
        const ShimmerPlaceholder(width: 200, height: 12),
        const SizedBox(height: Spacing.s),
        const ShimmerPlaceholder(width: 150, height: 12),
      ],
    );
  }
}

/// The not-found outcome: what happened per step, plus the way out.
class _OutcomeView extends StatelessWidget {
  final IdentificationResult? failure;
  final bool retryLeft;
  final VoidCallback onManual;
  final VoidCallback onRetry;

  const _OutcomeView({
    required this.failure,
    required this.retryLeft,
    required this.onManual,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final notes = failure?.notes ?? const <String>[];
    final reasons = notes.isEmpty ? 'No identification available.' : notes.join(' ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Symbols.search_off, size: 40, color: c.inkSecondary),
        const SizedBox(height: Spacing.m),
        Text(
          "Couldn't identify this piece",
          style: AppText.title(context),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Spacing.s),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.gutter),
          child: Text(
            reasons,
            style: AppText.caption(context),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: Spacing.section),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 260),
          child: FilledButton(
            onPressed: onManual,
            // Primary pill; the theme's textStyle pairs the fill with its
            // on-pill color for the current brightness.
            child: const Text('Fill in manually'),
          ),
        ),
        if (retryLeft) ...[
          const SizedBox(height: Spacing.s),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 260),
            child: OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Symbols.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ),
        ],
      ],
    );
  }
}
