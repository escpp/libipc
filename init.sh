#!/bin/bash

git submodule update --init

if [ ! -d cpp-ipc/es_tools ]; then
	cd cpp-ipc
	cp ../es_tools ./ -rf
	cp ../CMakeLists.txt ./
	cp es_tools/makefile ./
	bash es_tools/shell/es_replace cpp-ipc libipc
fi

