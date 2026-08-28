@echo off
REM 启动页配置验证脚本（Windows 版本）
REM 用于检查启动页配置是否正确

echo 🔍 验证启动页配置...
echo.

set PASS=0
set FAIL=0

REM 1. 检查 pubspec.yaml 配置
echo 1️⃣  检查 pubspec.yaml 配置...
findstr /C:"color: \"#FFFFFF\"" pubspec.yaml >nul 2>&1
if %errorlevel% equ 0 (
    findstr /C:"image: assets/icon/logo_transparent.png" pubspec.yaml >nul 2>&1
    if %errorlevel% equ 0 (
        echo ✅ pubspec.yaml 配置正确
        set /a PASS+=1
    ) else (
        echo ❌ pubspec.yaml 配置错误
        set /a FAIL+=1
    )
) else (
    echo ❌ pubspec.yaml 配置错误
    echo    应该包含：
    echo    color: "#FFFFFF"
    echo    image: assets/icon/logo_transparent.png
    set /a FAIL+=1
)
echo.

REM 2. 检查透明 Logo 文件
echo 2️⃣  检查透明 Logo 文件...
if exist "assets\icon\logo_transparent.png" (
    echo ✅ logo_transparent.png 文件存在
    set /a PASS+=1
) else (
    echo ❌ logo_transparent.png 文件不存在
    echo    路径：assets\icon\logo_transparent.png
    set /a FAIL+=1
)
echo.

REM 3. 检查 Android 启动页资源
echo 3️⃣  检查 Android 启动页资源...
if exist "android\app\src\main\res\drawable\splash.png" (
    echo ✅ Android splash.png 已生成
    set /a PASS+=1
) else (
    echo ❌ Android splash.png 未生成
    echo    请运行：dart run flutter_native_splash:create
    set /a FAIL+=1
)
echo.

REM 4. 检查 launch_background.xml
echo 4️⃣  检查 launch_background.xml...
if exist "android\app\src\main\res\drawable\launch_background.xml" (
    findstr /C:"@drawable/splash" android\app\src\main\res\drawable\launch_background.xml >nul 2>&1
    if %errorlevel% equ 0 (
        echo ✅ launch_background.xml 配置正确
        set /a PASS+=1
    ) else (
        echo ❌ launch_background.xml 配置错误
        set /a FAIL+=1
    )
) else (
    echo ❌ launch_background.xml 不存在
    set /a FAIL+=1
)
echo.

REM 5. 检查 SplashScreen 组件
echo 5️⃣  检查 SplashScreen 组件...
if exist "lib\features\splash\presentation\screens\splash_screen.dart" (
    findstr /C:"backgroundColor: Colors.white" lib\features\splash\presentation\screens\splash_screen.dart >nul 2>&1
    if %errorlevel% equ 0 (
        echo ✅ SplashScreen 组件配置正确
        set /a PASS+=1
    ) else (
        echo ⚠️  SplashScreen 背景色可能不正确
        set /a FAIL+=1
    )
) else (
    echo ❌ SplashScreen 组件不存在
    set /a FAIL+=1
)
echo.

REM 6. 检查 main.dart 配置
echo 6️⃣  检查 main.dart 启动流程...
findstr /C:"SplashWrapper" lib\main.dart >nul 2>&1
if %errorlevel% equ 0 (
    echo ✅ main.dart 使用了 SplashWrapper
    set /a PASS+=1
) else (
    echo ❌ main.dart 未使用 SplashWrapper
    echo    home 应该设置为：const SplashWrapper()
    set /a FAIL+=1
)
echo.

REM 7. 检查资源声明
echo 7️⃣  检查资源声明...
findstr /C:"assets/icon/logo_transparent.png" pubspec.yaml >nul 2>&1
if %errorlevel% equ 0 (
    echo ✅ 资源已在 pubspec.yaml 中声明
    set /a PASS+=1
) else (
    echo ❌ 资源未在 pubspec.yaml 中声明
    set /a FAIL+=1
)
echo.

REM 总结
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo 📊 验证结果：
echo    通过：%PASS%
echo    失败：%FAIL%
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

if %FAIL% equ 0 (
    echo 🎉 所有检查通过！启动页配置正确。
    echo.
    echo 下一步：
    echo   1. 运行：flutter clean
    echo   2. 运行：flutter pub get
    echo   3. 运行：flutter run
) else (
    echo ⚠️  发现 %FAIL% 个问题，请修复后重新验证。
    echo.
    echo 修复建议：
    echo   1. 检查上述失败项
    echo   2. 参考 SPLASH_TROUBLESHOOTING.md
    echo   3. 运行：dart run flutter_native_splash:create
)
echo.
pause
