#!/bin/bash
#
# File: build-pypicloud.sh
# ========================================================================
# When        Who  What
# ------------------------------------------------------------------------
# 2021-01-20  jtc  Script to build pypicloud system start to finish
# ========================================================================
#
# Notes:
#
# This script does all the steps to build pypicloud:
# - checks out the repo (from our forked version, presumably)
# - installs requirements and builds the pypicloud package
# - uploads the pypicloud package to our pip index (pypicloud itself!)
# - preps a context directory and builds a docker image with your choice of base
# - saves the new image to a local tar file and/or uploads to our image registry
#
# TODO: Control of the script is extremely rudimentary and would be improved with some command line options and help.
# However, in its current state:
#  - you can export variables to control options
#  - you can pass a number of the step to start on, but otherwise there are no options
#
# Chances are, if you're reading this, you're in a dev cycle and it will make sense to simply edit the file
# and then run it with the step option. Regardless, it provides good documentation of the steps required to
# modify the package and build a new image.
#
# It would be cool to add the ability to optionally run the pypicloud tests (that come with the project repo).
#

declare -i startstep=${1:-1}

# Override defaults for local testing
#PIP_INDEX_URL="http://pypicloud.locninja:8088/simple/"
#PIP_TRUSTED_HOST=pypicloud.locninja
#ADMIN_USER=admin
#ADMIN_USER_PASSWORD="blahblahblah"

: ${ADF_PPC:="$HOME/code/projects/ambition-dockerfiles/pypicloud"}
: ${WORKDIR:="$HOME/code/projects/pypicloud"}
#git@github.com:geophphrie/pypicloud.git
: ${PPC_REPO:="ambitioninc/pypicloud"}
: ${PPC_BRANCH:="ubu"}
#: ${PPC_BRANCH:="master"}

: ${PIP_INDEX_URL:="https://pypicloud.ambition.ninja/simple/"}

# Allow a twine repository to be separate from the pip index
: ${TWINE_REPOSITORY_URL:=${PIP_INDEX_URL}}
: ${ADMIN_USER:=ambition}
: ${ADMIN_USER_PASSWORD:=nop}

: ${PYPICLOUD_IMAGE:=alpine} # could be alpine or baseimage
: ${PYPICLOUD_VERSION:="1.2.4+ambition"}

: ${AMBITION_ECR:="401107560193.dkr.ecr.us-east-1.amazonaws.com"}


if [[ $startstep -le 0 ]]; then

    echo "Checking installation for prerequisites - using sudo for apt-get install ..."
    sudo apt-get install python3-dev build-essential default-libmysqlclient-dev libsasl2-dev libldap2-dev libssl-dev

    if [[ -d "$WORKDIR" ]]; then
	rmdir "$WORKDIR" 2>/dev/null || echo "Working directory [ $WORKDIR ] exists and is not empty. Please fix!" && exit
    fi
fi

if [[ $startstep -le 2 ]]; then
    
    echo "Cloning pypicloud repo [ $PPC_REPO ], branch [ $PPC_BRANCH ] to directory [ $WORKDIR ] ..."
    git clone --verbose --single-branch --branch "$PPC_BRANCH" "git@github.com:$PPC_REPO" "$WORKDIR"
    status=$?
    if [[ $status -ne 0 ]]; then
	echo "Failed to clone repo. Quitting!"
	exit $status
    fi
fi

# Perform the rest of the tasks from the pypicloud repo dir, regardless of the start step.
echo "Working from [ $WORKDIR ]"
cd "$WORKDIR"
ENVDIR="${WORKDIR}/pypicloud_env"
ENVBIN="${ENVDIR}/bin"

if [[ $startstep -le 3 ]]; then
    echo "Creating and activating virtual environment..."
    if [[ -d $ENVDIR ]]; then
	echo "  - Removing old venv ..."
	rm -rf $ENVDIR
    fi
    echo "  - Creating new env ..."
    python3 -m venv $ENVDIR

fi

