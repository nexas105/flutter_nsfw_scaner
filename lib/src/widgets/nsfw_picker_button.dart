import 'package:flutter/material.dart';
import '../api/nsfw_detector.dart';
import '../api/picked_media.dart';
import '../api/scan_configuration.dart';
import '../api/scan_session.dart';
import 'theme/nsfw_theme.dart';

/// One-shot pick-and-scan trigger. Renders a `FilledButton.icon` that opens the
/// native picker, scans the selection, and hands back a [ScanSession] via
/// [onSession]. The button shows a small loading indicator while the picker
/// is open and the scan is starting.
///
/// For a "pick only" flow without classification, use
/// [NsfwDetector.pickMedia] directly.
class NsfwPickerButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final int maxItems;
  final MediaPickerType type;
  final ScanConfiguration? config;
  final void Function(ScanSession session) onSession;
  final NsfwTheme? theme;

  const NsfwPickerButton({
    super.key,
    required this.label,
    required this.onSession,
    this.icon = Icons.add_photo_alternate_rounded,
    this.maxItems = 1,
    this.type = MediaPickerType.any,
    this.config,
    this.theme,
  });

  @override
  State<NsfwPickerButton> createState() => _NsfwPickerButtonState();
}

class _NsfwPickerButtonState extends State<NsfwPickerButton> {
  bool _busy = false;

  Future<void> _go() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = await NsfwDetector.instance.pickAndScan(
        maxItems: widget.maxItems,
        config: widget.config,
      );
      widget.onSession(session);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Picker failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? NsfwTheme.defaults();
    return FilledButton.icon(
      onPressed: _busy ? null : _go,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Icon(widget.icon),
      label: Text(widget.label),
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        padding: EdgeInsets.symmetric(
          horizontal: t.spacing.lg,
          vertical: t.spacing.md,
        ),
      ),
    );
  }
}

/// Convenience wrapper around [NsfwDetector.pickMedia] that exposes a button
/// returning the picked items without scanning them. Pair with
/// [NsfwDetector.scanAsset] for on-demand classification.
class NsfwPickMediaButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final MediaPickerType type;
  final bool multiple;
  final int? maxItems;
  final void Function(List<PickedMedia> media) onPicked;
  final NsfwTheme? theme;

  const NsfwPickMediaButton({
    super.key,
    required this.label,
    required this.onPicked,
    this.icon = Icons.collections_outlined,
    this.type = MediaPickerType.any,
    this.multiple = false,
    this.maxItems,
    this.theme,
  });

  @override
  State<NsfwPickMediaButton> createState() => _NsfwPickMediaButtonState();
}

class _NsfwPickMediaButtonState extends State<NsfwPickMediaButton> {
  bool _busy = false;

  Future<void> _go() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: widget.type,
        multiple: widget.multiple,
        maxItems: widget.maxItems,
      );
      widget.onPicked(picked);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Picker failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? NsfwTheme.defaults();
    return OutlinedButton.icon(
      onPressed: _busy ? null : _go,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(widget.icon),
      label: Text(widget.label),
      style: OutlinedButton.styleFrom(
        foregroundColor: t.onSurface,
        side: BorderSide(color: t.outline),
        padding: EdgeInsets.symmetric(
          horizontal: t.spacing.lg,
          vertical: t.spacing.md,
        ),
      ),
    );
  }
}
