#!/usr/bin/ruby -w

require 'rexml/document'
require 'json'
include REXML

$stdout.sync = true

# Set to true when testing locally to skip the Artifactory upload step.
DEBUG_SKIP_UPLOAD = false

ARTIFACTORY_URL_PREFIX = 'https://artifactory.psdops.com/psddev-releases'

# Represents a Maven artifact, where the path is optional.
class MavenArtifact
  attr_accessor :group_id, :artifact_id, :version, :path

  def initialize(group_id, artifact_id, version, path)
    @group_id = group_id
    @artifact_id = artifact_id
    @version = version
    @path = path
  end

  def to_s
    "#{@group_id}:#{@artifact_id}:#{@version}"
  end
end

# Semantic Version, mostly-ish
class SemVersion

  attr_accessor :major, :minor, :patch

  def initialize(version)

    if version.respond_to?("major")
      @major = version.major
      @minor = version.minor
      @patch = version.patch
    else
      # parse version string
      version_parts = version.split(/\./, 3)

      if version_parts.length > 0
        @major = version_parts[0]
      else
        @major = '0'
      end

      if version_parts.length > 1
        @minor = version_parts[1]
      else
        @minor = nil
      end

      if version_parts.length > 2
        @patch = version_parts[2]
      else
        @patch = nil
      end

    end
  end

  def to_s
    "#{@major}.#{@minor}.#{@patch}"
  end

  def major_number
    if @major == nil
      nil
    else
      @major.to_i
    end
  end

  def minor_number
    if @minor == nil
      nil
    else
      @minor.to_i
    end
  end

  def patch_number
    if @patch == nil
      nil
    else
      @patch.to_i
    end
  end

  def is_major_snapshot
    @major.include?'-SNAPSHOT'
  end

  def is_minor_snapshot
    @minor.include?'-SNAPSHOT'
  end

  def is_patch_snapshot
    @patch.include?'-SNAPSHOT'
  end

  def is_snapshot
    is_major_snapshot || is_minor_snapshot || is_patch_snapshot
  end

end

# Finds the element targeted by the given XPath expression for the pom.xml of
# the given module_path and returns the text value of the first result.
def maven_xpath(module_path, expr)
  list = maven_xpath_list(module_path, expr)
  list.each do |item|
    return item
  end
  nil
end

# Finds the elements targeted by the given XPath expression for the pom.xml of
# the given module_path and returns the text values as an iterable.
def maven_xpath_list(module_path, expr)
  xmlfile = File.new("#{module_path}/pom.xml")
  xmldoc = Document.new(xmlfile)

  XPath.each(xmldoc, "#{expr}/text()")
end

# Calculates the Maven artifact info (groupId / artifactId / version) for the
# given module_paths. If only one path is given then only one MavenArtifact is
# returned, otherwise an iterable of the results is returned.
def maven_module_info(module_paths)

  if module_paths.respond_to?("each")
    modules = Array.new

    module_paths.each do |module_path|
      modules.push(maven_module_info(module_path))
    end

    modules
  else
    group_id = maven_xpath(module_paths, "/project/groupId")
    if group_id == nil
      group_id = maven_xpath(module_paths, "/project/parent/groupId")
    end
    artifact_id = maven_xpath(module_paths, "/project/artifactId")
    version = maven_xpath(module_paths, "/project/version")

    MavenArtifact.new(group_id, artifact_id, version, module_paths)
  end
end

# Gets the list of modules defined in the pom.xml at the given path. This
# function can optionally recurse down to sub-modules.
def maven_module_list(path, recurse = false)

  module_list = Array.new

  maven_xpath_list(path, "/project/modules/module").each do |name|

    module_list.push(name.to_s)

    if recurse
      maven_module_list("#{path}/#{name}", true).each do |name2|
        module_list.push("#{name}/#{name2}")
      end
    end
  end

  module_list
end

