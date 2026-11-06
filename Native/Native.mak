# Invoked with -C vendor/7zip/CPP/7zip/Bundles/Format7zF.
include ../../var_mac_arm64.mak
MY_ARCH = -arch arm64 -march=armv8-a -mmacosx-version-min=13.0
include makefile.gcc

.PHONY: native
native: $(OBJS) $(O)/SevenZipBridge.o
	$(CXX) -dynamiclib -arch arm64 -mmacosx-version-min=13.0 -Wl,-install_name,@rpath/libSevenZip.dylib -Wl,-exported_symbols_list,$(BRIDGE_DIR)/exports.txt -o $(NATIVE_OUTPUT) $(OBJS) $(O)/SevenZipBridge.o -lpthread -ldl

$(O)/SevenZipBridge.o: $(BRIDGE_DIR)/SevenZipBridge.cpp $(BRIDGE_DIR)/../BridgeAPI/include/SevenZipBridge.h
	$(CXX) -c -std=c++17 -O2 -fPIC -arch arm64 -mmacosx-version-min=13.0 -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -I$(SEVENZIP_SOURCE_ROOT) -I$(BRIDGE_DIR)/../BridgeAPI/include -o $@ $<
