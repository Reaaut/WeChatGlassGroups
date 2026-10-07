# WeChatGlassGroups

给 iOS 16.1.1 / iPhone 14 Pro / 微信 8.0.78 写的会话分组插件（Theos Tweak，纯 UIKit）。

**先说三句最重要的，避免你白折腾：**

1. **这份代码我这边没有编译过，也没有在真机上跑过。** 我手上只有 Windows，没有 macOS、没有 Theos、没有 iOS SDK，连 `clang` 都没有。所以它属于"结构完整、待你上机编译调试"的骨架，不是"编译即用"的成品。
2. **阶段一必须先跑，先拿日志。** 设计稿里的 `MMConversationListViewController` / `conversationArray` / `MMTableView` 这些名字是**传闻值**，在 8.0.78 上大概率对不上。Tweak 里 hook 一个不存在的类**不会报任何错**，就是静默失效——你会以为"代码有问题"，其实只是名字错了。所以我先做了一套运行时探测，让它自己在你手机上把真名打出来。
3. **改微信有封号风险。** 这违反微信用户协议，腾讯有反作弊和特征检测。用小号试，别拿主号。以下内容仅供你在自己设备上做技术学习。

---

## 零、效果图 → 代码：尺寸对照表

面板尺寸是**从效果图反推的**（图是 1179×2556，即 iPhone 14 Pro @3x，除以 3 得 pt）。
所有数值在 [GlassGroupPanel.m](GlassGroupPanel.m) 顶部集中定义，改一个地方就够。

| 效果图元素 | 图上像素 | 换算 pt | 代码常量 |
|---|---|---|---|
| 左右留白 | 60px | 20 | `kSidePadding` |
| 左侧大图宽 | 535px | 178 | `kHeroWidth` |
| 大图 / 卡片圆角 | 60px | 20 | `kHeroRadius` |
| 大图与卡片间距 | 35px | 12 | `kHeroGap` |
| 卡片内圆形头像 | 150px | 52 | `kAvatarSize` |
| 分组胶囊高 | 215px | ~72 | `kPillHeight` |
| 胶囊间距 | 30px | 10 | `kPillSpacing` |
| 卡片底 → XXX | 72px | 24 | `kDividerGapTop` |
| XXX → 第一个胶囊 | 48px | 16 | `kDividerGapBot` |

**三个容易做错、我按效果图纠正了的地方：**

1. **箭头在左，文字紧随其后，右边一大片留白。** 常规做法是"文字在左、箭头推到最右"，效果图是反的。已按图实现（`chevron.leadingAnchor` + 文字 `kPillTextLeft`）。
2. **胶囊是完全圆角**（`height/2`），不是小圆角卡片。
3. **那一行 `/` 用的是衬线斜体**，不是系统常规字重；`0920` 同理。已用 `TimesNewRomanPS-ItalicMT` + 系统字体兜底。

### ⚠️ 效果图和你最初设计稿有一处冲突，我没动

| | 你的设计稿 | 效果图 |
|---|---|---|
| 底部 Tab 栏 | **保留**微信原生 Tab 栏（聊天/通讯录/发现/我） | **完全替换**成三个独立玻璃胶囊 + 搜索框 |

这两件事互斥，而且难度差一个量级。改 Tab 栏要 hook `UITabBarController`、在它内部插自定义 view、还要处理它自己的 layout 和切换动画，属于另一个量级的改动。

**所以现在代码里还是保留原生 Tab 栏。** 你要哪种，告诉我：

- **A（推荐，安全）**：只做会话列表上方的分组面板，底部保持微信原样。
- **B（效果图 1:1）**：连底部 Tab 栏一起换。工作量大、崩溃面也大得多，建议 A 稳定后再做。

同样，效果图里那条**搜索框**我单独写成了 `WGGSearchBar` 类，但**没有注入微信**——因为它在效果图里是跟着内容滚动的，而微信原生搜索框的实现各版本差异很大。我另给了一个低风险的替代方案：`WGG_RESTYLE_SEARCHBAR=1` 编译开关，直接把微信**原生**搜索框改成圆角玻璃胶囊，视觉接近且几乎不可能崩。默认关闭，等阶段一看完 view 层级再开。

