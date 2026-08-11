ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotlightCandidateFix SpotlightCandidateFixSpringBoard
SpotlightCandidateFix_FILES = Tweak.xm
SpotlightCandidateFix_CFLAGS = -fobjc-arc
SpotlightCandidateFix_FRAMEWORKS = UIKit QuartzCore CoreFoundation
SpotlightCandidateFixSpringBoard_FILES = SpringBoardGate.xm
SpotlightCandidateFixSpringBoard_CFLAGS = -fobjc-arc
SpotlightCandidateFixSpringBoard_FRAMEWORKS = UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
