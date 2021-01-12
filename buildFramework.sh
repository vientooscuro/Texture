rm -rf ./build

xcodebuild archive \
    -scheme $1 \
    -archivePath "./build/ios.xcarchive" \
    -sdk iphoneos \
    SKIP_INSTALL=NO BUILD_LIBRARIES_FOR_DISTRIBUTION=YES BUILD_LIBRARY_FOR_DISTRIBUTION=YES

xcodebuild archive \
    -scheme $1 \
    -archivePath "./build/ios_sim.xcarchive" \
    -sdk iphonesimulator \
    SKIP_INSTALL=NO BUILD_LIBRARIES_FOR_DISTRIBUTION=YES BUILD_LIBRARY_FOR_DISTRIBUTION=YES

xcodebuild archive \
    -scheme $1 \
    -destination 'platform=macOS,arch=x86_64,variant=Mac Catalyst' \
    -archivePath "./build/macCatalyst.xcarchive" \
    SKIP_INSTALL=NO BUILD_LIBRARIES_FOR_DISTRIBUTION=YES BUILD_LIBRARY_FOR_DISTRIBUTION=YES SUPPORTS_MACCATALYST=YES

xcodebuild -create-xcframework \
    -framework "./build/ios.xcarchive/Products/Library/Frameworks/$1.framework" \
    -framework "./build/ios_sim.xcarchive/Products/Library/Frameworks/$1.framework" \
    -framework "./build/macCatalyst.xcarchive/Products/Library/Frameworks/$1.framework" \
    -output "./build/$1.xcframework"