---

## 一、原始设计里我改掉的 7 个地方

按重要性排序，前两个是"照原方案写必崩"的级别。

### 1. ⚠️ 不能只 hook `conversationArray` 的 getter

原设计："拦截 getter，返回过滤后的数组给原生 TableView。"

问题：`UITableView` 的行数**不一定**来自这个 getter。如果微信自己的 `-tableView:numberOfRowsInSection:` 读的是内部缓存（比如 `m_arrConversation`），而你只改了 getter，就会出现：

```
你的过滤数组 count = 3   →  你希望显示 3 行
微信说 numberOfRows     = 25  →  实际要 25 行
第 4 行取 cell 时 → 数组越界 → 崩溃
```

**正确做法是"成对拦截"**：`numberOfRowsInSection:` 返回过滤后数量，`cellForRowAtIndexPath:` 把行号用映射表翻译回原始行号，两者共用同一份 `WGGFilterResult`。

代码里已经把这套写好了（`GroupStore.h` 的 `WGGFilterResult` 保存 `filtered` + `indices` 映射），但它默认**关着**，必须先在真机上确认"到底是谁在给首页 table 供数"，再打开。

### 2. ⚠️ 面板不能直接 addSubview 到 `self.view` 就完事

原设计："addSubview 到 self.view，给下方 TableView 设 contentInset。"

两个坑：

- 微信首页的 `self.view` 很可能**整个就是那张 table**（或者 table 是唯一子视图）。你把面板叠上去，随便一次下拉刷新、切 tab、reloadData，微信都可能重新布局把你盖掉或挤走。
- `contentInset` **不能硬编码数字**。面板高度会随图片加载、系统字号（你手机如果开了大字号）、深色模式变化，写死 220 之类的值，在大字号下就会被遮挡。

代码里的做法：面板作为 `vc.view` 的**独立子视图**用 Auto Layout 钉在 `safeAreaLayoutGuide.top`（这样自动避开灵动岛和状态栏），inset 每次先**减掉上一次自己加的量**再加新值，避免反复叠加把列表越推越低。

### 3. `NSUserDefaults` 的域不对

`GlassGroupPanel` 写的是 `[NSUserDefaults standardUserDefaults]`。这个域是**微信自己的沙盒**（`com.tencent.xin`），不是插件的域。

好处：跟着微信沙盒走，卸载微信配置一起没，多个插件也不会互相踩。
坏处：微信自己如果也用了同名的 key 会冲突——所以所有 key 都加了 `WGG.` 前缀。

原设计想做的"设置页"，正确做法是**另开一个 PreferenceBundle target**（Theos 的 `preference_bundle` 模板），用 `PreferenceLoader` 注册入口。Tweak 和设置页通过 `NSUserDefaults` 的同一个域通信。这部分我没写，属于第二阶段。

### 4. arm64e + iOS 16.1.1 基本等于 **rootless（无根）越狱**

原设计的 Makefile 只写了 `ARCHS = arm64e` 和 `TARGET`，缺了最关键的一行：

```make
export THEOS_PACKAGE_SCHEME = rootless
```

iOS 15 之后主流的越狱（Dopamine、palera1n 的 rootless 模式等）都是无根的，插件不能装到 `/Library/MobileSubstrate/DynamicLibraries/`，必须装到 `/var/jb/Library/MobileSubstrate/DynamicLibraries/`。**如果你用了有根越狱（比如 Taurine 的老版本），把这行注释掉。**

⚠️ 这里有个你可能记错的地方：**Taurine 是 iOS 14 的越狱工具**，16.1.1 上最常见的是 **Dopamine**（无根）。原设计第六节说"你的 16.1.1 一般是 Taurine 越狱"，这条要按你手机实际情况确认——这直接决定 Makefile 和插件安装路径。

### 5. 关于"SwiftUI 注入会渲染崩溃"这条

结论对（确实别用 SwiftUI），但原因说法不准。真实原因是：**Tweak 项目默认不编译 Swift**，dylib 里不会链接 `libswiftCore.dylib`；一旦运行时真的走到 Swift 代码，就会因为找不到 Swift 运行时符号而崩，而且崩在加载阶段，看起来就像"注入了就崩"。

