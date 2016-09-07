#!/bin/bash -e
#
# OpenXT build script.
# Software license: see accompanying LICENSE file.
#
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
# Invocation:
# Takes a build identifier as an optional argument to the script
# to enable rerunning this script to continue an interrupted build
# or run a build with a specified directory name.

# -- Script configuration settings.

# This /16 subnet prefix is used for networking in the containers.
# Strongly advised to use part of the private IP address space (eg. "192.168")
# This value should be configured to match the setting used in setup.sh
SUBNET_PREFIX="192.168"

# -- End of script configuration settings.

BUILDID=$1
BRANCH=$2
LAYERS=$3
OVERRIDES=$4
ISSUE=$5
DISTRO=$6

BUILD_USER="$(whoami)"
BUILD_USER_ID="$(id -u ${BUILD_USER})"
BUILD_USER_HOME="$(eval echo ~${BUILD_USER})"
IP_C=$(( 150 + ${BUILD_USER_ID} % 100 ))
ALL_BUILDS_SUBDIR_NAME="xt-builds"

umask 0022

do_overrides () {
    for trip in $OVERRIDES; do
        name=$(echo $trip | cut -f 1 -d ':')
        git=$(echo $trip | cut -f 2 -d ':')
        branch=$(echo $trip | cut -f 3 -d ':')

        rm -rf /home/git/${BUILD_USER}/$name.git
        git clone --mirror git://$git/$name /home/git/${BUILD_USER}/$name.git
        # The following code will name the override $BRANCH, to match what we're building
        if [[ $branch != "${BRANCH}" ]]; then
            pushd /home/git/${BUILD_USER}/$name.git
            # Avoid being on a releavant branch by moving the HEAD to a tmp branch
            git branch tmp
            git symbolic-ref HEAD refs/heads/tmp
            # Move $BRANCH to a backup location (avoid removing it, since some branches can't be removed)
            #   Do not fail if the branch doesn't exist, it can happen
            git branch -m $BRANCH original$BRANCH || true
            # Create a branch named $BRANCH out of the $branch requested by the override
            git branch $BRANCH $branch
            # Make $BRANCH the head of the repository
            git symbolic-ref HEAD refs/heads/$BRANCH
            popd
        fi
    done
}

# Determine the intended build directory
ALL_BUILDS_DIRECTORY="${BUILD_USER_HOME}/${ALL_BUILDS_SUBDIR_NAME}"
BUILD_DIR_PREFIX=$(date +%y%m%d)
#FIXME: the sorting in this isnt quite correct:
COUNTER=$(/bin/ls -1d "${ALL_BUILDS_DIRECTORY}/${BUILD_DIR_PREFIX}"-* \
                  2>/dev/null | \
		 sort -nr | \
		 sed -e 's/^.*-//' -n  -e 1p)
COUNTER=$((COUNTER + 1))
BUILD_DIR="${BUILD_DIR_PREFIX}-${COUNTER}"

BUILD_DIR_PATH="${ALL_BUILDS_DIRECTORY}/${BUILD_DIR}"
if [ -e "$BUILD_DIR_PATH" ] ; then
    echo "Build path is already present: ${BUILD_DIR_PATH}"
fi
if ! mkdir -p "${BUILD_DIR_PATH}" ; then
    echo "Error: Failed to create build directory: ${BUILD_DIR_PATH}" >&2
    exit 1
fi