# Gets the Maven artifact dependencies defined in the pom.xml at the given path.
# Only those dependencies defined in the dependencyManagement section are
# returned (for now).
def maven_dependencies(path)

  deps = Array.new

  xmlfile = File.new("#{path}/pom.xml")
  xmldoc = Document.new(xmlfile)

  XPath.each(xmldoc, "/project/dependencyManagement/dependencies/dependency") do |dep|
    group_id = XPath.first(dep, "groupId/text()")
    artifact_id = XPath.first(dep, "artifactId/text()")
    version = XPath.first(dep, "version/text()")

    deps.push(MavenArtifact.new(group_id, artifact_id, version, nil))
  end

  deps
end

# Gets the Maven artifact plugin dependencies defined in the pom.xml at the
# given path. Only those dependencies defined in the pluginManagement section
# are  returned (for now).
def maven_plugins(path)

  deps = Array.new

  xmlfile = File.new("#{path}/pom.xml")
  xmldoc = Document.new(xmlfile)

  XPath.each(xmldoc, "/project/build/pluginManagement/plugins/plugin") do |dep|
    group_id = XPath.first(dep, "groupId/text()")
    artifact_id = XPath.first(dep, "artifactId/text()")
    version = XPath.first(dep, "version/text()")

    deps.push(MavenArtifact.new(group_id, artifact_id, version, nil))
  end

  deps
end

# For a given Maven artifact, checks Artifactory to see if the artifact already
# exists by returning the HTTP status response code for the artifact's pom file.
def maven_artifactory_status(maven_artifact)

  maven_artifact = maven_module_info(maven_artifact) unless maven_artifact.respond_to?("group_id")
  ma = maven_artifact

  artifactory_url = "#{ARTIFACTORY_URL_PREFIX}/#{ma.group_id.to_s.gsub(".", "/")}/#{ma.artifact_id}/#{ma.version}/#{ma.artifact_id}-#{ma.version}.pom"

  puts "Fetching: " + artifactory_url

  artifactory_status = `curl -s -I "#{artifactory_url}" | head -n 1 | cut -d' ' -f2`

  puts "Status: " + artifactory_status

  artifactory_status
end

# Fetches an array of maven module paths whose versions have not yet been
# deployed to artifactory.
def get_newly_versioned_modules

  new_modules = Array.new

  all_modules = maven_module_list(".", true)

  all_modules.each do |mod|
    new_modules.push(mod) unless maven_artifactory_status(mod).strip.eql?("200")
  end

  new_modules
end

# For a given Git commit range, checks to see if any pom.xml file was modified.
def is_pom_modified(commit_range)
  commit_range = commit_range.gsub("...", "..")

  modified_files = `git diff-tree -m -r --no-commit-id --name-only #{commit_range}`

  # write the modified files out to a file since issuing an inline echo command
  # with each as arguments can become too large for the shell to handle.
  open('modified_files.out', 'w') { |f|
    f.puts "#{modified_files}"
  }

  modified_file_names = `cat modified_files.out | rev | cut -d/ -f1 | rev | uniq`
  modified_file_names.split(/\n+/).index("pom.xml") != nil
end

# For a given Git commit range, finds all the Maven module paths that have
# been modified.
def get_project_diff_list(commit_range)

  modified_modules = Array.new

  commit_range = commit_range.gsub("...", "..")

  modified_files = `git diff-tree -m -r --no-commit-id --name-only #{commit_range}`

  # write the modified files out to a file since issuing an inline echo command
  # with each as arguments can become too large for the shell to handle.
  open('modified_root_paths.out', 'w') { |f|
    f.puts "#{modified_files}"
  }

  modified_root_paths = `cat modified_root_paths.out | cut -d/ -f1 | uniq`
  modified_root_paths = modified_root_paths.split(/\n+/)
  puts "modified_root_paths: #{modified_root_paths.join(" ")}"

  root_modules = maven_module_list(".")
  modified_root_paths = modified_root_paths.delete_if { |item| root_modules.index(item) == nil }
  puts "modified_root_modules: #{modified_root_paths.join(" ")}"

  modified_root_paths.each do |root_path|
    modified_modules.push(root_path)

    maven_module_list(root_path, true).each do |sub_module|
      modified_modules.push("#{root_path}/#{sub_module}")
    end
  end

  modified_modules
end

