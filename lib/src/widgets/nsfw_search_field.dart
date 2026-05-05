import 'dart:async';
import 'package:flutter/material.dart';
import 'theme/nsfw_theme.dart';

/// A debounced text input. Emits trimmed lower-case query strings via
/// [onChanged] after the user pauses typing for [debounce]. Designed for
/// inline use in the gallery — but generic enough to drop anywhere.
class NsfwSearchField extends StatefulWidget {
  final String? initialValue;
  final String hintText;
  final Duration debounce;
  final ValueChanged<String> onChanged;
  final NsfwTheme? theme;
  final EdgeInsets padding;

  const NsfwSearchField({
    super.key,
    this.initialValue,
    this.hintText = 'Search…',
    this.debounce = const Duration(milliseconds: 200),
    required this.onChanged,
    this.theme,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  @override
  State<NsfwSearchField> createState() => _NsfwSearchFieldState();
}

class _NsfwSearchFieldState extends State<NsfwSearchField> {
  late final TextEditingController _controller;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, () {
      widget.onChanged(raw.trim().toLowerCase());
    });
  }

  void _clear() {
    _controller.clear();
    _debounceTimer?.cancel();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? NsfwTheme.defaults();
    return Padding(
      padding: widget.padding,
      child: TextField(
        controller: _controller,
        onChanged: _onChanged,
        style: t.typography.body.copyWith(color: t.onSurface),
        cursorColor: t.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.hintText,
          hintStyle: t.typography.body.copyWith(color: t.onSurfaceMuted),
          prefixIcon: Icon(Icons.search_rounded,
              size: 18, color: t.onSurfaceMuted),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  splashRadius: 16,
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: t.onSurfaceMuted),
                  onPressed: _clear,
                ),
          filled: true,
          fillColor: t.surface,
          contentPadding: EdgeInsets.symmetric(
            horizontal: t.spacing.md,
            vertical: t.spacing.sm,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: t.outline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: t.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: t.accent, width: 1.2),
          ),
        ),
      ),
    );
  }
}
