cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Define the application target.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "../../shared_native/process_security.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Define the bridge library target.
add_library(bridge SHARED
  "bridge.cpp"
  "../../shared_native/process_security.cc"
)

# Apply the standard set of build settings.
apply_standard_settings(${BINARY_NAME})
apply_standard_settings(bridge)

target_compile_definitions(${BINARY_NAME} PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:DEPLOYDASH_RELEASE_HARDENING=1>")
target_compile_definitions(bridge PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:DEPLOYDASH_RELEASE_HARDENING=1>")

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")
add_definitions(-DAPP_DISPLAY_NAME="${APP_DISPLAY_NAME}")

# Add dependency libraries.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_link_libraries(bridge PRIVATE PkgConfig::PYTHON)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(bridge PRIVATE "${CMAKE_SOURCE_DIR}")

# Set RPATH for bridge so it can find libpython in the same directory
set_target_properties(bridge PROPERTIES
  INSTALL_RPATH "$ORIGIN"
)

# Ensure the bridge library is built and copied to the bundle.
add_dependencies(${BINARY_NAME} bridge)
