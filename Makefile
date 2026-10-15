export THEOS ?= $(THEOS)
TARGET := iphone:clang:latest:15.0
# 只编 arm64（thin），避免 fat 通用二进制：TrollFools 内置 ldid 不支持 fat，
# 对 arm64+arm64e 双架构产物报 "Unsupported Mach-O type"
ARCHS = arm64
INSTALL_TARGET_PROCESSES = WeChat
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = FullScreenBackTweak
FullScreenBackTweak_FILES = FullScreenBackTweak.m
FullScreenBackTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-error
FullScreenBackTweak_FRAMEWORKS = UIKit Foundation AudioToolbox
include $(THEOS)/makefiles/tweak.mk
