platform :ios, '26.0'

project 'QB.xcodeproj'

target 'QB' do
  use_frameworks!
  # VLC للملفات اللي ما يشغّلها مشغّل الآيفون (MKV وAVI وTS…)
  pod 'MobileVLCKit', '~> 3.7'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
      c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
