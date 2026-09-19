TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LyPerformance
LyPerformance_FILES = Tweak.xm
LyPerformance_CFLAGS = -fobjc-arc
LyPerformance_FRAMEWORKS = Foundation UIKit os
LyPerformance_PRIVATE_FRAMEWORKS = FrontBoardServices

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