如果你的 Theos 工程正确配置了 Swift（`SWIFT_LIBRARIES`、`-lswiftCore` 等），SwiftUI 是能跑的。所以结论保持"用 UIKit"，但别再把它当成"SwiftUI 本身在微信里不能用"。

### 6. 类名要实测，别信传闻

- `MMConversation` 这个类**大概率不存在**，微信的会话模型类名跟版本强相关。
- `MMTableView` 这种"微信专用 UITableView 子类"也不一定有，`WGGFindMainTableView` 里我是按**面积最大的 `UITableView`** 找的，不依赖类名。

所以 `Discovery.m` 里干的事就是：把所有类名里带 `Conversation` / `Session` / `MainFrame` 的都列出来，再逐个验证设计稿假设的那些名字存不存在。

### 7. 版本门禁用 Info.plist，不用类名

原设计说"control 里增加版本校验"。`control` 文件是 dpkg 元数据，**运行时校验不了任何东西**（`Depends` 只能写包依赖）。

正确做法是代码里读 `CFBundleShortVersionString`（已实现，`WGGVersionSupported()`），或者用 Theos 的 `%init` + 运行时判断。顺便：微信的 Bundle ID 在部分版本/地区是 `com.tencent.xinWeChat`，filter plist 里我两个都写了。

---

## 二、文件结构

```
WeChatGlassGroups/
├── Makefile                  Theos 构建配置（rootless + arm64e + 阶段开关）
├── control                   deb 元数据
├── WeChatGlassGroups.plist   MobileSubstrate 注入过滤（只注入微信）
├── Tweak.x                   Logos 钩子：找首页 / 挂面板 / 撑 inset / 数据源过滤
├── GlassGroupPanel.h/.m      玻璃面板 UI（纯 UIKit，不依赖微信任何类）
├── GroupStore.h/.m           分组持久化 + 过滤 + 下标映射
├── Discovery.h/.m            运行时逆向探测（阶段一的核心）
├── .github/workflows/build.yml  GitHub Actions：用 macOS runner 编译出 deb
├── .gitattributes            强制 LF —— Windows 编辑 / macOS 编译必须加这个
└── README.md                 本文件
```

`GlassGroupPanel` 和 `GroupStore` **完全不引用微信的类**，所以你可以先把它们塞进一个普通 iOS App 里跑，确认 UI 长对了、按钮点得动，再去和微信对接。这是省时间的关键——别一上来就在真机微信里调 UI。

---

## 三、阶段一：先拿日志（必做）

### 0. 你只有 Windows —— 所以不要在本地装工具链

**推荐路线：用 GitHub Actions 的 macOS runner 编译。** 我已经配好了 [.github/workflows/build.yml](.github/workflows/build.yml)。

理由：编译 iOS Tweak 必须有 Apple 的 SDK 和 `ldid` 签名，这套东西官方只支持 macOS。在 Windows/WSL 里硬凑要么缺私有框架的 `.tbd`，要么签名链断，排错的时间远超收益。而 GitHub 免费给 macOS runner，编译完直接给你 `.deb` 下载。

用法：

```bash
# 在 Windows 上（装了 git 就行）
cd WeChatGlassGroups
git init && git add -A
git commit -m "stage 1: discovery build"
git remote add origin https://github.com/<你的账号>/WeChatGlassGroups.git
git push -u origin main
```

然后去 GitHub 仓库的 **Actions** 页面，等这次 run 跑完（大约 3~5 分钟），在页面底部 **Artifacts** 里下载 `WeChatGlassGroups-deb`，解压就是 `.deb`。

workflow 里我额外加了一步 **Verify binary**，会打印 `lipo -archs` / `codesign -dvvv` / `otool -L`。这一步很关键——"装上了但插件不生效"十次有九次是**架构不对（编成了 arm64 而非 arm64e）或签名丢了**，有这段输出你一眼就能看出来，不用瞎猜。

想手动重跑：Actions 页面右上角 **Run workflow**（我配了 `workflow_dispatch`）。

