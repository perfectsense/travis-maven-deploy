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

    local raw_expr_grep_pattern="\[INFO\]\|\[WARNING\]\|\[ERROR\]"
    local raw_expr_value=

    local expr_arr=($expr)
    if [ ${#expr_arr[@]} -gt 1 ]; then
        # multiple expressions - run in interactive mode, offline
        local interactive_expr=""

        for expr_arr_item in "${expr_arr[@]}"; do
            interactive_expr="$interactive_expr\${$expr_arr_item}"$'\n'
        done
        interactive_expr="${interactive_expr}0"$'\n'

        raw_expr_grep_pattern="$raw_expr_grep_pattern\|Download"
        raw_expr_value=$(echo "$interactive_expr" | mvn -f $path/pom.xml help:evaluate)
    else
        # single expression - run in non-interactive batch mode
        raw_expr_value=$(mvn -B -f $path/pom.xml help:evaluate -Dexpression=$expr)
    fi

    local expr_value=$(echo "$raw_expr_value" | grep -v "$raw_expr_grep_pattern")

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

# Given a path ($path) to a maven module directory, returns a new line
# separated string of all the sub-modules defined in the module's pom.xml file
# recursively.
function module_list_recursive() {

    local path=$1

    # result var
    local __result_var=
    if [ "$#" -gt 1 ]; then
        __result_var=$2
    else
        __result_var=
    fi
    # end result var

    echo "module_list_recursive: $path"

    local combined_module_list=

    local modules=
    maven_expression $path project.modules modules

    local module_list=$(echo "$modules" \
        | grep '<string>' \
        | sed 's/<\/*string>//g' \
        | sed 's/[[:blank:]]*//')

    build_log "module_list: $module_list"

    for module in $module_list; do

        combined_module_list="$combined_module_list $path/$module "

        local sub_module_list=
        module_list_recursive "$path/$module" sub_module_list

        echo "sub_module_list: $sub_module_list"

        #if [[ ! -z "$sub_module_list" ]]; then
            combined_module_list="$combined_module_list $sub_module_list "
        #fi
    done

    echo "combined_module_list: $combined_module_list"

    # return
    if [[ "$__result_var" ]]; then
        eval $__result_var="'$combined_module_list'"
    else
        echo "$combined_module_list"
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

function verify_bom_dependencies() {

    local bom_deps_arr=()
    local mod_deps_arr=()

    # get the bom dependencies
    local bom_deps=
    maven_expression bom project.dependencyManagement.dependencies bom_deps

    bom_deps=$(echo "$bom_deps" | grep -A 2 "<groupId>" || true)

    # removes surrounding xml tags
    local sed_xml_expr="s/<.*>\(.*\)<\/.*>/\1/"

    if [[ ! -z $bom_deps ]]; then
        bom_deps=$bom_deps$'\n--'
    fi

    while { read -r groupId; read -r artifactId; read -r version; read -r separator; }
    do
        groupId=$(echo "$groupId" | sed "$sed_xml_expr")
        artifactId=$(echo "$artifactId" | sed "$sed_xml_expr")
        version=$(echo "$version" | sed "$sed_xml_expr")

        bom_deps_arr+=("$groupId:$artifactId:$version")
    done <<< "$(echo "$bom_deps")"

    # get the module list dependencies

    local all_modules=()

    local root_modules=
    module_list . root_modules

    # convert the list to space delim string with trailing space
    root_modules=$(echo $root_modules" ")

    # Remove the bom, parent, and grandparent since they aren't in the bom
    root_modules=${root_modules/bom /}
    root_modules=${root_modules/grandparent /}
    root_modules=${root_modules/parent /}

    for root_module in $root_modules; do

        all_modules+=($root_module)

        local sub_modules=
        module_list $root_module sub_modules

        for sub_module in $sub_modules; do
            all_modules+=($root_module/$sub_module)
        done
    done

    # TODO remove
    echo "OK2: ${#all_modules[@]}"

    for module in "${all_modules[@]}"; do
        local dependency_info=
        maven_expression $module "project.groupId project.artifactId project.version" dependency_info

        dependency_info=($dependency_info)

        local group_id=${dependency_info[0]}
        local artifact_id=${dependency_info[1]}
        local version=${dependency_info[2]}

        mod_deps_arr+=("$group_id:$artifact_id:$version")
    done

    bom_deps_arr=($(for i in ${bom_deps_arr[@]}; do echo $i; done | sort))
    mod_deps_arr=($(for i in ${mod_deps_arr[@]}; do echo $i; done | sort))

    echo "bom dependency count:    ${#bom_deps_arr[@]}"
    echo "module dependency count: ${#mod_deps_arr[@]}"

    for dep in "${bom_deps_arr[@]}"; do
        echo "bom: $dep"
    done

    for dep in "${mod_deps_arr[@]}"; do
        echo "mod: $dep"
    done

    echo "bom dependency count:    ${#bom_deps_arr[@]}"
    echo "module dependency count: ${#mod_deps_arr[@]}"
}

function build() {

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

            mvn -B clean install

            verify_no_release_snapshots

            local newly_versioned_modules=
            get_newly_versioned_modules newly_versioned_modules

            echo "newly_versioned_modules: $newly_versioned_modules"

            mvn -B --settings=$(dirname $(pwd)/$0)/settings.xml -Pdeploy deploy -pl $newly_versioned_modules
        else
            mvn -B clean install -pl .,parent,bom,grandparent

            local modified_modules_csv_list=

            if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then
                if [[ "$TRAVIS_BRANCH" == "release/"* ]] ||
                   [[ "$TRAVIS_BRANCH" == "patch/"* ]] ||
                   [ "$TRAVIS_BRANCH" == "develop" ] ||
                   [ "$TRAVIS_BRANCH" == "master" ]; then

                    project_diff_list $TRAVIS_COMMIT_RANGE modified_modules_csv_list
                    echo "modified_modules: $modified_modules_csv_list"

                    if [ ! -z "$modified_modules_csv_list" ]; then
                        echo "Deploying SNAPSHOT to Maven repository..."
                        mvn -B --settings=$(dirname $(pwd)/$0)/settings.xml -Pdeploy deploy -pl $modified_modules_csv_list
                    else
                        echo "No projects to deploy..."
                    fi
                else
                    echo "Branch is not associated with a PR, nothing to do..."
                fi
            else
                project_diff_list $TRAVIS_COMMIT_RANGE modified_modules_csv_list
                echo "modified_modules: $modified_modules_csv_list"

                if [ ! -z "$modified_modules_csv_list" ]; then
                    echo "Building pull request..."
                    mvn -B clean install -pl $modified_modules_csv_list
                else
                    echo "No projects to build..."
                fi
            fi
        fi
    fi
}

build
