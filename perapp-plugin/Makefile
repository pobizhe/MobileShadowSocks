# Shadowsocks per-app plugin
# Copyright (c) 2014 Linus Yang

TARGET = iphone:clang:latest:5.0
ARCHS = armv7 armv7s arm64

include theos/makefiles/common.mk

TWEAK_NAME = SSPerApp
SSPerApp_FILES = Tweak.x $(wildcard proxychains/*.c)
SSPerApp_CFLAGS = -DTHREAD_SAFE -Os
SSPerApp_LIBRARIES = substrate finder
SSPerApp_PRIVATE_FRAMEWORKS = AppSupport CFNetwork
SSPerApp_LDFLAGS = -Llibfinder

export PATH := $(shell pwd)/../extra:$(PATH)

include $(THEOS_MAKE_PATH)/tweak.mk

VERSION.INC_BUILD_NUMBER = 6

stage::
	find "$(THEOS_STAGING_DIR)" -type f \( -iname "*.strings" -o -iname "*.plist" \) -exec plutil -convert binary1 {} \;

package::
	mkdir -p ../release/ && mv -f $(THEOS_PACKAGE_NAME)*.deb ../release/