# Verifies that the dependencies in the BOM match the dependencies in the rest
# of the project.
def verify_bom_dependencies
  bom_deps_arr = Array.new
  mod_deps_arr = Array.new

  # Get the BOM dependencies
  maven_dependencies("bom").each do |bom_dep|
    bom_deps_arr.push(bom_dep.to_s)
  end

  # Get each module's artifact information
  all_modules = maven_module_list(".", true)

  bom_index = all_modules.index('bom')
  all_modules.slice!(bom_index) unless bom_index == nil

  parent_index = all_modules.index('parent')
  all_modules.slice!(parent_index) unless parent_index == nil

  grandparent_index = all_modules.index('grandparent')
  all_modules.slice!(grandparent_index) unless grandparent_index == nil

  all_modules.each do |name|
    mod_deps_arr.push(maven_module_info(name).to_s)
  end

  # Sort the arrays
  bom_deps_arr = bom_deps_arr.sort
  mod_deps_arr = mod_deps_arr.sort

  # Compare the arrays

  bom_deps_arr.each do |bom_dep|
    #puts "bom: #{bom_dep}"
  end

  mod_deps_arr.each do |mod_dep|
    #puts "mod: #{mod_dep}"
  end

  bom_extras = bom_deps_arr - mod_deps_arr
  mod_extras = mod_deps_arr - bom_deps_arr

  if bom_extras.length > 0 || mod_extras.length > 0

    bom_deps_error = ""

    if bom_extras.length > 0
      bom_deps_error += "BOM contains unrecognized dependencies: [" + bom_extras.join(", ") + "]. "
    end

    if mod_extras.length > 0
      bom_deps_error += "BOM is missing dependencies: [" + mod_extras.join(", ") + "]."
    end

    begin
      raise ArgumentError, bom_deps_error
    end
  end

end

# Verifies that the BOM (and brightspot-parent for plugin) do not contain any
# SNAPSHOT versions for use when publishing a tag release.
def verify_no_release_snapshots

  bom_dependencies = maven_dependencies("bom")
  parent_plugins = maven_plugins("parent")

  bom_snapshots = bom_dependencies.keep_if { |item| item.version.to_s.end_with?("SNAPSHOT") }
  parent_snapshots = parent_plugins.keep_if { |item| item.version.to_s.end_with?("SNAPSHOT") }

  if bom_snapshots.length > 0 || parent_snapshots.length > 0

    release_snapshots_error=""

    if bom_snapshots.length > 0
      release_snapshots_error += "BOM contains snapshot dependencies: [" + bom_snapshots.join(", ") + "]. "
    end

    if parent_snapshots.length > 0
      release_snapshots_error += "parent contains snapshot plugins: [" + parent_snapshots.join(", ") + "]."
    end

    begin
      raise ArgumentError, release_snapshots_error
    end

  end

end

def system_stdout(command)
  puts "COMMAND: #{command}"
  system(command, out: $stdout, err: :out)
end

# One off function that ensures that the express archetype has correct versions
# in it since it's not updated automatically by the normal diff / versioning
# scripts.
def update_archetype_versions

  express_archetype_path = "express/archetype/src/main/resources/archetype-resources"

  if File.exist?(express_archetype_path)
    brightspot_mvn_version = maven_module_info("parent").version.to_s
    express_npm_version = JSON.parse(File.read('express/package.json'))['version']
    styleguide_npm_version = JSON.parse(File.read('styleguide/package.json'))['version']

    system_stdout("sed -i.bak 's|${brightspot-version}|'#{brightspot_mvn_version}'|g' #{express_archetype_path}/pom.xml")
    if $? != 0 then raise ArgumentError, "Failed to update archetype pom.xml!" end

    system_stdout("sed -i.bak 's|${express-version}|'#{express_npm_version}'|g; s|${styleguide-version}|'#{styleguide_npm_version}'|g' #{express_archetype_path}/package.json")
    if $? != 0 then raise ArgumentError, "Failed to update archetype package.json!" end

    puts "Updated express archetype dependency versions."
  else
    puts "Could not find express archetype."
  end

end

