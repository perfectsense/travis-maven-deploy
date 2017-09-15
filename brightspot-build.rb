#!/usr/bin/ruby -w

require 'rexml/document'
include REXML

$stdout.sync = true

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

ARTIFACTORY_URL_PREFIX = "https://artifactory.psdops.com/psddev-releases"

def maven_xpath(module_path, expr)
  list = maven_xpath_list(module_path, expr)
  list.each do |item|
    return item
  end
  nil
end

def maven_xpath_list(module_path, expr)
  xmlfile = File.new("#{module_path}/pom.xml")
  xmldoc = Document.new(xmlfile)

  XPath.each(xmldoc, "#{expr}/text()")
end

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

def maven_module_list(path, recurse = false)

  module_list = Array.new

  maven_xpath_list(path, "/project/modules/module").each do |name|

    module_list.push(name)

    if recurse
      maven_module_list("#{path}/#{name}", true).each do |name2|
        module_list.push("#{name}/#{name2}")
      end
    end
  end

  module_list
end

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

def maven_artifactory_status(maven_artifact)

  maven_artifact = maven_module_info(maven_artifact) unless maven_artifact.respond_to?("group_id")
  ma = maven_artifact

  artifactory_url = "#{ARTIFACTORY_URL_PREFIX}/#{ma.group_id.to_s.gsub(".", "/")}/#{ma.artifact_id}/#{ma.version}/#{ma.artifact_id}-#{ma.version}.pom"

  puts "Fetching: " + artifactory_url

  artifactory_status = `curl -s -I "#{artifactory_url}" | head -n 1 | cut -d$' ' -f2`

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

def get_project_diff_list(commit_range)

  modified_modules = Array.new

  commit_range = commit_range.gsub("...", "..")

  modified_files = `git diff-tree -m -r --no-commit-id --name-only #{commit_range}`

  modified_root_paths = `echo "#{modified_files}" | cut -d/ -f1 | uniq`
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

def build

  puts "TRAVIS_COMMIT_RANGE: " + (ENV["TRAVIS_COMMIT_RANGE"] || "")
  puts "TRAVIS_TAG: " + (ENV["TRAVIS_TAG"] || "")
  puts "TRAVIS_REPO_SLUG: " + (ENV["TRAVIS_REPO_SLUG"] || "")
  puts "TRAVIS_PULL_REQUEST: " + (ENV["TRAVIS_PULL_REQUEST"] || "")
  puts "TRAVIS_BRANCH: " + (ENV["TRAVIS_BRANCH"] || "")

  ENV["MAVEN_OPTS"] = "-Xmx3000m -XX:MaxDirectMemorySize=2000m"

  if ENV["TRAVIS_REPO_SLUG"].to_s.start_with?("perfectsense/")

    if not ENV["TRAVIS_TAG"].to_s.strip.empty?
      puts "Preparing RELEASE version..."

      system("git fetch --unshallow", out: $stdout, err: :out)
      system("touch BSP_ROOT", out: $stdout, err: :out)
      system("touch TAG_VERSION bom/TAG_VERSION parent/TAG_VERSION grandparent/TAG_VERSION", out: $stdout, err: :out)

      system("mvn -B -Dtravis.tag=#{ENV["TRAVIS_TAG"]} -Pprepare-release initialize", out: $stdout, err: :out)
      if $? != 0 then raise ArgumentError, "Failed to prepare release!" end

      system("mvn -B clean install", out: $stdout, err: :out)
      if $? != 0 then raise ArgumentError, "Failed to install release!" end

      verify_no_release_snapshots
      verify_bom_dependencies

      newly_versioned_modules = get_newly_versioned_modules

      puts "newly_versioned_modules: #{newly_versioned_modules.join(" ")}"

      if newly_versioned_modules.length > 0
        puts "Deploying #{newly_versioned_modules.length} artifacts to artifactory."

        system("mvn -B --settings=$(dirname $(pwd)/$0)/settings.xml -Pdeploy deploy -pl #{newly_versioned_modules.join(",")}", out: $stdout, err: :out)
        if $? != 0 then raise ArgumentError, "Failed to deploy release!" end

      else
        puts "Nothing new to deploy to artifactory."
      end

    else
      system("mvn -B clean install -pl .,parent,bom,grandparent", out: $stdout, err: :out)
      if $? != 0 then raise ArgumentError, "Failed to prepare snapshot build!" end

      if ENV["TRAVIS_PULL_REQUEST"].to_s.eql?("false")

        if ENV["TRAVIS_BRANCH"].to_s.start_with?("release/*") ||
            ENV["TRAVIS_BRANCH"].to_s.start_with?("path/*") ||
            ENV["TRAVIS_BRANCH"].to_s.eql?("develop") ||
            ENV["TRAVIS_BRANCH"].to_s.eql?("master")

          modified_modules = get_project_diff_list(ENV["TRAVIS_COMMIT_RANGE"])
          puts "modified_modules: #{modified_modules.join(" ")}"

          if modified_modules.length > 0
            puts "Deploying SNAPSHOT to Maven repository..."
            system("mvn -B --settings=$(dirname $(pwd)/$0)/settings.xml -Pdeploy deploy -pl #{modified_modules.join(",")}", out: $stdout, err: :out)
            if $? != 0 then raise ArgumentError, "Failed to deploy SNAPSHOT to artifactory!" end

          else
            puts "No modules to deploy..."
          end

        else
          puts "Branch is not associated with a PR, nothing to do..."
        end

      else
        modified_modules = get_project_diff_list(ENV["TRAVIS_COMMIT_RANGE"])
        puts "modified_modules: #{modified_modules.join(" ")}"

        if modified_modules.length > 0
          puts "Building pull request..."
          system("mvn -B clean install -pl #{modified_modules.join(",")}", out: $stdout, err: :out)
          if $? != 0 then raise ArgumentError, "Failed to build pull request!" end

        else
          puts "No modules to build..."
        end

      end

    end

  end

end

if __FILE__ == $0
  build
end
