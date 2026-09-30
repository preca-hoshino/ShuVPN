#
# Standalone pod exposing the Flutter-free SangforTunnelCore module, for
# consumer packet tunnel extension (.appex) targets that integrate via
# CocoaPods while the Runner uses the regular flutter_sangfor plugin pod.
#
Pod::Spec.new do |s|
  s.name             = 'SangforTunnelCore'
  s.version          = '0.0.1'
  s.summary          = 'Flutter-free NetworkExtension core for flutter_sangfor'
  s.description      = <<-DESC
Packet tunnel provider runtime and NETunnelProviderManager lifecycle shared
between the flutter_sangfor Flutter plugin and consumer app extensions.
                       DESC
  s.homepage         = 'https://github.com/TsinbeiLabs/flutter_sangfor'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'TsinbeiLabs' => 'https://github.com/TsinbeiLabs' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_sangfor/Sources/SangforTunnelCore/**/*'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
