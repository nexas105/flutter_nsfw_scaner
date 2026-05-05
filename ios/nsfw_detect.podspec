Pod::Spec.new do |s|
  s.name             = 'nsfw_detect'
  s.version          = '1.2.8'
  s.summary          = 'On-device NSFW/nudity detection for iOS and Android.'
  s.description      = <<-DESC
    Flutter plugin for fast, accurate, on-device NSFW/nudity detection.
    Scans images and videos from the iOS photo library using CoreML + Vision.
    Streams results progressively. Body part detection included.
  DESC
  s.homepage         = 'https://pub.dev/packages/nsfw_detect'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'nsfw_detect' => 'pub.dev/packages/nsfw_detect' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'
  s.frameworks       = 'Photos', 'Vision', 'CoreML', 'AVFoundation', 'CoreVideo'
  s.library          = 'sqlite3'
  s.resources = ['Assets/**/*.mlmodelc']
end
