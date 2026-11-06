# 构建 GreenMusic

正式工程在 `compose/`。用 Android Studio 打开该目录，或在仓库根运行下列命令。需要 JDK 17、Android SDK 36 和 Build Tools 37。

```powershell
.\compose\gradlew.bat -p compose :app:testReleaseUnitTest :app:lintRelease :app:assembleRelease --console=plain
```

仅构建 arm64-v8a。没有签名配置时，Release 输出 `compose/app/build/outputs/apk/release/app-release-unsigned.apk`，可用于检查构建产物。

正式发布使用原发布签名。签名配置位于本机忽略目录 `.local/signing/key.properties`，配置键为 `storeFile`、`storeType`、`storePassword`、`keyAlias` 和 `keyPassword`，密钥相对同一目录解析。签名输出为 `compose/app/build/outputs/apk/release/app-release.apk`。核验签名、版本、ABI 和 16 KB 对齐后，交付仓库根目录的 `GreenMusic_v1.2.13_arm64.apk`。
