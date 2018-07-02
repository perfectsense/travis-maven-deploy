#!/usr/bin/ruby -w

require 'rexml/document'
require 'json'
include REXML

$stdout.sync = true

# Gets the list of modules defined in the pom.xml at the given path. This
# function can optionally recurse down to sub-modules.
def maven_module_list(path, recurse = false)

  module_list = Array.new

  XPath.each(Document.new(File.new("#{path}/pom.xml")), '/project/modules/module/text()').each do |name|

    module_list.push(name.to_s)

    if recurse
      maven_module_list("#{path}/#{name}", true).each do |name2|
        module_list.push("#{name}/#{name2}")
      end
    end
  end

  module_list
end

def check_dependencies

  maven_modules = maven_module_list('.', true)

  dep_mgmt_check_failed = false
  dep_version_check_failed = false

  maven_modules.each do |maven_module|

    xmldoc = Document.new(File.new("#{maven_module}/pom.xml"))

    # 1. Check for dependencyManagement sections.
    #    a) Only the bom, parent and dari/grandparent should have dependencyManagement sections.
    #    b) The parent should only contain the com.psddev:brightspot-bom dependency in its dependencyManagement section.

    dep_mgmt_count = XPath.each(xmldoc, '/project/dependencyManagement').count

    if dep_mgmt_count > 0

      if maven_module == 'parent'
        XPath.each(xmldoc, '/project/dependencyManagement/dependencies/dependency').each do |dep|
          group_id = XPath.first(dep, 'groupId/text()')
          artifact_id = XPath.first(dep, 'artifactId/text()')

          if group_id != 'com.psddev' || artifact_id != 'brightspot-bom'
            dep_mgmt_check_failed = true
            puts "ERROR: #{maven_module}/pom.xml contains dependency #{group_id}:#{artifact_id}."
          end
        end

      elsif maven_module != 'bom' && maven_module != 'dari/grandparent'
        puts "ERROR: #{maven_module}/pom.xml contains dependencyManagement section."
        dep_mgmt_check_failed = true
      end

    end

    # 2. Check for dependency versions.
    #    a) Dependency versions should ONLY be defined in dependencyManagement sections.

    version_count = XPath.each(xmldoc, '/project/dependencies/dependency/version').count
    if version_count > 0
      puts "ERROR: #{maven_module}/pom.xml contains dependency version."
      dep_version_check_failed = true
    end

  end

  if dep_mgmt_check_failed || dep_version_check_failed

    if dep_mgmt_check_failed
      puts 'Please move all dependencies in <dependencyManagement> into dari/grandparent/pom.xml'
    end

    if dep_version_check_failed
      puts 'Please define all dependency versions inside <dependencyManagement> in dari/grandparent/pom.xml'
    end

    exit 1
  end

end

if __FILE__ == $0
  check_dependencies
end