# Updates all build config files (pom.xml & package.json) to have their new release versions set.
def prepare_release_versions(commit_range, tag_version, pr_version, build_number)

  if commit_range != nil && !commit_range.to_s.strip.empty?
    module_paths = get_project_diff_list(commit_range)
  else
    module_paths = Array.new
    all_modules = maven_module_list('.', true)
    all_modules.each do |all_module|
      module_paths.push(all_module.to_s)
    end
  end

  prepare_maven_release_versions(module_paths, tag_version, pr_version, build_number)
  prepare_node_release_versions(module_paths, tag_version, pr_version, build_number)
  prepare_s3deploy_versions(module_paths)
end

# Update pom.xml release versions
def prepare_maven_release_versions(modified_modules, tag_version, pr_version, build_number)
  modified_artifacts = Set.new

  # Always add the root, parent, grandparent, and bom pom artifacts!
  modified_artifacts.add(maven_module_info('.'))
  modified_artifacts.add(maven_module_info('parent'))
  modified_artifacts.add(maven_module_info('grandparent'))
  modified_artifacts.add(maven_module_info('bom'))

  modified_modules.each do |modified_module|
    modified_artifacts.add(maven_module_info(modified_module))
  end

  all_modules = maven_module_list(".", true)
  # Always update the root pom
  all_modules.push('.')

  all_modules.each do |all_module|

    pom_modified = false
    pom = nil

    File.open("#{all_module}/pom.xml") do |pom_file|
      pom = Document.new(pom_file)

      XPath.each(pom, "//dependency | //plugin | //parent | /project") do |dep|

        group_id = XPath.first(dep, "groupId/text()")
        if group_id == nil && dep.name() == 'project'
          group_id = XPath.first(dep, "parent/groupId/text()")
        end

        artifact_id = XPath.first(dep, "artifactId/text()")
        version_elmt = XPath.first(dep, "version")

        modified_artifacts.each do |modified_artifact|

          if group_id == modified_artifact.group_id && artifact_id == modified_artifact.artifact_id && version_elmt != nil
            old_version = version_elmt.text
            release_version = module_release_version(modified_artifact.path, tag_version, pr_version, nil, false)

            if release_version != nil
              version_elmt.text = release_version
              pom_modified = true

              puts "Set #{all_module}/pom.xml #{dep.name()} #{group_id}:#{artifact_id}:#{old_version} to version #{release_version}."
            end
          end
        end
      end
    end

    if pom_modified
      formatter = REXML::Formatters::Default.new
      File.open("#{all_module}/pom.xml", 'w') do |f|
        formatter.write(pom, f)
      end
    end
  end
end

# Update package.json release versions
def prepare_node_release_versions(modified_modules, tag_version, pr_version, build_number)
  modified_modules.each do |modified_module|
    if File.file?("#{modified_module}/package.json")

      new_version = module_release_version(modified_module, tag_version, pr_version, build_number, true)

      if new_version != nil
        package_json = JSON.parse(File.read("#{modified_module}/package.json"))
        old_version = package_json['version']
        package_json['version'] = new_version

        puts "Set #{modified_module}/package.json version #{old_version} to #{new_version}."

        File.open("#{modified_module}/package.json", 'w') do |f|
          f.write(JSON.pretty_generate(package_json))
        end
      end
    end
  end
end

