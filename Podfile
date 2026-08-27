source 'https://cdn.cocoapods.org/'
platform :ios, '15.0'

target :'AsyncDisplayKitTests' do
  platform :ios, '15.0'
  use_frameworks!
  pod 'OCMock', '~>3.9'
  pod 'iOSSnapshotTestCase/Core', '~> 8.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
