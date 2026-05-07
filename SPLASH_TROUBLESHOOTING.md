# 启动页故障排除指南

## 问题：仍然看到旧的开屏动画

如果在更新后仍然看到旧的紫色背景或方块 Logo，请按照以下步骤排查：

---

## 🔍 诊断步骤

### 1. 确认配置文件已更新

检查 `pubspec.yaml` 中的配置：

```yaml
flutter_native_splash:
  color: "#FFFFFF"  # 应该是纯白色，不是 #893fdf
  image: assets/icon/logo_transparent.png  # 应该是透明 Logo
```

✅ **正确配置**：`color: "#FFFFFF"` + `image: assets/icon/logo_transparent.png`  
❌ **错误配置**：`color: "#893fdf"` + `image: assets/icon/icon.png`

---

### 2. 确认透明 Logo 文件存在

```bash
# 检查文件是否存在
ls assets/icon/logo_transparent.png
```

如果文件不存在，请确保：
- 文件路径正确
- 文件已提交到版本控制
- 文件格式为 PNG，且背景透明

---

### 3. 彻底清理构建缓存

**方法 A：使用清理脚本（推荐）**

Windows:
```bash
scripts\clean_splash.bat
```

macOS/Linux:
```bash
chmod +x scripts/clean_splash.sh
./scripts/clean_splash.sh
```

**方法 B：手动清理**

```bash
# 1. Flutter 清理
flutter clean

# 2. 删除 Android 构建缓存
rm -rf android/build
rm -rf android/app/build
rm -rf android/.gradle

# 3. 删除 iOS 构建缓存（如果有）
rm -rf ios/Pods
rm -rf ios/Podfile.lock
rm -rf ios/build

# 4. 重新生成启动页
dart run flutter_native_splash:create

# 5. 获取依赖
flutter pub get
```

---

### 4. 卸载设备上的应用

**重要：** 某些设备会缓存启动页资源，必须完全卸载应用才能清除缓存。

**Android:**
```bash
# 查看已安装的应用
adb shell pm list packages | grep gonow

# 卸载应用
adb uninstall com.example.gonow

# 重新安装
flutter run
```

**iOS:**
1. 在设备上长按应用图标
2. 点击"删除应用"
3. 重新运行 `flutter run`

---

### 5. 验证生成的资源文件

检查生成的启动页图片是否正确：

```bash
# 查看 Android 启动页图片
ls android/app/src/main/res/drawable*/splash.png
ls android/app/src/main/res/drawable*/android12splash.png

# 查看背景图片
ls android/app/src/main/res/drawable*/background.png
```

**验证方法：**
- 打开 `android/app/src/main/res/drawable/splash.png`
- 确认图片是透明背景的 Logo，不是方块

---

### 6. 检查 Android 配置文件

**launch_background.xml:**

```bash
cat android/app/src/main/res/drawable/launch_background.xml
```

应该包含：
```xml
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item>
        <bitmap android:gravity="fill" android:src="@drawable/background"/>
    </item>
    <item>
        <bitmap android:gravity="center" android:src="@drawable/splash"/>
    </item>
</layer-list>
```

**styles.xml:**

```bash
cat android/app/src/main/res/values/styles.xml
```

应该包含：
```xml
<item name="android:windowBackground">@drawable/launch_background</item>
```

---

## 🐛 常见问题

### 问题 1：运行 `flutter_native_splash:create` 失败

**错误信息：**
```
Error: Could not find image file: assets/icon/logo_transparent.png
```

**解决方法：**
1. 确认文件路径正确
2. 确认文件存在：`ls assets/icon/logo_transparent.png`
3. 确认 `pubspec.yaml` 中已声明资源：
   ```yaml
   assets:
     - assets/icon/logo_transparent.png
   ```

---

### 问题 2：启动页显示白屏，没有 Logo

**可能原因：**
- Logo 图片路径错误
- Logo 图片损坏
- 资源未正确打包

**解决方法：**
1. 检查 Logo 文件是否存在且完整
2. 重新运行 `dart run flutter_native_splash:create`
3. 清理缓存后重新构建

---

### 问题 3：Android 12+ 设备显示不同的启动页

**说明：**
Android 12+ 使用不同的启动页系统。

**检查配置：**
```yaml
flutter_native_splash:
  android_12:
    image: assets/icon/logo_transparent.png
    color: "#FFFFFF"
```

**验证文件：**
```bash
cat android/app/src/main/res/values-v31/styles.xml
```

---

### 问题 4：Flutter 启动页的导入语没有显示

**检查代码：**

1. 确认 `lib/features/splash/presentation/screens/splash_screen.dart` 存在
2. 确认 `lib/main.dart` 中使用了 `SplashWrapper`
3. 确认导航逻辑正确：

```dart
home: const SplashWrapper(),  // 不是 AuthGate()
```

---

### 问题 5：启动页过渡不流畅，有闪烁

**原因：**
原生启动页和 Flutter 启动页的背景色不一致。

**解决方法：**
确保两者使用完全相同的背景色：

**pubspec.yaml:**
```yaml
flutter_native_splash:
  color: "#FFFFFF"
```

**splash_screen.dart:**
```dart
backgroundColor: Colors.white,  // 必须是纯白色
```

---

## ✅ 验证清单

完成以下所有步骤后，启动页应该正常显示：

- [ ] `pubspec.yaml` 配置正确（纯白背景 + 透明 Logo）
- [ ] `logo_transparent.png` 文件存在且背景透明
- [ ] 运行了 `dart run flutter_native_splash:create`
- [ ] 运行了 `flutter clean`
- [ ] 删除了 Android/iOS 构建缓存
- [ ] 卸载了设备上的旧应用
- [ ] 重新运行了 `flutter run`
- [ ] 启动页显示纯白背景 + 透明 Logo
- [ ] Flutter 启动页显示导入语
- [ ] 过渡流畅无闪烁

---

## 🆘 仍然无法解决？

如果完成以上所有步骤后仍然有问题，请提供以下信息：

1. **设备信息：**
   - 操作系统：Android / iOS
   - 系统版本：
   - 设备型号：

2. **配置文件：**
   ```bash
   cat pubspec.yaml | grep -A 10 "flutter_native_splash"
   ```

3. **生成的资源：**
   ```bash
   ls -la android/app/src/main/res/drawable*/splash.png
   ```

4. **错误日志：**
   ```bash
   flutter run --verbose
   ```

5. **截图：**
   - 当前启动页的截图
   - 期望的启动页效果图

---

## 📚 相关文档

- [SPLASH_SCREEN_UPDATE.md](./SPLASH_SCREEN_UPDATE.md) - 启动页更新说明
- [flutter_native_splash 官方文档](https://pub.dev/packages/flutter_native_splash)
- [Android 启动页指南](https://developer.android.com/guide/topics/ui/splash-screen)
- [iOS 启动页指南](https://developer.apple.com/design/human-interface-guidelines/launch-screen)
