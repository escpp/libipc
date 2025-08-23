#!/bin/bash

if [ ! -d cpp-ipc/es_tools ]; then
	cp -rf es_tools cpp-ipc/
	cp cpp-ipc/es_tools/makefile cpp-ipc/
	cp CMakeLists.txt cpp-ipc
	bash cpp-ipc/es_tools/shell/es_replace cpp-ipc libipc
fi

