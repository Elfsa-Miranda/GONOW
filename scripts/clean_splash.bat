@echo off
REM 清理启动页脚本（Windows 版本）
REM 用于彻底删除旧的启动页资源和缓存

echo 🧹 开始清理旧的启动页资源...
echo.

REM 1. Flutter 清理
echo 📦 清理 Flutter 构建缓存...
call flutter clean
echo.

REM 2. 删除 Android 构建缓存
echo 🤖 清理 Android 构建缓存...
if exist android\build rmdir /s /q android\build
if exist android\app\build rmdir /s /q android\app\build
if exist android\.gradle rmdir /s /q android\.gradle
echo.

REM 3. 删除 iOS 构建缓存
echo 🍎 清理 iOS 构建缓存...
if exist ios\Pods rmdir /s /q ios\Pods
if exist ios\Podfile.lock del /q ios\Podfile.lock
if exist ios\build rmdir /s /q ios\build
echo.

REM 4. 重新生成启动页
echo 🎨 重新生成启动页...
call dart run flutter_native_splash:create
echo.

REM 5. 获取依赖
echo 📥 获取依赖...
call flutter pub get
echo.

echo ✅ 清理完成！现在可以运行 flutter run 来测试新的启动页。
echo.
echo 💡 提示：如果仍然看到旧的启动页，请手动卸载设备上的应用：
echo    Android: adb uninstall com.example.gonow
echo    然后重新运行: flutter run
echo.
pause
