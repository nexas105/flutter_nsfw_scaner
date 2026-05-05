import 'package:flutter/material.dart';

import '../api/nsfw_detector.dart';
import '../api/permissions/permission_kind.dart';
import 'theme/nsfw_theme.dart';

typedef PermissionLabelBuilder = String Function(
  PermissionKind kind,
  PermissionStatus status,
  BuildContext context,
);

typedef PermissionChangedCallback = void Function(
  PermissionKind kind,
  PermissionStatus status,
);

/// Reusable widget that surfaces every permission [NsfwDetector] needs and
/// lets the user re-request the ones that are missing.
///
/// Polls live status via [NsfwDetector.checkPermission] and
/// [NsfwDetector.checkCameraPermission]. If the camera-permission native
/// handler isn't wired yet (pre–Phase-2 / pre–Phase-3), the camera row
/// renders as [PermissionStatus.notDetermined] and the Request button is a
/// no-op until the handler lands.
///
/// The widget is dependency-free — it does NOT pull in `permission_handler`
/// or `app_settings`. The "Open Settings" deep-link is delegated to the host
/// app via [onOpenSettings].
class NsfwPermissionsView extends StatefulWidget {
  /// Which permissions to render. Defaults to both photo library and camera.
  final List<PermissionKind> kinds;

  /// Theme. Falls back to [NsfwTheme.defaults] when null.
  final NsfwTheme? theme;

  /// Optional override of the row title — receives the kind, current status,
  /// and `BuildContext` so callers can localise.
  final PermissionLabelBuilder? labelBuilder;

  /// Fires whenever a row's status changes (initial poll AND after request).
  final PermissionChangedCallback? onPermissionChanged;

  /// Tapped when a row is in [PermissionStatus.permanentlyDenied] or
  /// [PermissionStatus.restricted]. The plugin does NOT add a deep-link
  /// dependency — the host app wires `app_settings` (or equivalent) here.
  /// When null, the Settings button is hidden.
  final VoidCallback? onOpenSettings;

  /// Re-poll status when the app returns from the system Settings UI.
  final bool refreshOnAppResume;

  /// Optional injection point for tests. When null, [NsfwDetector.instance]
  /// is used.
  final NsfwDetector? detector;

  const NsfwPermissionsView({
    super.key,
    this.kinds = const [PermissionKind.photoLibrary, PermissionKind.camera],
    this.theme,
    this.labelBuilder,
    this.onPermissionChanged,
    this.onOpenSettings,
    this.refreshOnAppResume = true,
    this.detector,
  });

  @override
  State<NsfwPermissionsView> createState() => _NsfwPermissionsViewState();
}

class _NsfwPermissionsViewState extends State<NsfwPermissionsView>
    with WidgetsBindingObserver {
  final Map<PermissionKind, PermissionStatus> _statuses = {};
  final Set<PermissionKind> _busy = {};

  NsfwDetector get _detector => widget.detector ?? NsfwDetector.instance;

  @override
  void initState() {
    super.initState();
    if (widget.refreshOnAppResume) {
      WidgetsBinding.instance.addObserver(this);
    }
    for (final kind in widget.kinds) {
      _statuses[kind] = PermissionStatus.notDetermined;
    }
    _refreshAll();
  }

  @override
  void dispose() {
    if (widget.refreshOnAppResume) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.refreshOnAppResume) {
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    for (final kind in widget.kinds) {
      await _refresh(kind);
    }
  }

  Future<void> _refresh(PermissionKind kind) async {
    final status = await _query(kind);
    if (!mounted) return;
    final prev = _statuses[kind];
    setState(() => _statuses[kind] = status);
    if (prev != status) {
      widget.onPermissionChanged?.call(kind, status);
    }
  }

  Future<PermissionStatus> _query(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.photoLibrary:
        final raw = await _detector.checkPermission();
        return raw.toPermissionStatus();
      case PermissionKind.camera:
        return _detector.checkCameraPermission();
    }
  }

  Future<PermissionStatus> _request(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.photoLibrary:
        final raw = await _detector.requestPermission();
        return raw.toPermissionStatus();
      case PermissionKind.camera:
        return _detector.requestCameraPermission();
    }
  }

  Future<void> _onRequestTap(PermissionKind kind) async {
    if (_busy.contains(kind)) return;
    setState(() => _busy.add(kind));
    try {
      final status = await _request(kind);
      if (!mounted) return;
      final prev = _statuses[kind];
      setState(() => _statuses[kind] = status);
      if (prev != status) {
        widget.onPermissionChanged?.call(kind, status);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(kind));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme ?? NsfwTheme.defaults();
    return Container(
      decoration: BoxDecoration(
        color: theme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.outline),
      ),
      padding: EdgeInsets.symmetric(
        vertical: theme.spacing.sm,
        horizontal: theme.spacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.kinds.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: theme.outline,
              ),
            _buildRow(widget.kinds[i], theme),
          ],
        ],
      ),
    );
  }

  Widget _buildRow(PermissionKind kind, NsfwTheme theme) {
    final status = _statuses[kind] ?? PermissionStatus.notDetermined;
    final busy = _busy.contains(kind);
    final title = widget.labelBuilder?.call(kind, status, context) ??
        kind.defaultLabel;

    return Semantics(
      label: '$title: ${_statusLabel(status)}',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: theme.spacing.sm),
        child: Row(
          children: [
            Icon(
              _iconFor(kind),
              color: theme.onSurfaceMuted,
              size: 24,
            ),
            SizedBox(width: theme.spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: theme.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _statusLabel(status),
                    style: TextStyle(
                      color: _statusColor(status, theme),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: theme.spacing.sm),
            _buildTrailing(kind, status, theme, busy: busy),
          ],
        ),
      ),
    );
  }

  Widget _buildTrailing(
    PermissionKind kind,
    PermissionStatus status,
    NsfwTheme theme, {
    required bool busy,
  }) {
    if (busy) {
      return SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(theme.accent),
        ),
      );
    }
    if (status.isGranted) {
      return Tooltip(
        message: 'Granted',
        child: Icon(Icons.check_circle, color: theme.success, size: 22),
      );
    }
    if (status.canRequest) {
      return TextButton(
        onPressed: () => _onRequestTap(kind),
        style: TextButton.styleFrom(foregroundColor: theme.accent),
        child: const Text('Request'),
      );
    }
    if (status.needsSettings && widget.onOpenSettings != null) {
      return TextButton(
        onPressed: widget.onOpenSettings,
        style: TextButton.styleFrom(foregroundColor: theme.danger),
        child: const Text('Open Settings'),
      );
    }
    // permanentlyDenied / restricted with no onOpenSettings → no button.
    return const SizedBox.shrink();
  }

  IconData _iconFor(PermissionKind kind) => switch (kind) {
        PermissionKind.photoLibrary => Icons.photo_library_outlined,
        PermissionKind.camera => Icons.photo_camera_outlined,
      };
}

String _statusLabel(PermissionStatus s) => switch (s) {
      PermissionStatus.authorized => 'Authorized',
      PermissionStatus.limited => 'Limited access',
      PermissionStatus.denied => 'Denied',
      PermissionStatus.permanentlyDenied => 'Permanently denied',
      PermissionStatus.restricted => 'Restricted',
      PermissionStatus.notDetermined => 'Not determined',
    };

Color _statusColor(PermissionStatus s, NsfwTheme t) => switch (s) {
      PermissionStatus.authorized || PermissionStatus.limited => t.success,
      PermissionStatus.denied || PermissionStatus.notDetermined => t.accent,
      PermissionStatus.permanentlyDenied || PermissionStatus.restricted =>
        t.danger,
    };
