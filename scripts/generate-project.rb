#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
APP_NAME = "FileFlip"
APP_CATEGORY = "public.app-category.utilities"
APP_VERSION = "0.2.3"
APP_BUILD_NUMBER = "1"
PROJECT_PATH = File.join(ROOT, "#{APP_NAME}.xcodeproj")
SPARKLE_VERSION = "2.9.5"
MACOS_DEPLOYMENT_TARGET = "15.0"
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

def add_asset_catalog(project, group_name, path, target)
  group = project.main_group.find_subpath(group_name, true)
  reference = group.new_file(path.sub(ROOT + "/", ""))
  reference.last_known_file_type = "folder.assetcatalog"
  target.resources_build_phase.add_file_reference(reference)
end

def configure(target, bundle_id)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["MACOSX_DEPLOYMENT_TARGET"] = MACOS_DEPLOYMENT_TARGET
    settings["SWIFT_VERSION"] = "6.0"
    settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["ARCHS"] = "arm64"
    settings["ONLY_ACTIVE_ARCH"] = "YES"
  end
end

core = project.new_target(:framework, "FileConvertCore", :osx, MACOS_DEPLOYMENT_TARGET)
providers = project.new_target(:framework, "FileConvertProviders", :osx, MACOS_DEPLOYMENT_TARGET)
evidence = project.new_target(:framework, "FileConvertEvidence", :osx, MACOS_DEPLOYMENT_TARGET)
app = project.new_target(:application, "FileConvertApp", :osx, MACOS_DEPLOYMENT_TARGET)
core_tests = project.new_target(:unit_test_bundle, "FileConvertCoreTests", :osx, MACOS_DEPLOYMENT_TARGET)
provider_tests = project.new_target(:unit_test_bundle, "FileConvertProvidersTests", :osx, MACOS_DEPLOYMENT_TARGET)
evidence_tests = project.new_target(:unit_test_bundle, "FileConvertEvidenceTests", :osx, MACOS_DEPLOYMENT_TARGET)
integration_tests = project.new_target(:unit_test_bundle, "FileConvertIntegrationTests", :osx, MACOS_DEPLOYMENT_TARGET)
ui_tests = project.new_target(:ui_test_bundle, "FileConvertUITests", :osx, MACOS_DEPLOYMENT_TARGET)
app_tests = project.new_target(:unit_test_bundle, "FileConvertAppTests", :osx, MACOS_DEPLOYMENT_TARGET)
sparkle_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sparkle_package.repositoryURL = "https://github.com/sparkle-project/Sparkle"
sparkle_package.requirement = { "kind" => "exactVersion", "version" => SPARKLE_VERSION }
project.root_object.package_references << sparkle_package
sparkle_product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
sparkle_product.package = sparkle_package
sparkle_product.product_name = "Sparkle"
app.package_product_dependencies << sparkle_product
sparkle_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
sparkle_build_file.product_ref = sparkle_product
app.frameworks_build_phase.files << sparkle_build_file

configure(core, "app.fileconvert.FileConvertCore")
configure(providers, "app.fileconvert.FileConvertProviders")
configure(evidence, "app.fileconvert.FileConvertEvidence")
configure(app, "com.chasedputnam.FileFlip")
configure(core_tests, "app.fileconvert.FileConvertCoreTests")
configure(provider_tests, "app.fileconvert.FileConvertProvidersTests")
configure(evidence_tests, "app.fileconvert.FileConvertEvidenceTests")
configure(integration_tests, "app.fileconvert.FileConvertIntegrationTests")
configure(ui_tests, "app.fileconvert.FileConvertUITests")
configure(app_tests, "app.fileconvert.FileConvertAppTests")

app.build_configurations.each do |configuration|
  configuration.build_settings["INFOPLIST_FILE"] = "Config/FileConvertApp-Info.plist"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  configuration.build_settings["PRODUCT_NAME"] = APP_NAME
  configuration.build_settings["PRODUCT_MODULE_NAME"] = "FileConvertApp"
  configuration.build_settings["MARKETING_VERSION"] = APP_VERSION
  configuration.build_settings["CURRENT_PROJECT_VERSION"] = APP_BUILD_NUMBER
  configuration.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = APP_NAME
  configuration.build_settings["INFOPLIST_KEY_LSApplicationCategoryType"] = APP_CATEGORY
  configuration.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  configuration.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  configuration.build_settings["DEVELOPMENT_TEAM"] = "C5C4W9B7FS"

end
[core, providers, evidence].each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings["DEFINES_MODULE"] = "YES"
    configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
    configuration.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  end
end
[core_tests, provider_tests, evidence_tests, integration_tests, app_tests, ui_tests].each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
    configuration.build_settings["ENABLE_HARDENED_RUNTIME"] = "NO"
    configuration.build_settings["TEST_TARGET_NAME"] = "FileConvertApp" if [app_tests, ui_tests].include?(target)
  end
end
app_tests.build_configurations.each do |configuration|
  configuration.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  configuration.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/#{APP_NAME}.app/Contents/MacOS/#{APP_NAME}"
end

providers.add_dependency(core)
evidence.add_dependency(core)
evidence.add_dependency(providers)
app.add_dependency(core)
app.add_dependency(providers)
core_tests.add_dependency(core)
provider_tests.add_dependency(providers)
evidence_tests.add_dependency(evidence)
evidence_tests.add_dependency(core)
evidence_tests.add_dependency(providers)
integration_tests.add_dependency(core)
integration_tests.add_dependency(providers)
integration_tests.add_dependency(evidence)
ui_tests.add_dependency(app)
app_tests.add_dependency(app)
app_tests.add_dependency(core)


