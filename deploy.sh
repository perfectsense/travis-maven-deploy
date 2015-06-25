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
    git fetch --unshallow || true
    mvn -Pprepare-release initialize
    VERSION="v$(cat newVersion)"

    echo "Deploying RELEASE to Maven repository..."
    mvn clean $OPTIONS

    echo "Tagging RELEASE in GitHub..."
    git config --global user.email "support@perfectsensedigital.com"
    git config --global user.name "Travis CI"
    git tag $VERSION -a -m "$VERSION"
    git push -q "https://$GITHUB_AUTHORIZATION@github.com/$TRAVIS_REPO_SLUG" $VERSION > /dev/null 2>&1
  fi
fi
