TARGET := iphone:clang:26.5:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME=rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallessKit

CallessKit_FILES = Tweak.x
CallessKit_CFLAGS = -fobjc-arc
CallessKit_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-CallessKit-all::
	install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate @rpath/CydiaSubstrate.framework/CydiaSubstrate $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib
