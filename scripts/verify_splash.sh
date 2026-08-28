#!/bin/bash

# 启动页配置验证脚本
# 用于检查启动页配置是否正确

echo "🔍 验证启动页配置..."
echo ""

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查计数
PASS=0
FAIL=0

# 1. 检查 pubspec.yaml 配置
echo "1️⃣  检查 pubspec.yaml 配置..."
if grep -q 'color: "#FFFFFF"' pubspec.yaml && grep -q 'image: assets/icon/logo_transparent.png' pubspec.yaml; then
    echo -e "${GREEN}✅ pubspec.yaml 配置正确${NC}"
    ((PASS++))
else
    echo -e "${RED}❌ pubspec.yaml 配置错误${NC}"
    echo "   应该包含："
    echo "   color: \"#FFFFFF\""
    echo "   image: assets/icon/logo_transparent.png"
    ((FAIL++))
fi
echo ""

# 2. 检查透明 Logo 文件
echo "2️⃣  检查透明 Logo 文件..."
if [ -f "assets/icon/logo_transparent.png" ]; then
    echo -e "${GREEN}✅ logo_transparent.png 文件存在${NC}"
    ((PASS++))
else
    echo -e "${RED}❌ logo_transparent.png 文件不存在${NC}"
    echo "   路径：assets/icon/logo_transparent.png"
    ((FAIL++))
fi
echo ""

# 3. 检查 Android 启动页资源
echo "3️⃣  检查 Android 启动页资源..."
if [ -f "android/app/src/main/res/drawable/splash.png" ]; then
    echo -e "${GREEN}✅ Android splash.png 已生成${NC}"
    ((PASS++))
else
    echo -e "${RED}❌ Android splash.png 未生成${NC}"
    echo "   请运行：dart run flutter_native_splash:create"
    ((FAIL++))
fi
echo ""

# 4. 检查 launch_background.xml
echo "4️⃣  检查 launch_background.xml..."
if [ -f "android/app/src/main/res/drawable/launch_background.xml" ]; then
    if grep -q '@drawable/splash' android/app/src/main/res/drawable/launch_background.xml; then
        echo -e "${GREEN}✅ launch_background.xml 配置正确${NC}"
        ((PASS++))
    else
        echo -e "${RED}❌ launch_background.xml 配置错误${NC}"
        ((FAIL++))
    fi
else
    echo -e "${RED}❌ launch_background.xml 不存在${NC}"
    ((FAIL++))
fi
echo ""

# 5. 检查 SplashScreen 组件
echo "5️⃣  检查 SplashScreen 组件..."
if [ -f "lib/features/splash/presentation/screens/splash_screen.dart" ]; then
    if grep -q 'backgroundColor: Colors.white' lib/features/splash/presentation/screens/splash_screen.dart; then
        echo -e "${GREEN}✅ SplashScreen 组件配置正确${NC}"
        ((PASS++))
    else
        echo -e "${YELLOW}⚠️  SplashScreen 背景色可能不正确${NC}"
        ((FAIL++))
    fi
else
    echo -e "${RED}❌ SplashScreen 组件不存在${NC}"
    ((FAIL++))
fi
echo ""

# 6. 检查 main.dart 配置
echo "6️⃣  检查 main.dart 启动流程..."
if grep -q 'SplashWrapper' lib/main.dart; then
    echo -e "${GREEN}✅ main.dart 使用了 SplashWrapper${NC}"
    ((PASS++))
else
    echo -e "${RED}❌ main.dart 未使用 SplashWrapper${NC}"
    echo "   home 应该设置为：const SplashWrapper()"
    ((FAIL++))
fi
echo ""

# 7. 检查资源声明
echo "7️⃣  检查资源声明..."
if grep -q 'assets/icon/logo_transparent.png' pubspec.yaml; then
    echo -e "${GREEN}✅ 资源已在 pubspec.yaml 中声明${NC}"
    ((PASS++))
else
    echo -e "${RED}❌ 资源未在 pubspec.yaml 中声明${NC}"
    ((FAIL++))
fi
echo ""

# 总结
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 验证结果："
echo -e "   ${GREEN}通过：$PASS${NC}"
echo -e "   ${RED}失败：$FAIL${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}🎉 所有检查通过！启动页配置正确。${NC}"
    echo ""
    echo "下一步："
    echo "  1. 运行：flutter clean"
    echo "  2. 运行：flutter pub get"
    echo "  3. 运行：flutter run"
else
    echo -e "${RED}⚠️  发现 $FAIL 个问题，请修复后重新验证。${NC}"
    echo ""
    echo "修复建议："
    echo "  1. 检查上述失败项"
    echo "  2. 参考 SPLASH_TROUBLESHOOTING.md"
    echo "  3. 运行：dart run flutter_native_splash:create"
fi
echo ""
