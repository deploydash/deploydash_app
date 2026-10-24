# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(deploydash LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "deploydash")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# --- Python 3.13 Runtime Setup via uv ---
execute_process(
  COMMAND uv python find 3.13
  OUTPUT_VARIABLE PYTHON_INTERPRETER_PATH
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(NOT PYTHON_INTERPRETER_PATH)
  message(FATAL_ERROR "uv could not find a Python 3.13 interpreter.")
endif()

execute_process(
  COMMAND "${PYTHON_INTERPRETER_PATH}" -c "import sys; print(sys.base_prefix)"
  OUTPUT_VARIABLE PYTHON_BASE_PREFIX
  OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(PYTHON_BASE_PREFIX)
  set(PYTHON_ROOT_DIR "${PYTHON_BASE_PREFIX}")
else()
  get_filename_component(PYTHON_INTERPRETER_REALPATH ${PYTHON_INTERPRETER_PATH} REALPATH)
  get_filename_component(PYTHON_BIN_DIR ${PYTHON_INTERPRETER_REALPATH} DIRECTORY)
  get_filename_component(PYTHON_ROOT_DIR ${PYTHON_BIN_DIR} DIRECTORY)
endif()
# CMake install scripts parse backslashes as escape sequences. uv returns a
# native Windows path here, so normalize it before using it in install(FILES).
file(TO_CMAKE_PATH "${PYTHON_ROOT_DIR}" PYTHON_ROOT_DIR)

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
file(TO_CMAKE_PATH "${ENGINE_BACKEND_ROOT}" ENGINE_BACKEND_ROOT)

if(NOT EXISTS "${ENGINE_BACKEND_ROOT}")
  message(FATAL_ERROR "Backend app root not found: ${ENGINE_BACKEND_ROOT}")
endif()

set(ENGINE_BACKEND_PREP_SCRIPT "${ENGINE_BACKEND_ROOT}/scripts/prepare_desktop_runtime_bundle.py")
set(ENGINE_BACKEND_RUNTIME_BUNDLE_DIR "${ENGINE_BACKEND_ROOT}/runtime_bundle/py")
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env
    "ORCHESTRATOR_VENV_PYTHON=${PYTHON_INTERPRETER_PATH}"
    "${PYTHON_INTERPRETER_PATH}" "${ENGINE_BACKEND_PREP_SCRIPT}"
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

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} bridge
  RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
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

install(DIRECTORY "${ENGINE_BACKEND_RUNTIME_BUNDLE_DIR}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  USE_SOURCE_PERMISSIONS)

file(GLOB PYTHON_RUNTIME_DLLS "${PYTHON_ROOT_DIR}/python3*.dll")
if(PYTHON_RUNTIME_DLLS)
  install(FILES ${PYTHON_RUNTIME_DLLS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

foreach(PYTHON_EXECUTABLE_NAME python.exe pythonw.exe)
  if(NOT EXISTS "${PYTHON_ROOT_DIR}/${PYTHON_EXECUTABLE_NAME}")
    message(FATAL_ERROR
      "Python runtime executable not found: "
      "${PYTHON_ROOT_DIR}/${PYTHON_EXECUTABLE_NAME}")
  endif()
endforeach()
install(FILES
  "${PYTHON_ROOT_DIR}/python.exe"
  "${PYTHON_ROOT_DIR}/pythonw.exe"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(EXISTS "${PYTHON_ROOT_DIR}/DLLs")
  # CPython loads standard-library extension modules such as _socket.pyd from
  # this directory. Preserve the layout instead of flattening its DLLs.
  install(DIRECTORY "${PYTHON_ROOT_DIR}/DLLs"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    USE_SOURCE_PERMISSIONS
    PATTERN "__pycache__" EXCLUDE
    # The embedded backend is headless. CPython's Tcl/Tk binaries are unused
    # and make otherwise valid MSIX packages unsignable with Windows SignTool.
    PATTERN "_tkinter.pyd" EXCLUDE
    PATTERN "tcl86t.dll" EXCLUDE
    PATTERN "tk86t.dll" EXCLUDE
  )
endif()

if(EXISTS "${PYTHON_ROOT_DIR}/Lib")
  install(DIRECTORY "${PYTHON_ROOT_DIR}/Lib"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    USE_SOURCE_PERMISSIONS
    PATTERN "__pycache__" EXCLUDE
    PATTERN "site-packages" EXCLUDE
    # CPython's stdlib test suite ships private-key fixtures
    # (Lib/test/certdata) that must never enter a Store payload.
    PATTERN "test" EXCLUDE
    PATTERN "idlelib" EXCLUDE
    PATTERN "tkinter" EXCLUDE
    PATTERN "turtledemo" EXCLUDE
  )
endif()

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
