#!/bin/bash

set -e -u

if [[ "$TRAVIS_REPO_SLUG" == "perfectsense/"* ]] && \
   [ "$TRAVIS_PULL_REQUEST" == "false" ]; then

  OPTIONS="--settings=$(dirname $0)/settings.xml -Pdeploy deploy"

  if [[ "$TRAVIS_BRANCH" == "release/"* ]] ||
     [ "$TRAVIS_BRANCH" == "master" ]; then

    echo "Deploying SNAPSHOT to Maven repository..."
    mvn $OPTIONS
  fi

  if [[ "$TRAVIS_BRANCH" == "release/"* ]]; then

    echo "Preparing RELEASE version..."
    mvn -o -Pprepare-release initialize

    echo "Deploying RELEASE to Maven repository..."
    mvn -o clean $OPTIONS
  fi
fi
