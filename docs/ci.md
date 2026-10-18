# 用 GitHub Actions 出 .ipa

## 它做什么

推送、打 tag、或者手动点一次 Run workflow，GitHub 就会在 macOS 机器上：

1. 跑 `MizarKit` 的协议测试（`swift test`，不需要模拟器，几秒）
2. 用 Release 配置编一遍 App（`xcodebuild archive`），确认它能编出来
3. 打包成 `.ipa`，连同 dSYMs 挂到这次运行的 Artifacts 里

workflow 是 `.github/workflows/ios.yml`，真正的命令都在 `scripts/ci.sh` ——
本地想复现一次失败的 CI，跑同一条命令即可：

```sh
scripts/ci.sh protocol    # = swift test
scripts/ci.sh app         # = 模拟器上编一遍
scripts/ci.sh ipa         # = archive + 打包，产物在 release/ci/
```

## 产物在哪

一次成功的 **IPA** job，页面底部的 **Artifacts** 里有：

| 文件 | 是什么 |
|---|---|
| `DSH-Mizar-<版本>.ipa` | 安装包，签名与否则看这次有没有配密钥 |
| `DSH-Mizar-<版本>.dSYMs.zip` | 崩溃日志符号化用 |

构建号默认取 UTC 时间戳（`20261018.2216`），这样同一版本号可以反复出包而不会在
App Store Connect 上撞号；想固定就手动填 `build_number`。

## 不配任何密钥：能出包，但装不上

**这是重点。** 没有签名密钥时流水线照样跑完、照样产出 `.ipa`，但它是**未签名**的：
iOS 会直接拒绝安装，因为它既没有证书也没有描述文件。

未签名包仍然有用：它是这一版真实的 Release 产物，可以自己拿 Xcode / Sideloadly
重签后装到设备上；也可以当作 Release 编译是否通过的一道闸。

## 配了密钥：签名包，可选直传 TestFlight

在仓库的 **Settings → Secrets and variables → Actions** 里加这六个 secret：

| Secret | 内容 |
|---|---|
| `APPLE_CERTIFICATE_P12` | 发行证书 `.p12` 的 base64（见下） |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设的密码 |
| `APPLE_TEAM_ID` | 团队 ID，如 `5Q2A46685M` |
| `APPSTORE_API_KEY_ID` | App Store Connect API Key 的 Key ID |
| `APPSTORE_API_ISSUER_ID` | 同一把 Key 的 Issuer ID |
| `APPSTORE_API_PRIVATE_KEY` | `AuthKey_XXXX.p8` 的**全文** |

六个齐了才按签名走；缺任意一个就退回到未签名的产物，不会半途失败。

证书转 base64：

```sh
base64 -i Certificates.p12 | pbcopy        # macOS，直接粘进 secret
base64 -i Certificates.p12 > cert.b64      # 或者写文件再看
```

API Key 在 https://appstoreconnect.apple.com/access/integrations/api 生成，
权限选 **App Manager** 即可（要上传的话不能更低）。

配好之后：

- **随便一次推送 / 打 tag** → 出**签名** `.ipa`（默认 `app-store-connect` 方式）
- **手动 Run workflow** → 可以选 `export_method`（`app-store-connect` /
  `release-testing` / `debugging` / `ad-hoc`），也可以勾 `upload_to_testflight`
  直接传上去，`docs/testflight.md` 里第 3 步那些网页操作就可以省掉

> `.ipa` 的安装仍然受描述文件限制：`app-store-connect` / `ad-hoc` 的包只能装到
> 描述文件里登记过的设备上。想装到自己手机上，最省事的是 `ad-hoc` 并先在
> developer.apple.com 把你的设备 UDID 加进去。

## 在 fork 上跑

这个仓库是上游的 fork。fork 默认**不能**用上游的 App ID 签名 —— `me.shirazu.dshmizar`
属于另一个团队，你的证书签不了它。两个办法：

1. **不配密钥**，只拿未签名包（最常见）；
2. 配好自己的六个 secret，再加一条仓库变量 `BUNDLE_ID`（Settings → Secrets and
   variables → Actions → **Variables**），例如 `com.yourname.dshmizar`。
   `scripts/ci.sh` 会在**工作区副本里**改写 `project.pbxproj`，仓库本身不动；
   LiveActivity 扩展会自动跟着变成 `com.yourname.dshmizar.LiveActivity`，扩展前缀
   必须等于宿主 App，这条不能省。

另外 fork 的 Actions 默认是关的，需要到 **Actions** 标签页点一次 **I understand my
workflows, go ahead and enable them**。

## 触发条件一览

| 事件 | 跑什么 |
|---|---|
| push 到 `main` / 打 `v*` tag | 测试 + 模拟器编译 → **出 .ipa** |
| Pull Request | 测试 + 模拟器编译（不出包，也不碰密钥） |
| 手动 Run workflow | 同上，另可选装 UI 测试、选导出方式、传 TestFlight |

UI 测试（`AppFlowTests`，约 6 分钟）默认不跑，手动勾 `run_ui_tests` 才跑：
它要起两个假主机（`node scripts/mock-host.mjs 19395` 和 `19396`），两个端口缺一不可 ——
少一个，跨电脑切换的那几个用例会去连一个不存在的服务。

## 已知边界

- runner 用 `macos-26`（Apple Silicon）。Xcode 镜像自带 26.x；工程要求 Xcode 26+、
  `IPHONEOS_DEPLOYMENT_TARGET = 26.0`。要换版本就在 Run workflow 里填 `xcode_version`。
- 打包耗时约 10–20 分钟（含排队）；UI 测试另算，单独一个 job。
- 公开仓库走 GitHub 免费的 Actions 额度，但 macOS 的分钟数按 10 倍折算，
  所以 UI 测试不要挂在每次 push 上。
