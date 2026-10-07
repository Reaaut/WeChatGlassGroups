##############################################################################
# WeChatGlassGroups — Theos 构建配置
#
# 目标环境（请确认与你手机实际一致）：
#   iPhone 14 Pro / iOS 16.1.1 / WeChat 8.0.78 / arm64e
#
# ⚠️ 重要：iOS 15+ 的越狱（Dopamine / 较早的 Taurine 移植版 / palera1n 等）
#    基本都是 **rootless（无根）** 方案，插件不能装到 /Library/MobileSubstrate，
#    必须放到 /var/jb/Library/MobileSubstrate/DynamicLibraries/。
#    所以下面必须开 THEOS_PACKAGE_SCHEME = rootless。
#    如果你确认自己的越狱是 **有根** 的，把这一行注释掉、并把安装路径改回 /Library/...
##############################################################################

export THEOS_PACKAGE_SCHEME = rootless

# 架构：arm64e（A12 及以上设备的用户态 ABI）。只支持 arm64e 时不要带 arm64。
ARCHS = arm64e

# 部署目标 = 你手机的系统版本
TARGET = iphone:clang:latest:16.0

# 关闭 ARC，全程手动内存管理更贴近越狱插件惯例（避免与微信 MRC 代码混用出错）
# 若你更习惯 ARC，改成 -fobjc-arc，但注意 hook 里返回对象的所有权语义会变。
ADDITIONAL_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations -Wno-unused-variable

# 语法严格一些，帮你早暴露问题
ADDITIONAL_CFLAGS += -Wall -Wno-unused-function

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeChatGlassGroups

WeChatGlassGroups_FILES = Tweak.x GlassGroupPanel.m GroupStore.m Discovery.m
WeChatGlassGroups_CFLAGS = -I./include
WeChatGlassGroups_FRAMEWORKS = UIKit Foundation QuartzCore

# 阶段一：打开运行时探测（真机上把类名日志打出来）
WeChatGlassGroups_CFLAGS += -DWGG_DISCOVERY=1

# 阶段二：确认真实类名后再打开下面两行
# WeChatGlassGroups_CFLAGS += -DWGG_STAGE2=1
# WeChatGlassGroups_CFLAGS += -DWGG_STAGE2_FILTER=1

# 可选：给微信原生搜索框加玻璃圆角（阶段一确认 view 层级后再开）
# WeChatGlassGroups_CFLAGS += -DWGG_RESTYLE_SEARCHBAR=1

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat || true"
