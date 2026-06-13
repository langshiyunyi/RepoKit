export THEOS ?= /var/jb/var/mobile/theos
export LANG=C
export LC_ALL=C

THEOS_PACKAGE_SCHEME ?= rootless
ARCHS = arm64
TARGET = iphone:clang:latest:14.0


include $(THEOS)/makefiles/common.mk

SUBPROJECTS += repokit-helper
SUBPROJECTS += RepoKitApp

include $(THEOS_MAKE_PATH)/aggregate.mk
