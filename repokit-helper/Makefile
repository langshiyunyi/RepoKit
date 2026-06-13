ARCHS = arm64
include $(THEOS)/makefiles/common.mk

TOOL_NAME = repokit-helper

repokit-helper_FILES = Sources/main.m
repokit-helper_FRAMEWORKS = Foundation
repokit-helper_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
repokit-helper_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
