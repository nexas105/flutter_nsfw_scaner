/// Exception thrown when camera permission is denied.
class CameraPermissionDeniedException implements Exception {
  final String message;
  const CameraPermissionDeniedException([this.message = 'Camera permission denied']);
  @override
  String toString() => 'CameraPermissionDeniedException: $message';
}

/// Exception thrown when a camera error occurs.
class CameraErrorException implements Exception {
  final String message;
  const CameraErrorException(this.message);
  @override
  String toString() => 'CameraErrorException: $message';
}
