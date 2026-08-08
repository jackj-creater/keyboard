ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpotlightCandidateFix
SpotlightCandidateFix_FILES = Tweak.xm
SpotlightCandidateFix_CFLAGS = -fobjc-arc
SpotlightCandidateFix_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
