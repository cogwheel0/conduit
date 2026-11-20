#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_callkit_incoming.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_callkit_incoming'
  s.version          = '3.1.6'
  s.summary          = 'Flutter Callkit Incoming'
  s.description      = <<-DESC
Flutter Callkit Incoming
                       DESC
  s.homepage         = 'https://github.com/hiennguyen92/flutter_callkit_incoming'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Hien Nguyen' => 'hien@hiennv.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_callkit_incoming/Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'CryptoSwift'
  s.platform = :ios, '15.0'

  s.resource_bundles = { 'flutter_callkit_incoming_privacy' => ['flutter_callkit_incoming/Classes/PrivacyInfo.xcprivacy'] }

  # Flutter.framework does not contain an i386 slice. VALID_ARCHS is deprecated and,
  # pinned to x86_64, excluded arm64 simulators on Apple Silicon.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