def embed_frameworks(target, frameworks)
  phase = target.new_copy_files_build_phase("Embed Frameworks")
  phase.dst_subfolder_spec = "10"
  frameworks.each do |framework|
    build_file = phase.add_file_reference(framework.product_reference, true)
    build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
  end
end

embed_frameworks(app, [core, providers])

add_tree(project, "Sources/FileConvertCore", File.join(ROOT, "Sources/FileConvertCore"), core)
add_tree(project, "Sources/FileConvertProviders", File.join(ROOT, "Sources/FileConvertProviders"), providers)
add_tree(project, "Sources/FileConvertEvidence", File.join(ROOT, "Sources/FileConvertEvidence"), evidence)
add_tree(project, "Sources/FileConvertApp", File.join(ROOT, "Sources/FileConvertApp"), app)
add_folder_resource(project, "MediaTools", File.join(ROOT, "Sources/FileConvertApp/Resources/MediaTools"), app)
add_asset_catalog(project, "Assets", File.join(ROOT, "Sources/FileConvertApp/Resources/Assets.xcassets"), app)
add_tree(project, "Tests/FileConvertCoreTests", File.join(ROOT, "Tests/FileConvertCoreTests"), core_tests)
add_tree(project, "Tests/FileConvertProvidersTests", File.join(ROOT, "Tests/FileConvertProvidersTests"), provider_tests)
add_tree(project, "ImageFixtures", File.join(ROOT, "Tests/FileConvertProvidersTests/Fixtures"), provider_tests, phase: :resources)
add_tree(project, "Tests/FileConvertEvidenceTests", File.join(ROOT, "Tests/FileConvertEvidenceTests"), evidence_tests)
add_tree(project, "Tests/FileConvertIntegrationTests", File.join(ROOT, "Tests/FileConvertIntegrationTests"), integration_tests)
add_tree(project, "Tests/FileConvertUITests", File.join(ROOT, "Tests/FileConvertUITests"), ui_tests)
add_tree(project, "Tests/FileConvertAppTests", File.join(ROOT, "Tests/FileConvertAppTests"), app_tests)

media_signing_phase = app.new_shell_script_build_phase("Sign Media Tools")
media_signing_phase.always_out_of_date = "1"
media_signing_phase.shell_path = "/bin/bash"
media_signing_phase.shell_script = <<~'SCRIPT'
  set -euo pipefail

  if [[ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]]; then
    exit 0
  fi
  if [[ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    echo "error: Media tools require a signing identity" >&2
    exit 1
  fi

  tools_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/MediaTools"
  manifest="${tools_directory}/manifest.json"
  if [[ ! -f "${manifest}" ]]; then
    echo "error: Missing bundled media tool manifest: ${manifest}" >&2
    exit 1
  fi
  expected_team_identifier="C5C4W9B7FS"
  artifact_index=0
  for executable_name in ffmpeg ffprobe; do
    executable="${tools_directory}/${executable_name}"
    if [[ ! -f "${executable}" ]]; then
      echo "error: Missing bundled media tool: ${executable}" >&2
      exit 1
    fi
    manifest_name=$(/usr/bin/plutil -extract "artifacts.${artifact_index}.name" raw "${manifest}")
    if [[ "${manifest_name}" != "${executable_name}" ]]; then
      echo "error: Bundled media tool manifest order is invalid" >&2
      exit 1
    fi
    /usr/bin/codesign \
      --force \
      --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
      --options runtime \
      "${executable}"
    if [[ "${EXPANDED_CODE_SIGN_IDENTITY}" == "-" ]]; then
      signed_sha256=$(/usr/bin/shasum -a 256 "${executable}" | /usr/bin/cut -d ' ' -f 1)
      /usr/bin/plutil -replace "artifacts.${artifact_index}.sha256" -string "${signed_sha256}" "${manifest}"
      /usr/bin/plutil -replace "artifacts.${artifact_index}.signature.mode" -string adhoc "${manifest}"
      /usr/bin/plutil -remove "artifacts.${artifact_index}.signature.teamIdentifier" "${manifest}" 2>/dev/null || true
    else
      if [[ "${DEVELOPMENT_TEAM:-}" != "${expected_team_identifier}" ]]; then
        echo "error: Media tools must be signed by team ${expected_team_identifier}" >&2
        exit 1
      fi
      /usr/bin/plutil -remove "artifacts.${artifact_index}.sha256" "${manifest}"
      /usr/bin/plutil -replace "artifacts.${artifact_index}.signature.mode" -string identity "${manifest}"
      /usr/bin/plutil -remove "artifacts.${artifact_index}.signature.teamIdentifier" "${manifest}" 2>/dev/null || true
      /usr/bin/plutil -insert "artifacts.${artifact_index}.signature.teamIdentifier" -string "${expected_team_identifier}" "${manifest}"
    fi
    artifact_index=$((artifact_index + 1))
  done
SCRIPT

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(core)
scheme.add_build_target(providers)
scheme.add_test_target(core_tests)
scheme.add_test_target(provider_tests)
scheme.add_test_target(evidence_tests)
scheme.add_test_target(integration_tests)
scheme.add_test_target(app_tests)
scheme.add_test_target(ui_tests)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, APP_NAME, true)


project.save
puts "Generated #{PROJECT_PATH}"
