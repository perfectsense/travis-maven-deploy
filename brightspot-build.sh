#!/bin/bash

set -e -u

BUILD_LOG=true

function build_log() {
    if [[ $BUILD_LOG == 'true' ]]; then
        echo "$1"
    fi
}

# Evaluates a maven expression ($expr) for a given path ($path). If ($expr)
# is a space separated list of more than one expression, then each is evaluated
# interactively in offline mode.
function maven_expression() {

    local path=$1
    local expr=$2

    # result var
    local __result_var=
    if [ "$#" -gt 2 ]; then
        __result_var=$3
    else
        __result_var=
    fi
    # end result var

    local raw_expr_value=

    local expr_arr=($expr)
    if [ ${#expr_arr[@]} -gt 1 ]; then
        # multiple expressions - run in interactive mode, offline
        local interactive_expr=""

        for expr_arr_item in "${expr_arr[@]}"; do
            interactive_expr="$interactive_expr\${$expr_arr_item}"$'\n'
        done
        interactive_expr="${interactive_expr}0"$'\n'

        raw_expr_value=$(echo "$interactive_expr" | mvn -o -f $path help:evaluate)
    else
        # single expression - run in non-interactive batch mode
        raw_expr_value=$(mvn -B -f $path help:evaluate -Dexpression=$expr)
    fi

    local expr_value=$(echo "$raw_expr_value" \
        | grep -F -v "[INFO]" \
        | grep -F -v "[WARNING]" \
        | grep -F -v "[ERROR]"
        )

    build_log "maven_expression:       path: $path"
    build_log "maven_expression: expression: $expr"
    #build_log "maven_expression:  raw_value: $raw_expr_value"
    #build_log "maven_expression:      value: $expr_value"

    # return
    if [[ "$__result_var" ]]; then
        eval $__result_var="'$expr_value'"
    else
        echo "$expr_value"
    fi
}

# Given a path ($path) to a maven module directory, returns a new line
# separated string of all the sub-modules defined in the module's pom.xml file.
function module_list() {

    local path=$1

    # result var
    local __result_var=
    if [ "$#" -gt 1 ]; then
        __result_var=$2
    else
        __result_var=
    fi
    # end result var

    local modules=
    maven_expression $path project.modules modules

    local module_list=$(echo "$modules" \
        | grep '<string>' \
        | sed 's/<\/*string>//g' \
        | sed 's/[[:blank:]]*//')

    build_log "module_list: $module_list"

    # return
    if [[ "$__result_var" ]]; then
        eval $__result_var="'$module_list'"
    else
        echo "$module_list"
    fi
}

# Fetches the list of modules for each project that has been changed between
# the commit range ($commit_range) as a string of comma separated values. The
# result can be directly used as the value of the Maven -pl option.
function project_diff_list() {

    local commit_range=$1

    # result var
    local __result_var=
    if [ "$#" -gt 1 ]; then
        __result_var=$2
    else
        __result_var=
    fi
    # end result var

    local modified_modules=()

    local build_script_modified="false"

    local modified_files=$(git diff-tree -m -r --no-commit-id --name-only ${commit_range/.../..})
    #build_log "modified_files: $modified_files"

    for file_path in $modified_files; do
        if [ "$file_path" == "etc/build.sh" ]; then
            build_script_modified="true"
        fi
    done

    local modified_root_paths=
    if [ "$build_script_modified" == "true" ]; then
        build_script_modified="true"
        module_list . modified_root_paths
    else
        modified_root_paths=$(echo "$modified_files" | cut -d/ -f1 | uniq)
    fi

    build_log "modified_root_paths: $modified_root_paths"

    for dir in $modified_root_paths; do
        if [ -e "$dir/pom.xml" ]; then
            modified_modules+=($dir)

            sub_modules=
            module_list $dir sub_modules

            for sub_dir in $sub_modules; do
                modified_modules+=($dir/$sub_dir)
            done
        fi
    done

    modified_modules_array=${modified_modules[@]+"${modified_modules[@]}"}
    modified_modules_csv=$(array_to_csv $modified_modules_array)

    build_log "modified_modules_csv: $modified_modules_csv"

    # return
    if [[ "$__result_var" ]]; then
        eval $__result_var="'$modified_modules_csv'"
    else
        echo "$modified_modules_csv"
    fi
}

# For a given maven module path ($plugin_path), checks whether the version of
# said module is published and released in artifactory by returning the HTTP
# status code of the module's pom file by making an HTTP request to artifactory.
function artifactory_status() {

    local plugin_path=$1

    # result var
    local __result_var=
    if [ "$#" -gt 1 ]; then
        __result_var=$2
    else
        __result_var=
    fi
    # end result var

    local artifactory_url_prefix="https://artifactory.psdops.com/psddev-releases"

    local dependency_info=
    maven_expression $plugin_path "project.groupId project.artifactId project.version" dependency_info

    dependency_info=($dependency_info)

    local group_id=${dependency_info[0]}
    local artifact_id=${dependency_info[1]}
    local version=${dependency_info[2]}

    local group_id_pathed=${group_id//./\/}

    local artifactory_url="$artifactory_url_prefix/$group_id_pathed/$artifact_id/$version/$artifact_id-$version.pom"

    build_log "artifactory_status: artifactory_url: $artifactory_url"

    local artifactory_status=$(curl -s -I "$artifactory_url" | head -n 1 | cut -d$' ' -f2)

    build_log "artifactory_status: artifactory_url_status: $artifactory_status"

    # return
    if [[ "$__result_var" ]]; then
        eval $__result_var="'$artifactory_status'"
    else
        echo "$artifactory_status"
    fi
}

# Fetches a CSV of maven module paths whose versions have not yet been deployed
# to artifactory.
function get_newly_versioned_modules() {

    # result var
    local __result_var=
    if [ "$#" -gt 0 ]; then
        __result_var=$1
    else
        __result_var=
    fi
    # end result var

    local new_modules=()
    local status=

    local root_modules=
    module_list ./ root_modules

    build_log "get_newly_versioned_modules: root_modules: $root_modules"

    for dir in $root_modules; do

        artifactory_status $dir status

        if [[ $status -ne 200 ]]; then
            new_modules+=($dir)
            build_log "get_newly_versioned_modules: added $dir to new_modules"
        fi

        local sub_modules=
        module_list $dir sub_modules
        for sub_dir in $sub_modules; do

            artifactory_status $dir/$sub_dir status

            if [[ $status -ne 200 ]]; then
                new_modules+=($dir/$sub_dir)
                build_log "get_newly_versioned_modules: added $dir/$sub_dir to new_modules"
            fi
        done
    done

    #local new_modules_string=$(echo "${new_modules[*]}")
    #build_log "get_newly_versioned_modules: new_modules: $new_modules_string"

    local new_modules_array=${new_modules[@]+"${new_modules[@]}"}
    local new_modules_csv=$(array_to_csv $new_modules_array)

    build_log "new_modules_csv: $new_modules_csv"

    # return
    if [[ "$__result_var" ]]; then
        eval $__result_var="'$new_modules_csv'"
    else
        echo "$new_modules_csv"
    fi
}

# Converts an array to comma separated values. This function's value must be
# returned directly and cannot be written to a variable.
function array_to_csv() {

    local array=$@

    local csv=

    for array_item in $array; do
        csv="$csv$array_item,"
    done

    csv=$(echo $csv | rev | cut -c 2- | rev)

    # return
    echo "$csv"
}

function verify_no_release_snapshots() {

    local bom_deps=
    maven_expression bom project.dependencyManagement.dependencies bom_deps

    local parent_plugin_deps=
    maven_expression parent project.build.pluginManagement.plugins parent_plugin_deps

    local bom_snapshot_deps=$(echo "$bom_deps" | grep -B 2 "<version>" | grep -B 2 "SNAPSHOT" || true)
    local parent_plugin_snapshot_deps=$(echo "$parent_plugin_deps" | grep -B 2 "<version>" | grep -B 2 "SNAPSHOT" || true)

    if [[ ! -z "$bom_snapshot_deps" || ! -z "$parent_plugin_snapshot_deps" ]]; then

        echo "ERROR: Found snapshot dependencies in release candidate."

        if [[ ! -z "$bom_snapshot_deps" ]]; then
            echo "bom: Snapshot Dependencies:"
            echo "$bom_snapshot_deps"
        fi

        if [[ ! -z "$parent_plugin_snapshot_deps" ]]; then
            echo "parent: Plugin Snapshot Dependencies:"
            echo "$parent_plugin_snapshot_deps"
        fi

        echo "Exiting. Please fix the dependencies above before retrying the release build."

        exit 1
    fi
}

echo "TRAVIS_COMMIT_RANGE: $TRAVIS_COMMIT_RANGE"
echo "TRAVIS_TAG: $TRAVIS_TAG"
echo "TRAVIS_REPO_SLUG: $TRAVIS_REPO_SLUG"
echo "TRAVIS_PULL_REQUEST: $TRAVIS_PULL_REQUEST"
echo "TRAVIS_BRANCH: $TRAVIS_BRANCH"

MAVEN_OPTS="-Xmx3000m -XX:MaxDirectMemorySize=2000m"

if [[ "$TRAVIS_REPO_SLUG" == "perfectsense/"* ]]; then

    if [ ! -z "$TRAVIS_TAG" ]; then
        echo "Preparing RELEASE version..."
        git fetch --unshallow || true
        touch BSP_ROOT
        touch TAG_VERSION bom/TAG_VERSION parent/TAG_VERSION grandparent/TAG_VERSION
        mvn -B -Dtravis.tag=$TRAVIS_TAG -Pprepare-release initialize

        verify_no_release_snapshots

        mvn -B clean install

        NEWLY_VERSIONED_MODULES=
        get_newly_versioned_modules NEWLY_VERSIONED_MODULES

        echo "NEWLY_VERSIONED_MODULES: $NEWLY_VERSIONED_MODULES"

        mvn -B --settings=$(dirname $(pwd)/$0)/settings.xml -Pdeploy deploy -pl $NEWLY_VERSIONED_MODULES
    else
        mvn -B clean install -pl .,parent,bom,grandparent

        if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then
            if [[ "$TRAVIS_BRANCH" == "release/"* ]] ||
               [[ "$TRAVIS_BRANCH" == "patch/"* ]] ||
               [ "$TRAVIS_BRANCH" == "develop" ] ||
               [ "$TRAVIS_BRANCH" == "master" ]; then

                MODIFIED_MODULES=
                project_diff_list $TRAVIS_COMMIT_RANGE MODIFIED_MODULES
                echo "MODIFIED_MODULES: $MODIFIED_MODULES"

                if [ ! -z "$MODIFIED_MODULES" ]; then
                    echo "Deploying SNAPSHOT to Maven repository..."
                    mvn -B --settings=$(dirname $(pwd)/$0)/settings.xml -Pdeploy deploy -pl $MODIFIED_MODULES
                else
                    echo "No projects to deploy..."
                fi
            else
                echo "Branch is not associated with a PR, nothing to do..."
            fi
        else
            MODIFIED_MODULES=
            project_diff_list $TRAVIS_COMMIT_RANGE MODIFIED_MODULES
            echo "MODIFIED_MODULES: $MODIFIED_MODULES"

            if [ ! -z "$MODIFIED_MODULES" ]; then
                echo "Building pull request..."
                mvn -B clean install -pl $MODIFIED_MODULES
            else
                echo "No projects to build..."
            fi
        fi
    fi
fi
