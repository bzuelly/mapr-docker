#!/bin/bash

. ../version.sh


sed -e"s/CENTOS_VER/$CENTOS_VER/" \
    Dockerfile.template > Dockerfile


time docker build -t $(basename $(pwd)):${CENTOS_VER}.systemd .
