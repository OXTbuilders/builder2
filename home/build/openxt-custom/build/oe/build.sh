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
BUILDID=%BUILDID%
BRANCH=%BRANCH%
LAYERS=%LAYERS%
DISTRO=%DISTRO%

mkdir $BUILD_DIR
cd $BUILD_DIR

git clone -b $BRANCH git://${SUBNET_PREFIX}.${IP_C}.1/${BUILD_USER}/openxt.git

cd openxt

# Get the latest Windows tools for the branch
mkdir wintools
rsync -r builds@158.69.227.117:/home/builds/win/$BRANCH/ wintools/
WINTOOLS="`pwd`/wintools"
WINTOOLS_ID="`grep -o '[0-9]*' wintools/BUILD_ID`"

cp example-config .config
cat >>.config <<EOF
BRANCH="${BRANCH}"
NAME_SITE="custom"
OPENXT_MIRROR="http://158.69.227.117/mirror"
OE_TARBALL_MIRROR="http://158.69.227.117/mirror/"
OPENXT_GIT_MIRROR="${SUBNET_PREFIX}.${IP_C}.1/${BUILD_USER}"
OPENXT_GIT_PROTOCOL="git"
REPO_PROD_CACERT="/home/build/certs/prod-cacert.pem"
REPO_DEV_CACERT="/home/build/certs/dev-cacert.pem"
REPO_DEV_SIGNING_CERT="/home/build/certs/dev-cacert.pem"
REPO_DEV_SIGNING_KEY="/home/build/certs/dev-cakey.pem"
WIN_BUILD_OUTPUT="$WINTOOLS"
XC_TOOLS_BUILD=$WINTOOLS_ID
SYNC_CACHE_OE=builds@158.69.227.117:/home/builds/oe
NETBOOT_HTTP_URL=http://158.69.227.117/builds
EOF

# Handle distro
if [[ $DISTRO != 'None' ]]; then
    sed -i "s/^DISTRO *=.*/DISTRO = \"${DISTRO}\"/" build/conf/local.conf-dist
fi

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

./do_build.sh -i $BUILDID -s setupoe,sync_cache

./do_build.sh -i $BUILDID | tee build.log

# The return value of `do_build.sh` got hidden by `tee`. Bring it back.
ret=${PIPESTATUS[0]}
( exit $ret )

# Build the tools and the extra packages
./do_build.sh -i $BUILDID -s xctools,ship,extra_pkgs,packages_tree

# Copy the build output
BUILD_NAME=custom-dev-${BUILDID}-${BRANCH}
scp -r build-output/${BUILD_NAME} "${BUILD_USER}@${SUBNET_PREFIX}.${IP_C}.1:${ALL_BUILDS_SUBDIR_NAME}/${BUILD_DIR}/"

# The script may run in an "ssh -t -t" environment, that won't exit on its own
set +e
exit
