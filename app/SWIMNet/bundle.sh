#!/bin/sh

rm -rf archives || true
rm -rf xcframeworks || true

# Destination iOS
xcodebuild archive \
    -project SWIMNet.xcodeproj \
    -scheme SWIMNet \
    -destination "generic/platform=iOS" \
    -archivePath "archives/SWIMNet-iOS"

# Destination iOS Simulator
xcodebuild archive \
    -project SWIMNet.xcodeproj \
    -scheme SWIMNet \
    -destination "generic/platform=iOS Simulator" \
    -archivePath "archives/SWIMNet-iOS_Simulator"

# Bundle it all up
xcodebuild -create-xcframework -archive archives/SWIMNet-iOS.xcarchive -framework SWIMNet.framework -archive archives/SWIMNet-iOS_Simulator.xcarchive -framework SWIMNet.framework -output xcframeworks/SWIMNet.xcframework

