# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "deploydash")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.deploydash.desktop")
set(APP_DISPLAY_NAME "Deploy Dash")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# --- Python 3.13 Setup via uv ---
execute_process(
  COMMAND uv python find 3.13
  OUTPUT_VARIABLE PYTHON_INTERPRETER_PATH
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(NOT PYTHON_INTERPRETER_PATH)
  message(FATAL_ERROR "uv could not find a Python 3.13 interpreter.")
endif()

# Prefer Python's reported base prefix so virtualenv wrappers don't break
# pkg-config discovery for python-3.13-embed.
execute_process(
  COMMAND "${PYTHON_INTERPRETER_PATH}" -c "import sys; print(sys.base_prefix)"
  OUTPUT_VARIABLE PYTHON_BASE_PREFIX
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(PYTHON_BASE_PREFIX)
  set(PYTHON_ROOT_DIR "${PYTHON_BASE_PREFIX}")
else()
  # Fallback: resolve through symlinks and derive /path/to from /path/to/bin/python3.13.
  get_filename_component(PYTHON_INTERPRETER_REALPATH ${PYTHON_INTERPRETER_PATH} REALPATH)
  get_filename_component(PYTHON_BIN_DIR ${PYTHON_INTERPRETER_REALPATH} DIRECTORY)
  get_filename_component(PYTHON_ROOT_DIR ${PYTHON_BIN_DIR} DIRECTORY)
endif()

message(STATUS "Found Python 3.13 Root: ${PYTHON_ROOT_DIR}")

# Set PKG_CONFIG_PATH to find this specific python
set(ENV{PKG_CONFIG_PATH}
  "${PYTHON_ROOT_DIR}/lib/pkgconfig:${PYTHON_ROOT_DIR}/lib64/pkgconfig:$ENV{PKG_CONFIG_PATH}")

pkg_check_modules(PYTHON REQUIRED IMPORTED_TARGET python-3.13-embed)
# --------------------------------

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Prepare orchestrator package artifacts for runtime bundle. The current
# checkout is built into a wheel by default so the desktop and backend sources
# cannot drift. Published-package mode remains an explicit release option.
set(ENGINE_BACKEND_ROOT "$ENV{DEPLOYDASH_ORCHESTRATOR_ROOT}")
if(ENGINE_BACKEND_ROOT STREQUAL "")
  set(ENGINE_BACKEND_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../orchestrator")
elseif(NOT IS_ABSOLUTE "${ENGINE_BACKEND_ROOT}")
  get_filename_component(
    ENGINE_BACKEND_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../${ENGINE_BACKEND_ROOT}"
    ABSOLUTE
  )
endif()

if(NOT EXISTS "${ENGINE_BACKEND_ROOT}")
  message(FATAL_ERROR "Backend app root not found: ${ENGINE_BACKEND_ROOT}")
endif()

set(ENGINE_BACKEND_PREP_SCRIPT "${ENGINE_BACKEND_ROOT}/scripts/prepare_desktop_runtime_bundle.sh")
set(ENGINE_BACKEND_RUNTIME_BUNDLE_DIR "${ENGINE_BACKEND_ROOT}/runtime_bundle/py")
execute_process(
  COMMAND "${ENGINE_BACKEND_PREP_SCRIPT}"
  RESULT_VARIABLE ENGINE_BACKEND_PREP_RESULT
  OUTPUT_VARIABLE ENGINE_BACKEND_PREP_OUTPUT
  ERROR_VARIABLE ENGINE_BACKEND_PREP_ERROR
)
if(NOT ENGINE_BACKEND_PREP_RESULT EQUAL 0)
  message(FATAL_ERROR
    "Failed to prepare orchestrator package.\n"
    "Output:\n${ENGINE_BACKEND_PREP_OUTPUT}\n"
    "Error:\n${ENGINE_BACKEND_PREP_ERROR}"
  )
endif()
message(STATUS "Prepared orchestrator package for runtime bundle.")

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT OR
   CMAKE_INSTALL_PREFIX STREQUAL "/usr/local")
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} bridge RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy prepared orchestrator runtime bundle (data/py/site-packages).
install(DIRECTORY "${ENGINE_BACKEND_RUNTIME_BUNDLE_DIR}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  USE_SOURCE_PERMISSIONS)

# --- Bundle Python Runtime ---
# Copy libpython3.13.so
file(GLOB PYTHON_LIBS "${PYTHON_ROOT_DIR}/lib/libpython3.13.so*")
install(FILES ${PYTHON_LIBS}
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Copy Standard Library (excluding site-packages to save space if needed, but we might need some)
# Actually, for embed, we usually copy the whole python3.13 folder.
install(DIRECTORY "${PYTHON_ROOT_DIR}/lib/python3.13"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  USE_SOURCE_PERMISSIONS
  PATTERN "__pycache__" EXCLUDE
  PATTERN "site-packages" EXCLUDE # We provide our own in data/py/site-packages
)
# --- Spawn worker interpreter ---
# task_runtime spawns real worker processes (fork is unavailable on Windows
# and unsafe in GUI processes on macOS; Linux unifies on the same mechanism).
# The spawn child re-execs this interpreter, so the bundle must carry a
# runnable one: the binary plus relative symlinks reproducing the prefix
# layout it expects (RPATH $ORIGIN/../lib, stdlib at lib/python3.13), all
# pointing into the existing lib/ tree — no duplication. The existing lib/
# tree is otherwise untouched, so the embedded (dlopen) path keeps working.
# Like the rules above, paths resolve against CMAKE_INSTALL_PREFIX, which
# the .deb/snap/Flatpak flows consume as the bundle root.
set(SPAWN_PYTHON_BIN "${PYTHON_ROOT_DIR}/bin/python3.13")
if(NOT EXISTS "${SPAWN_PYTHON_BIN}")
  message(FATAL_ERROR "Python 3.13 worker interpreter not found for spawn tasks: ${SPAWN_PYTHON_BIN}")
endif()
install(FILES "${SPAWN_PYTHON_BIN}"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/python/bin"
  COMPONENT Runtime
  PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
file(GLOB SPAWN_PYTHON_LIBS "${PYTHON_ROOT_DIR}/lib/libpython3.13.so*")
foreach(SPAWN_PYTHON_LIB ${SPAWN_PYTHON_LIBS})
  get_filename_component(SPAWN_PYTHON_LIB_NAME "${SPAWN_PYTHON_LIB}" NAME)
  install(CODE "
    file(MAKE_DIRECTORY \"${CMAKE_INSTALL_PREFIX}/python/lib\")
    file(CREATE_LINK \"../../lib/${SPAWN_PYTHON_LIB_NAME}\" \"${CMAKE_INSTALL_PREFIX}/python/lib/${SPAWN_PYTHON_LIB_NAME}\" SYMBOLIC)
    " COMPONENT Runtime)
endforeach()
install(CODE "
  file(MAKE_DIRECTORY \"${CMAKE_INSTALL_PREFIX}/python/lib\")
  file(CREATE_LINK \"../../lib/python3.13\" \"${CMAKE_INSTALL_PREFIX}/python/lib/python3.13\" SYMBOLIC)
  " COMPONENT Runtime)
# -----------------------------
