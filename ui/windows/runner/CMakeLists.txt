cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "../../shared_native/process_security.cc"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

add_library(bridge SHARED
  "bridge.cpp"
  "../../shared_native/process_security.cc"
)
apply_standard_settings(bridge)

target_compile_definitions(${BINARY_NAME} PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:DEPLOYDASH_RELEASE_HARDENING=1>")
target_compile_definitions(bridge PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:DEPLOYDASH_RELEASE_HARDENING=1>")
target_compile_options(${BINARY_NAME} PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/guard:cf>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/Zi>")
target_compile_options(bridge PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/guard:cf>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/Zi>")
target_link_options(${BINARY_NAME} PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/guard:cf>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/DEBUG>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/DYNAMICBASE>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/HIGHENTROPYVA>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/NXCOMPAT>")
target_link_options(bridge PRIVATE
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/guard:cf>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/DEBUG>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/DYNAMICBASE>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/HIGHENTROPYVA>"
  "$<$<OR:$<CONFIG:Profile>,$<CONFIG:Release>>:/NXCOMPAT>")

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE "_WIN32_WINNT=0x0A00")
target_compile_definitions(bridge PRIVATE "NOMINMAX" "_WIN32_WINNT=0x0A00")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(bridge PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
add_dependencies(${BINARY_NAME} bridge)
