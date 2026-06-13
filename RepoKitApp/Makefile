ARCHS = arm64
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RepoKit

RepoKit_FILES = Sources/main.m Sources/RKAppDelegate.m Sources/RKHelperClient.m Sources/RKRootViewController.m
RepoKit_FRAMEWORKS = UIKit Foundation
RepoKit_RESOURCE_FILES = Info.plist Icon-60@2x.png Icon-60@3x.png
RepoKit_RESOURCE_DIRS = Resources
RepoKit_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
