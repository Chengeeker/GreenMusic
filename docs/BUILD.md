# 构建与检查

项目为Flutter Android客户端，Flutter和Dart版本要求见根目录的pubspec.yaml。Android构建使用JDK 17，SDK、NDK和Gradle版本由Flutter及android目录中的配置决定。

## 依赖

```shell
flutter pub get
```

packages/liquid_glass_widgets是随项目提供的本地依赖，需完整保留。vendor_reference/lilt为协议来源的参考快照，不参与Flutter构建。

## Android签名与APK

将android/key.properties.example复制为android/key.properties，填写自己的密钥文件位置、别名和口令。示例的storeFile相对于android目录；发布私钥和实际签名配置不随源码提供，也不应提交到仓库。

```shell
flutter build apk --release --target-platform android-arm64
```

应用包名为com.green.music，仅构建arm64-v8a。APK输出位于build/app/outputs/flutter-apk/app-release.apk。Flutter会按需生成本机SDK路径配置和Gradle wrapper文件。

## 自动检查

```shell
flutter analyze
flutter test --concurrency 2
```

测试缓存写入当前项目的.local目录。需要真实服务的测试按其显式开关启用；自动化检查不能替代QQ账号登录、真实音频、系统通知和目录授权的设备验收。

项目使用AGPL-3.0，第三方来源及许可见根目录THIRD_PARTY_NOTICES.md、LICENSE和相关依赖的许可文件。