# Calculates the new version number for the maven artifact or node dependency
def module_release_version(module_path, tag_version, pr_version, build_number, is_node_module)

  if is_node_module
    package_json = JSON.parse(File.read("#{module_path}/package.json"))
    old_version = SemVersion.new(package_json['version'])
  else
    module_artifact = maven_module_info(module_path)
    old_version = SemVersion.new(module_artifact.version.to_s)
  end

  if !tag_version.to_s.strip.empty?

    # Remove leading v
    if tag_version.start_with?('v')
      tag_version = tag_version[1..-1]
    end

    if module_path == '' || module_path == '.' || module_path == 'bom' || module_path == 'parent' || module_path == 'grandparent'
      return tag_version
    else
      # foo/bar/baz/qux --> foo
      root_module_path = module_path.split(/\//, 2).first

      commit_count = `git rev-list --count HEAD -- #{root_module_path}`.to_s.strip
      commit_hash = `git rev-list HEAD -- #{root_module_path} | head -1`.to_s.strip[0, 6]

      return "#{old_version.major_number}.#{old_version.minor_number}.#{commit_count}-#{commit_hash}"
    end

  elsif !pr_version.to_s.strip.empty?
    if is_node_module
      return "#{old_version.major_number}.#{old_version.minor_number}.0-PR#{pr_version}.#{build_number}"
    else
      return "40.#{pr_version}-SNAPSHOT"
    end

  else
    if is_node_module
      return "#{old_version.major_number}.#{old_version.minor_number}.0-SNAPSHOT.#{build_number}"
    else
      return nil
    end
  end
end

# If an express version has not been set already (because it wasn't in the list
# of modified modules) then explicitly sets the express/site/pom.xml parent
# to point to the current brightspot-parent (bypassing express-parent) to ensure
# that the s3deploy function builds the express site WAR with the local
# dependencies from this build.
def prepare_s3deploy_versions(modified_modules)

  unless modified_modules.include?('express/site')

    File.open('parent/pom.xml') do |parent_pom_file|

      parent_pom = Document.new(parent_pom_file)

      parent_group_id = XPath.first(parent_pom, '/project/groupId/text()')
      if parent_group_id == nil
        parent_group_id = XPath.first(parent_pom, '/project/parent/groupId/text()')
      end

      parent_artifact_id = XPath.first(parent_pom, '/project/artifactId/text()')
      parent_version = XPath.first(parent_pom, '/project/version/text()')

      File.open('express/site/pom.xml') do |express_site_pom_file|

        express_site_pom = Document.new(express_site_pom_file)

        express_site_group_id_elmt = XPath.first(express_site_pom, '/project/parent/groupId')
        express_site_artifact_id_elmt = XPath.first(express_site_pom, '/project/parent/artifactId')
        express_site_version_elmt = XPath.first(express_site_pom, '/project/parent/version')
        express_site_relative_path_elmt = XPath.first(express_site_pom, '/project/parent/relativePath')

        express_site_group_id_elmt.text = parent_group_id
        express_site_artifact_id_elmt.text = parent_artifact_id
        express_site_version_elmt.text = parent_version
        express_site_relative_path_elmt.text = '../../parent/pom.xml'

        File.open('express/site/pom.xml', 'w') do |f|
          formatter = REXML::Formatters::Default.new
          formatter.write(express_site_pom, f)
        end

        puts "Set express/site/pom.xml parent to #{parent_group_id}:#{parent_artifact_id}:#{parent_version} for S3 Deploy."
      end
    end
  end
end

# Deploys the express/site WAR file to S3 to power the /_deploy servlet.
def s3deploy
  system_stdout('mvn -f express/site/pom.xml clean package'\
            ' -B'\
            ' -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn'\
            ' -Dmaven.test.skip=false')

  if $? != 0 then raise ArgumentError, 'Failed to compile the Express Site WAR file for S3 deploy!' end

  ENV['DEPLOY_SOURCE_DIR'] = "#{ENV['TRAVIS_BUILD_DIR']}/express/site/target"

  system_stdout('git clone https://github.com/perfectsense/travis-s3-deploy.git')
  if $? != 0 then raise ArgumentError, 'Failed to clone travis-s3-deploy repo!' end

  system_stdout('travis-s3-deploy/deploy.sh')
  if $? != 0 then raise ArgumentError, 'Failed to deploy to S3!' end
end

def sonar_goals(phases)
  ENV["SONAR_TOKEN"] ? "org.jacoco:jacoco-maven-plugin:prepare-agent #{phases} sonar:sonar" : phases
end

def deploy

  puts "REBUILD: " + (ENV["REBUILD"] || "")
  puts "TRAVIS_COMMIT_RANGE: " + (ENV["TRAVIS_COMMIT_RANGE"] || "")
  puts "TRAVIS_TAG: " + (ENV["TRAVIS_TAG"] || "")
  puts "TRAVIS_REPO_SLUG: " + (ENV["TRAVIS_REPO_SLUG"] || "")
  puts "TRAVIS_PULL_REQUEST: " + (ENV["TRAVIS_PULL_REQUEST"] || "")
  puts "TRAVIS_BRANCH: " + (ENV["TRAVIS_BRANCH"] || "")

  ENV["MAVEN_OPTS"] = "-Xmx2g"

  rebuild = ENV["REBUILD"].to_s.casecmp("true") == 0
  commit_range = ENV["TRAVIS_COMMIT_RANGE"]
  tag_version = ENV["TRAVIS_TAG"]
  pr_version = ENV["TRAVIS_PULL_REQUEST"].to_s.eql?("false") ? '' : ENV["TRAVIS_PULL_REQUEST"]
  build_number = ENV["TRAVIS_BUILD_NUMBER"]

  if ENV["TRAVIS_REPO_SLUG"].to_s.start_with?("perfectsense/")

    if not ENV["TRAVIS_TAG"].to_s.strip.empty?
      puts 'Preparing RELEASE version...'

      prepare_release_versions(commit_range, tag_version, pr_version, build_number)
      update_archetype_versions
      verify_no_release_snapshots
      verify_bom_dependencies

      system_stdout('mvn clean install'\
            ' -B'\
            ' -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn'\
            ' -Plibrary'\
            ' -Dmaven.test.skip=false')

      if $? != 0 then raise ArgumentError, 'Failed to install release!' end

      newly_versioned_modules = get_newly_versioned_modules

      puts "newly_versioned_modules: #{newly_versioned_modules.join(' ')}"

      if newly_versioned_modules.length > 0
        puts "Deploying #{newly_versioned_modules.length} artifacts to artifactory."

        system_stdout("DEPLOY_SKIP_UPLOAD=#{DEBUG_SKIP_UPLOAD}"\
                ' DEPLOY=true'\
                ' mvn deploy'\
                ' -B'\
                ' -Dmaven.test.skip=true'\
                ' -DdeployAtEnd=false'\
                " -Dmaven.deploy.skip=#{DEBUG_SKIP_UPLOAD}"\
                ' --settings=$(dirname $(pwd)/$0)/etc/settings.xml'\
                ' -Pdeploy'\
                " -pl #{newly_versioned_modules.join(",")}")

        if $? != 0 then raise ArgumentError, 'Failed to deploy release!' end

        s3deploy
      else
        puts 'Nothing new to deploy to artifactory.'
      end

    else
      if ENV["TRAVIS_PULL_REQUEST"].to_s.eql?('false')

        if ENV["TRAVIS_BRANCH"].to_s.start_with?('release/*') ||
            ENV["TRAVIS_BRANCH"].to_s.eql?('master')

          puts 'Deploying SNAPSHOT to Maven repository...'

          prepare_release_versions(commit_range, tag_version, pr_version, build_number)
          update_archetype_versions
          verify_bom_dependencies

          system_stdout("DEPLOY_SKIP_UPLOAD=#{DEBUG_SKIP_UPLOAD}"\
              ' DEPLOY=true'\
              " mvn #{sonar_goals('deploy')}"\
              ' -B'\
              ' -Dmaven.test.skip=false'\
              ' -DdeployAtEnd=false'\
              " -Dmaven.deploy.skip=#{DEBUG_SKIP_UPLOAD}"\
              ' --settings=$(dirname $(pwd)/$0)/etc/settings.xml'\
              ' -Pdeploy')

          if $? != 0 then raise ArgumentError, 'Failed to deploy SNAPSHOT to artifactory!' end

          s3deploy

        else
          puts 'Branch is not associated with a PR, nothing to do...'
        end

      else
        modified_modules = get_project_diff_list(commit_range)
        puts "modified_modules: #{modified_modules.join(" ")}"

        if modified_modules.length > 0
          puts 'Preparing pull request...'

          prepare_release_versions(commit_range, tag_version, '', build_number)
          update_archetype_versions
          verify_bom_dependencies

          puts 'Building pull request...'

          system_stdout(
                " mvn #{sonar_goals('install')}"\
                ' -B'\
                ' -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn'\
                ' -Plibrary'\
                ' -Dmaven.test.skip=false'\
                " -pl .,parent,bom,grandparent,#{modified_modules.join(',')}")

          if $? != 0 then raise ArgumentError, 'Failed to build pull request!' end

          s3deploy
        else
          puts 'No modules to build...'
        end

      end

    end

  end

end

if __FILE__ == $0
  deploy
end
