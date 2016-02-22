#!/bin/sh
# Copyright (c) 2016 Assured Information Security, Inc.
# Copyright (c) 2016 BAE Systems
#
# Contributions by Jean-Edouard Lejosne
# Contributions by Christopher Clark
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#

set -e

BUILD_USER=%BUILD_USER%
BUILD_DIR=%BUILD_DIR%
IP_C=%IP_C%
SUBNET_PREFIX=%SUBNET_PREFIX%
ALL_BUILDS_SUBDIR_NAME=%ALL_BUILDS_SUBDIR_NAME%
LAYERS=%LAYERS%

mkdir $BUILD_DIR
cd $BUILD_DIR

git clone git://${SUBNET_PREFIX}.${IP_C}.1/${BUILD_USER}/openxt.git

cd openxt
cp example-config .config
cat >>.config <<EOF
OPENXT_GIT_MIRROR="${SUBNET_PREFIX}.${IP_C}.1/${BUILD_USER}"
OPENXT_GIT_PROTOCOL="git"
REPO_PROD_CACERT="/home/build/certs/prod-cacert.pem"
REPO_DEV_CACERT="/home/build/certs/dev-cacert.pem"
REPO_DEV_SIGNING_CERT="/home/build/certs/dev-cacert.pem"
REPO_DEV_SIGNING_KEY="/home/build/certs/dev-cakey.pem"
EOF

# Handle layers
if [[ $LAYERS != 'None' ]]; then
    ./do_build.sh -s setupoe
    OIFS=$IFS
    IFS=','
    head build/conf/bblayers.conf -n -3 > build/conf/bblayers.conf.tmp
    mv build/conf/bblayers.conf.tmp build/conf/bblayers.conf
    for trip in $LAYERS;
    do
        LAYER_NAME=`echo $trip | cut -f 1 -d ':'`
        LAYER_REPO=`echo $trip | cut -f 2 -d ':'`
        LAYER_BRANCH=`echo $trip | cut -f 3 -d ':'`
        echo "  \${TOPDIR}/repos/$LAYER_NAME \\" >> build/conf/bblayers.conf
        cd build/repos
        git clone -b $LAYER_BRANCH git://$LAYER_REPO
        cd ../../
    done
    echo "  \"" >> build/conf/bblayers.conf
    IFS=$OIFS
fi

./do_build.sh | tee build.log

# Copy the build output
scp -r build-output/* "${BUILD_USER}@${SUBNET_PREFIX}.${IP_C}.1:${ALL_BUILDS_SUBDIR_NAME}/${BUILD_DIR}/"

# The script may run in an "ssh -t -t" environment, that won't exit on its own
set +e
exit