> 备选路线：WSL2 + Linux 版 Theos。能编译，但要自己解决 patched SDK（含私有框架 tbd）、cctools-port、ldid2 三件事，坑不少，而且我没法在这里替你验证每一步。如果你坚持走这条，先告诉我，我给你逐步命令。

### 1. 编译（本地 Mac 的话）

```bash
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS

cd WeChatGlassGroups
make clean && make package          # Makefile 里已开 WGG_DISCOVERY=1，先做阶段一
```

产物在 `packages/` 下的 `.deb`。

### 2. 装到手机（Dopamine / 无根）

**最省事的方式：不用 SSH。** 把 `.deb` 传到手机（微信传给自己、iCloud、AirDrop、或 `scp` 到 `/var/mobile/Documents/`），然后用 **Sileo → 从文件安装**。

想走命令行的话，Windows 自带 OpenSSH：

```powershell
scp .\WeChatGlassGroups.deb root@<手机IP>:/var/mobile/Documents/
ssh root@<手机IP> "sileo-cli install /var/mobile/Documents/WeChatGlassGroups.deb || dpkg -i /var/mobile/Documents/WeChatGlassGroups.deb"
ssh root@<手机IP> "killall -9 WeChat || true"
```

Dopamine 默认 root 密码是 `alpine`（**装完一定要改**）。

⚠️ 装完 **必须重启微信进程**（`killall -9 WeChat`）。重新打开微信不会重新加载插件，很多人卡在这里以为插件没生效。

### 3. 看日志（Windows 上也能看）

```powershell
# Windows 自带 OpenSSH 客户端，直接连手机看 syslog
ssh root@<手机IP> "socat - UNIX-CONNECT:/var/run/lockdown/syslog.sock"
```

如果手机没装 `socat`，用 Sileo 装一个；或者改用 **3uTools / iMazing** 的实时日志功能，过滤关键字 `WGG`。

打开微信，进首页，你应该看到（大概长这样）：

```
[WGG] WeChatGlassGroups loaded
[WGG] ---- search classes containing 'Conversation' ----
[WGG]    MMConversationListViewController
[WGG]    MMConversationCell
[WGG]    ...
[WGG] candidate MMConversationListViewController -> EXISTS
[WGG] candidate MMTableView -> missing
[WGG] ========== CLASS MMConversationListViewController ==========
[WGG] -- properties (N) --
[WGG]    @property conversationArray   [T@"NSArray",...]
[WGG] -- ivars (N) --
[WGG]    ivar m_arrConversation   [@"NSArray"]
```

### 4. 同时会打出 view 层级

`WGGDumpViewTree()` 会把 window 下所有 view 带 frame / 类名 / 行数递归打印。**这份日志是决定"面板放哪一层"的依据**——重点看：

- 哪一层是那张会话 table（行数对不对得上你实际的会话数）
- **`dataSource=` 后面那个类名 —— 这是整份日志里最重要的一行。** 它告诉你阶段二该 hook 谁。如果它不是 `MMConversationListViewController`，说明微信抽了独立的 data source 类，`Tweak.x` 末尾那段就要搬过去。
- table 的 `contentInset` 当前是多少（微信自己可能已经设了值，我们要在上面叠加）
- 有没有 `UIVisualEffectView`（微信自己的毛玻璃，可以借鉴它的层级位置）

**把这份日志贴回来**，我就能把阶段二的类名和属性名填成真值。

---

## 四、阶段二：接上数据源过滤

拿到真名后，改两个地方：

1. `Tweak.x` 里 `kWGGConversationClass` / `kWGGConversationArrayName` 改成真名。
2. `Makefile` 里打开：

```make
WeChatGlassGroups_CFLAGS += -DWGG_STAGE2=1
WeChatGlassGroups_CFLAGS += -DWGG_STAGE2_FILTER=1
```

然后**一步一步来，不要一次全开**：

- 先只开 `WGG_STAGE2`（不加 `_FILTER`）：只记录原始数组、不改行为。确认日志里数组能正常拿到、微信不崩。
- 再开 `WGG_STAGE2_FILTER`：真正过滤。
- 如果崩了，看崩溃日志的 `Last Exception Backtrace`——如果是 `NSRangeException` / `index out of range`，说明**行数和 cell 的来源不配对**，回到第一节第 1 条，去 `WGGDumpClassInfo` 的输出里找还有谁实现了 `numberOfRowsInSection:`，把它也拦上。

