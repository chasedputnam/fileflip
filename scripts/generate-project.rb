#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "FileFlip.xcodeproj")
FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2660"
project.root_object.attributes["LastUpgradeCheck"] = "2660"

def add_tree(project, group_name, path, target, phase: :sources)
  group = project.main_group.find_subpath(group_name, true)
  Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.each do |entry|
    next unless File.file?(entry)
    reference = group.new_file(entry.sub(ROOT + "/", ""))
    case phase
    when :sources then target.add_file_references([reference]) if entry.end_with?(".swift")
    when :resources then target.resources_build_phase.add_file_reference(reference)
    end
  end
end

def add_folder_resource(project, group_name, path, target)
  group = project.main_group.find_subpath(group_name, true)
  reference = group.new_file(path.sub(ROOT + "/", ""))
  reference.last_known_file_type = "folder"
  target.resources_build_phase.add_file_reference(reference)
end

def configure(target, bundle_id)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    settings["SWIFT_VERSION"] = "6.0"
    settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["ENABLE_HARDENED_RUNTIME"] = "YES"
    settings["ARCHS"] = "arm64"
    settings["ONLY_ACTIVE_ARCH"] = "YES"
  end
end

core = project.new_target(:framework, "FileConvertCore", :osx, "14.0")
providers = project.new_target(:framework, "FileConvertProviders", :osx, "14.0")
app = project.new_target(:application, "FileConvertApp", :osx, "14.0")
core_tests = project.new_target(:unit_test_bundle, "FileConvertCoreTests", :osx, "14.0")
provider_tests = project.new_target(:unit_test_bundle, "FileConvertProvidersTests", :osx, "14.0")
integration_tests = project.new_target(:unit_test_bundle, "FileConvertIntegrationTests", :osx, "14.0")
ui_tests = project.new_target(:ui_test_bundle, "FileConvertUITests", :osx, "14.0")
app_tests = project.new_target(:unit_test_bundle, "FileConvertAppTests", :osx, "14.0")

configure(core, "app.fileconvert.FileConvertCore")
configure(providers, "app.fileconvert.FileConvertProviders")
configure(app, "app.fileconvert.FileConvert")
configure(core_tests, "app.fileconvert.FileConvertCoreTests")
configure(provider_tests, "app.fileconvert.FileConvertProvidersTests")
configure(integration_tests, "app.fileconvert.FileConvertIntegrationTests")
configure(ui_tests, "app.fileconvert.FileConvertUITests")
configure(app_tests, "app.fileconvert.FileConvertAppTests")

app.build_configurations.each do |configuration|
  configuration.build_settings["INFOPLIST_FILE"] = "Config/FileConvertApp-Info.plist"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  configuration.build_settings["PRODUCT_NAME"] = "FileFlip"
  configuration.build_settings["PRODUCT_MODULE_NAME"] = "FileConvertApp"
end
[core, providers].each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings["DEFINES_MODULE"] = "YES"
    configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  end
end
[core_tests, provider_tests, integration_tests, app_tests, ui_tests].each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
    configuration.build_settings["ENABLE_HARDENED_RUNTIME"] = "NO"
    configuration.build_settings["TEST_TARGET_NAME"] = "FileConvertApp" if [app_tests, ui_tests].include?(target)
  end
end
app_tests.build_configurations.each do |configuration|
  configuration.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  configuration.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/FileFlip.app/Contents/MacOS/FileFlip"
end

providers.add_dependency(core)
app.add_dependency(core)
app.add_dependency(providers)
core_tests.add_dependency(core)
provider_tests.add_dependency(providers)
integration_tests.add_dependency(core)
integration_tests.add_dependency(providers)
ui_tests.add_dependency(app)
app_tests.add_dependency(app)
app_tests.add_dependency(core)


embed_frameworks = app.new_copy_files_build_phase("Embed Frameworks")
embed_frameworks.dst_subfolder_spec = "10"
[core, providers].each do |framework|
  build_file = embed_frameworks.add_file_reference(framework.product_reference, true)
  build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

add_tree(project, "Sources/FileConvertCore", File.join(ROOT, "Sources/FileConvertCore"), core)
add_tree(project, "Sources/FileConvertProviders", File.join(ROOT, "Sources/FileConvertProviders"), providers)
add_tree(project, "Sources/FileConvertApp", File.join(ROOT, "Sources/FileConvertApp"), app)
add_folder_resource(project, "MediaTools", File.join(ROOT, "Sources/FileConvertApp/Resources/MediaTools"), app)
add_tree(project, "Tests/FileConvertCoreTests", File.join(ROOT, "Tests/FileConvertCoreTests"), core_tests)
add_tree(project, "Tests/FileConvertProvidersTests", File.join(ROOT, "Tests/FileConvertProvidersTests"), provider_tests)
add_tree(project, "ImageFixtures", File.join(ROOT, "Tests/FileConvertProvidersTests/Fixtures"), provider_tests, phase: :resources)
add_tree(project, "Tests/FileConvertIntegrationTests", File.join(ROOT, "Tests/FileConvertIntegrationTests"), integration_tests)
add_tree(project, "Tests/FileConvertUITests", File.join(ROOT, "Tests/FileConvertUITests"), ui_tests)
add_tree(project, "Tests/FileConvertAppTests", File.join(ROOT, "Tests/FileConvertAppTests"), app_tests)

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(core)
scheme.add_build_target(providers)
scheme.add_test_target(core_tests)
scheme.add_test_target(provider_tests)
scheme.add_test_target(integration_tests)
scheme.add_test_target(app_tests)
scheme.add_test_target(ui_tests)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, "FileFlip", true)

project.save
puts "Generated #{PROJECT_PATH}"
