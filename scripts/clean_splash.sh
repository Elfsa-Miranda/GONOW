#!/bin/bash

# 清理启动页脚本
# 用于彻底删除旧的启动页资源和缓存

echo "🧹 开始清理旧的启动页资源..."

# 1. Flutter 清理
echo "📦 清理 Flutter 构建缓存..."
flutter clean

# 2. 删除 Android 构建缓存
echo "🤖 清理 Android 构建缓存..."
rm -rf android/build
rm -rf android/app/build
rm -rf android/.gradle

# 3. 删除 iOS 构建缓存
echo "🍎 清理 iOS 构建缓存..."
rm -rf ios/Pods
rm -rf ios/Podfile.lock
rm -rf ios/build

# 4. 重新生成启动页
echo "🎨 重新生成启动页..."
dart run flutter_native_splash:create

# 5. 获取依赖
echo "📥 获取依赖..."
flutter pub get

# 6. iOS Pod 安装（如果在 macOS 上）
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "🍎 安装 iOS Pods..."
    cd ios
    pod install
    cd ..
fi

echo "✅ 清理完成！现在可以运行 flutter run 来测试新的启动页。"
echo ""
echo "💡 提示：如果仍然看到旧的启动页，请手动卸载设备上的应用："
echo "   Android: adb uninstall com.example.gonow"
echo "   iOS: 在设备上长按应用图标并删除"