# If we are doing anything with steps 3-7, we need to activate the virtual environment
if [[ $startstep -le 7 ]]; then

    # Activate the venv if we get to this point - it is required for the next things
    echo "  - Activating ..."

    #. ./pypicloud_env/bin/activate
    pipcmd="${ENVBIN}/pip"
    pycmd="${ENVBIN}/python"
    #status=$?
    #if [[ $status -ne 0 ]]; then echo "Failed to activate environment!"; exit; fi
    # We need these first so the requirements build will work.
    echo "  - Installing package stuff ..."
    $pipcmd install wheel twine

    # Use curl to test if we're on the vpn. Maybe there's a better way...
    echo "Testing access to pip index ..."
    curl "$PIP_INDEX_URL" >/dev/null 2>&1
    status=$?
    if [[ $status -ne 0 ]]; then
	echo "Cannot reach the pip index [ $PIP_INDEX_URL ]. Do you need to connect to the vpn?"
	exit
    fi
fi


if [[ $startstep -le 4 ]]; then
    # Actually, we don't need the pypicloud dev requirements - that's mostly for testing.
    true
    #echo "Installing pypicloud dev requirements ..."
    #export PIP_INDEX_URL PIP_DISABLE_PIP_VERSION_CHECK=1
    #$pipcmd install -r requirements_dev.txt
fi

if [[ $startstep -le 5 ]]; then

    echo "Building pypicloud package ..."
    $pycmd setup.py bdist_wheel
    status=$?
    if [[ $status -ne 0 ]]; then echo "Build failure - quitting!"; exit; fi    
fi

# Stop doing this upload, and just copy the wheel into the dockerfile context instead!
if [[ $startstep -eq 99 ]]; then

    if [[ "$ADMIN_USER_PASSWORD" == "nop" ]]; then
	echo "You will need to supply environment ADMIN_USER_PASSWORD - the pypicloud admin password."
    else
	pwparam="--password $ADMIN_USER_PASSWORD"
    fi

    twinecmd="${ENVBIN}/twine upload --repository-url $TWINE_REPOSITORY_URL --username $ADMIN_USER $pwparam dist/*"
    
    echo "Uploading to pypicloud index ..."
    echo "Upload command is: [ $twinecmd ]"
    $twinecmd
    status=$?
    if [[ $status -ne 0 ]]; then echo "Upload failure - quitting!"; exit; fi
fi

if [[ $startstep -le 7 ]]; then

    # Create the dir to be the docker context
    mkdir -vp build/docker

    # Copy the pypicloud wheel into the docker context
    cp -v ./dist/*.whl ./build/docker
    
    # Copy the specified dockerfile from ambition-dockerfiles
    cp -v ${ADF_PPC}/build/Dockerfile-${PYPICLOUD_IMAGE} ./build/docker/Dockerfile
    # If there are additional files required for the docker context for the specific
    # image base, copy them in. Baseimage has one but this will work generally.
    if [[ -d $ADF_PPC/build/$PYPICLOUD_IMAGE ]]; then
	cp -v $ADF_PPC/build/$PYPICLOUD_IMAGE/* ./build/docker
	# If there are scripts, make sure they have the x bit
	chmod +x ./build/docker/*.sh
    fi

    # Do the docker build. Note that our PYPICLOUD_VERSION will usually have a +ambition in it
    # as per python package specs. Docker doesn't like that. So note the /+// in the param to
    # eliminate the plus and leave it e.g. 1.17ambition.
    set -x
    if [[ ! -z $PIP_TRUSTED_HOST ]]; then piparg="--build-arg PIP_TRUSTED_HOST=$PIP_TRUSTED_HOST"; fi
    localtag="ambition/pypicloud:${PYPICLOUD_VERSION//+/}-${PYPICLOUD_IMAGE}"
    ecrversion="${AMBITION_ECR}/pypicloud:${PYPICLOUD_VERSION//+/}-${PYPICLOUD_IMAGE}"
    ecrlatest="${AMBITION_ECR}/pypicloud:latest"
#    docker build --no-cache \
    docker build \
	   --build-arg PIP_INDEX_URL="$PIP_INDEX_URL" $piparg \
	   --build-arg PYPICLOUD_VERSION="$PYPICLOUD_VERSION" \
	   -t "$localtag" -t "$ecrversion" -t "$ecrlatest" \
	   ./build/docker
    status=$?
    set +x

    # Save the image to a tar file locally. This can be loaded by the service script if it exists.
    if [[ $status -eq 0 ]]; then
      mkdir -p ~/tmp && docker save -o ~/tmp/ambition-pypicloud.tar ${localtag}

      # Push the image to the registry. Don't actually do it now - really need a command-line option for that.
      echo "Here are the commands to push the new image to the registry:"
      echo "docker image push $ecrversion"
      echo "docker image push $ecrlatest"
    fi
fi
