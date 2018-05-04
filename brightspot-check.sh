#!/bin/bash

set -e -u

POM_FILES=$(find . -name 'pom.xml' -not -path '*/archetype-resources/*' -not -path '*/node_modules/*' -not -path '*/target/*')

if grep -l --exclude=./bom/pom.xml --exclude=./dari/grandparent/pom.xml '<dependencyManagement>' $POM_FILES; then
    echo 'Please move all dependencies in <dependencyManagement> into dari/grandparent/pom.xml'
    exit 1
fi

if xml sel -N m='http://maven.apache.org/POM/4.0.0' -t -i 'count(/m:project/m:dependencies/m:dependency/m:version) > 0' -f -n $POM_FILES; then
    echo 'Please define all dependency versions inside <dependencyManagement> in dari/grandparent/pom.xml'
    exit 1
fi