### 关键：`WGG_STAGE2_FILTER` 全开前先看这段

`%hook` 只拦了 `MMConversationListViewController` 自己的三个方法。如果探测发现 table 的 `dataSource` **不是**这个控制器（很常见——微信喜欢抽一个单独的 data source 类），那要 hook 的是那个类，`Tweak.x` 末尾三个方法原样搬过去即可。

`Discovery.m` 的 `WGGDumpViewTree` 里对 table 打了行数，你可以用它交叉验证：**table 报的行数 == 你过滤后的数组 count**，这个等式成立才安全。

---

## 五、当前进度对照原设计

| 原设计 | 状态 |
|---|---|
| 玻璃卡片组件（`UIVisualEffectView` + `SystemUltraThinMaterialLight`） | ✅ 已实现 |
| 左大图 + 右个人信息卡（#无趣 / life is but a dream / 0920） | ✅ 已实现（衬线斜体已还原，图片待提供素材） |
| 「X X X」浅灰分隔 | ✅ 已实现 |
| 4 个分组胶囊（垂直排列、箭头在左、完全圆角） | ✅ 已实现（按效果图尺寸） |
| 点击切换选中态 + 按压反馈 | ✅ 已实现（选中：白度提高 + 标题加粗；按下：0.985 缩放） |
| 4 组固定分组 + 持久化（`NSUserDefaults`） | ✅ 已实现（默认归 `Chats`） |
| Hook 首页控制器、挂面板、避开灵动岛 | ✅ 已实现（类名用关键字匹配，待真名收窄） |
| 数据源过滤 | 🟡 代码已写，**默认关闭**，待真机确认 |
| 底部搜索框（效果图那条胶囊） | 🟡 组件已写（`WGGSearchBar`），未注入；另有原生搜索框改玻璃的低风险开关 |
| 底部自定义 Tab 栏（效果图三个玻璃胶囊） | ❌ **未做 —— 与你的原设计冲突，等你定方案** |
| 分组未读角标 | ❌ 效果图无此元素；接口保留、暂不渲染 |
| 设置页（`PreferenceBundle`） | ❌ 未做 |
| 长按会话快速分组 | ❌ 未做 |
| 深色/浅色自动适配 | ✅ 系统 `Material` 自动跟随（用了 `labelColor` / `secondaryLabelColor`） |
| 面板滑动收起 | ❌ 未做 |

---

## 六、下一步最省时间的顺序

1. Mac 上装 Theos，`make package` —— **先让代码编译通过**。我没法帮你过编译，这一步的报错（缺 SDK、rootless 路径、Logos 语法）你得自己贴回来我再改。
2. 装到手机，只跑阶段一，拿 `WGG` 日志。
3. 日志贴回来 → 我把阶段二的类名/属性名改成真值。
4. 先验证"面板能显示且不被 table 吃掉"，再开过滤。
5. 最后做设置页 + 角标 + 深色微调。

---

## 七、已知风险清单

| 风险 | 说明 |
|---|---|
| 封号 | 改微信违反 ToS，存在被检测/限制的可能。用小号。 |
| 微信升级即失效 | 8.0.78 → 8.0.79 就可能类名/属性全变。版本门禁会拦住，但插件等于停摆。 |
| 数据源假设错误 | 最可能的崩溃来源。所以阶段一必须做、`WGG_STAGE2_FILTER` 必须最后开。 |
| 我的代码未经编译 | 有语法/API 层面的小错是正常的，第一次 `make` 大概率要修几处。 |
| 内存管理 | Makefile 里关掉了 ARC（`-fno-objc-arc`），为了贴近越狱插件惯例、避免和微信 MRC 代码混用出问题。`GlassGroupPanel` 里所有对象都是 `strong` 属性，生命周期跟着视图走，应该没问题；但如果你改代码后出现野指针崩溃，第一嫌疑就是这里。 |
