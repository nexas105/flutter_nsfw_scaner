/// Filter passed to [NsfwDetector.pickMedia]. Determines whether the native
/// picker shows images, videos, or both.
enum MediaPickerType {
  image('image'),
  video('video'),
  any('any');

  const MediaPickerType(this.wireValue);

  /// String value sent over the method channel to the native picker.
  final String wireValue;
}
