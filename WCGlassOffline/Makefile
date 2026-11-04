ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WCGlassOffline
WCGlassOffline_FILES = Tweak.xm WGGlassEngine.m WGSettings.m WGMorphingTabBar.m
WCGlassOffline_CFLAGS = -fobjc-arc
WCGlassOffline_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