# Reset git mirrors to stock, to revert overrides
rm -rf /home/git/${BUILD_USER}/*
for repo in `cat all_repos`; do
    git clone --mirror git://github.com/openxt/$repo /home/git/${BUILD_USER}/$repo
done

# Handle overrides
#   Note: It is against policy to set both $ISSUE and $OVERRIDES in the buildbot ui
if [[ $ISSUE != 'None' && $OVERRIDES != 'None' ]]; then
    echo "Cannot pass both a Jira ticket and custom repository overrides to build from."
    exit -1
elif [[ $ISSUE != 'None' && $OVERRIDES == 'None' ]]; then
    OVERRIDES=$( ./build_for_issue.sh $ISSUE )
else
    echo "Building using method other than Jira ticket."
fi
OFS=$IFS
IFS=','
[ "$OVERRIDES" != "None" ] && do_overrides
IFS=$OFS

# Now list the HEADS
for i in /home/git/${BUILD_USER}/*.git; do
    echo -n "`basename $i`:"
    cd $i
    git log $BRANCH -1 --pretty='tformat:%H' || echo "No $BRANCH branch"
    cd - > /dev/null
done | tee ${BUILD_DIR_PATH}/git_heads

# Start the git service if needed
ps -p `cat /tmp/openxt_git.pid 2>/dev/null` >/dev/null 2>&1 || {
    rm -f /tmp/openxt_git.pid
    git daemon --base-path=/home/git \
               --pid-file=/tmp/openxt_git.pid \
               --detach \
               --syslog \
               --export-all
    chmod 666 /tmp/openxt_git.pid
}

echo "Running build: ${BUILD_DIR}"

build_container() {
    NUMBER=$1           # 01
    NAME=$2             # oe
    echo "Building container: ${NUMBER} : ${NAME}"

    # Start the OE container
    # The containers are auto-started, and sudo requires a password,
    #   so the following lines don't do anything. Commenting out.
#    sudo lxc-info -n ${BUILD_USER}-${NAME} | \
#        grep STOPPED >/dev/null && sudo lxc-start -d -n ${BUILD_USER}-${NAME}

    CONTAINER_IP="${SUBNET_PREFIX}.${IP_C}.1${NUMBER}"
    echo "Accessing container at network address: ${CONTAINER_IP}"

    # Wait a few seconds and exit if the host doesn't respond
    # We ping the host until we get a reponse,
    # then we also ssh it until it's up, using the ping as a "sleep 1"
    tries=0
    until ping -c 1 -w 1 ${CONTAINER_IP} >/dev/null 2>&1 && \
          ssh -i "${BUILD_USER_HOME}"/ssh-key/openxt build@${CONTAINER_IP} \
              -oStrictHostKeyChecking=no true >/dev/null 2>&1; do
       tries=$(( tries + 1 ))
       if [ $tries -ge 30 ]; then
           echo "Error: Could not connect to container ${BUILD_USER}-${NAME}" \
                "at ${CONTAINER_IP}. Exiting." >&2
           exit 2
       fi
        echo "Could not connect to container ${BUILD_USER}-${NAME}" \
            "at ${CONTAINER_IP} (${tries}/30). Retrying." >&2
    done

    echo "${BUILD_USER}-${NAME} is up, starting the build now!"

    # Remove old builds
    ssh -i "${BUILD_USER_HOME}"/ssh-key/openxt -oStrictHostKeyChecking=no \
	build@${CONTAINER_IP} "rm -rf 1*"

    # Build
    cat $NAME/build.sh | \
        sed -e "s|\%BUILD_USER\%|${BUILD_USER}|" \
            -e "s|\%BUILD_DIR\%|${BUILD_DIR}|" \
            -e "s|\%SUBNET_PREFIX\%|${SUBNET_PREFIX}|" \
            -e "s|\%IP_C\%|${IP_C}|" \
            -e "s|\%BUILDID\%|${BUILDID}|" \
            -e "s|\%BRANCH\%|${BRANCH}|" \
            -e "s|\%LAYERS\%|${LAYERS}|" \
            -e "s|\%DISTRO\%|${DISTRO}|" \
            -e "s|\%ALL_BUILDS_SUBDIR_NAME\%|${ALL_BUILDS_SUBDIR_NAME}|" |\
        ssh -i "${BUILD_USER_HOME}"/ssh-key/openxt \
            -oStrictHostKeyChecking=no build@${CONTAINER_IP}
}

build_container "01" "oe"
build_container "02" "debian"
build_container "03" "centos"

# Put everything in the OE directory, like it was before
#   to avoid having to change recipes like the opkg repos one
mv ${BUILD_DIR_PATH}/git_heads ${BUILD_DIR_PATH}/custom-dev-*
mv ${BUILD_DIR_PATH}/debian ${BUILD_DIR_PATH}/custom-dev-*
mv ${BUILD_DIR_PATH}/rpms ${BUILD_DIR_PATH}/custom-dev-*

rsync -a ${BUILD_DIR_PATH}/custom-dev-* builds@158.69.227.117:/home/builds/builds/${BRANCH}
rm -rf $BUILD_DIR_PATH
