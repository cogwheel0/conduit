#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vad.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vad'
  s.version          = '0.0.6'
  s.summary          = 'VAD is a cross-platform Voice Activity Detection system'
  s.description      = <<-DESC
VAD is a cross-platform Voice Activity Detection system, allowing Flutter applications to seamlessly handle various VAD events using Silero VAD v4/v5 models.
                       DESC
  s.homepage         = 'https://keyur2maru.github.io/vad/'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Keyur Maru' => 'keyur2maru@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.dependency 'onnxruntime-objc', '1.22.0'
  s.platform = :ios, '15.1'
  s.static_framework = true

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end