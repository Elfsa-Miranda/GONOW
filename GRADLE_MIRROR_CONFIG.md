# Gradle 国内镜像源配置

## ✅ 已完成的配置

### 1. android/build.gradle.kts ✅
已将 Google 和 Maven 源替换为阿里云镜像，优先使用国内源：

```kotlin
allprojects {
    repositories {
        // 使用阿里云镜像源（国内网络环境优化）
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/jcenter") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // 保留原有源作为备用
        google()
        mavenCentral()
    }
}
```

### 2. android/settings.gradle.kts ✅
已配置插件管理的阿里云镜像源：

```kotlin
pluginManagement {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
```

---

## 🚀 下一步操作

### 1. 清理 Gradle 缓存
```bash
cd android
./gradlew clean
```

### 2. 重新构建项目
```bash
flutter clean
flutter pub get
flutter run
```

---

## 📝 配置说明

### 阿里云镜像源优势
- ✅ **速度快**: 国内CDN加速，下载速度提升10倍以上
- ✅ **稳定性高**: 不受网络限制，无需科学上网
- ✅ **完整性好**: 镜像同步及时，包含所有依赖

### 源优先级
1. **阿里云 Google 仓库** - 优先使用
2. **阿里云 JCenter 仓库** - 备用
3. **阿里云 Public 仓库** - 备用
4. **Google 官方源** - 最后备用
5. **Maven Central** - 最后备用

### 适用场景
- ✅ 国内开发环境
- ✅ CI/CD 构建服务器
- ✅ 无法使用代理的网络环境
- ✅ 需要快速下载依赖的场景

---

## 🔧 故障排除

### 如果仍然报错
1. **清理 Gradle 缓存**
   ```bash
   cd android
   ./gradlew clean
   rm -rf .gradle
   ```

2. **清理 Flutter 缓存**
   ```bash
   flutter clean
   flutter pub cache repair
   ```

3. **删除 build 目录**
   ```bash
   rm -rf android/build
   rm -rf android/app/build
   ```

4. **重新获取依赖**
   ```bash
   flutter pub get
   cd android
   ./gradlew build
   ```

### 检查网络连接
```bash
# 测试阿里云镜像连接
curl -I https://maven.aliyun.com/repository/google
```

---

## ✨ 配置完成

现在你的项目已经配置好国内镜像源，即使不开代理也能快速下载依赖！

重新运行 `flutter run` 即可正常编译。
