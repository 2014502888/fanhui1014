export THEOS ?= $(THEOS)
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = WeChat
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = FullScreenBackTweak
FullScreenBackTweak_FILES = FullScreenBackTweak.m
FullScreenBackTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-error
FullScreenBackTweak_FRAMEWORKS = UIKit Foundation AVFoundation
include $(THEOS)/makefiles/tweak.mk
