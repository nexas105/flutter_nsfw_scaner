/// Privacy-friendly, on-device NSFW detection for Flutter apps.
///
/// Import this library to access the headless scan APIs, configuration types,
/// result models, permission helpers, and ready-to-use widgets exposed by the
/// package.
library nsfw_detect;

export 'src/api/nsfw_detector.dart';
export 'src/api/nsfw_scan_controller.dart';
export 'src/api/nsfw_label.dart';
export 'src/api/media_item.dart';
export 'src/api/scan_result.dart';
export 'src/api/scan_result_extensions.dart';
export 'src/api/scan_progress.dart';
export 'src/api/scan_configuration.dart';
export 'src/api/scan_mode.dart';
export 'src/api/body_part_detection.dart';
export 'src/api/scan_session.dart';
export 'src/api/picked_media.dart';
export 'src/api/media_picker_type.dart';
export 'src/api/scan_summary.dart';
export 'src/api/model_descriptor.dart';
export 'src/api/model_download_progress.dart';
export 'src/api/nsfw_init_options.dart';
export 'src/api/nsfw_model_manager.dart';
export 'src/api/nsfw_gallery_filter.dart';
export 'src/api/camera_configuration.dart';
export 'src/api/camera_frame_result.dart';
export 'src/api/camera_scan_session.dart';
export 'src/api/camera_exceptions.dart';
export 'src/api/permissions/permission_kind.dart';
export 'src/platform/nsfw_platform_interface.dart'
    show PhotoLibraryPermissionStatus, NsfwUninitializedPlatform;
export 'src/widgets/nsfw_permissions_view.dart';
export 'src/widgets/nsfw_gallery_view.dart';
export 'src/widgets/nsfw_media_tile.dart';
export 'src/widgets/nsfw_result_badge.dart';
export 'src/widgets/nsfw_scan_progress_bar.dart';
export 'src/widgets/nsfw_scan_controls.dart';
export 'src/widgets/nsfw_skeleton_tile.dart';
export 'src/widgets/nsfw_summary_sheet.dart';
export 'src/widgets/nsfw_result_detail.dart';
export 'src/widgets/nsfw_settings_panel.dart';
export 'src/widgets/nsfw_detection_overlay.dart';
export 'src/widgets/nsfw_picker_button.dart';
export 'src/widgets/nsfw_filter_bar.dart';
export 'src/widgets/nsfw_search_field.dart';
export 'src/widgets/nsfw_selection_toolbar.dart';
export 'src/widgets/nsfw_camera_view.dart';
export 'src/widgets/nsfw_camera_hud.dart';
export 'src/widgets/nsfw_moderation_gate.dart';
export 'src/widgets/theme/nsfw_theme.dart';
export 'src/widgets/theme/nsfw_design_tokens.dart';
