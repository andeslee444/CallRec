cmake_minimum_required(VERSION 3.20)
project(CallRecDriver LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find libASPL (vendored in Dependencies/)
# If using installed version: find_package(libASPL REQUIRED)
set(LIBASPL_DIR "${CMAKE_SOURCE_DIR}/../Dependencies/libASPL")
if(EXISTS "${LIBASPL_DIR}/CMakeLists.txt")
    add_subdirectory(${LIBASPL_DIR} ${CMAKE_BINARY_DIR}/libASPL)
else()
    find_package(libASPL REQUIRED)
endif()

# Driver sources
set(DRIVER_SOURCES
    PluginEntry.cpp
    SmartRouter.cpp
    SharedMemoryReader.cpp
)

# Build as a macOS bundle
add_library(CallRecDriver MODULE ${DRIVER_SOURCES})

target_include_directories(CallRecDriver PRIVATE
    ${CMAKE_SOURCE_DIR}/../Common
    ${LIBASPL_DIR}/include
)

target_link_libraries(CallRecDriver PRIVATE
    libASPL::libASPL
    "-framework CoreAudio"
    "-framework CoreFoundation"
)

# Bundle configuration
set_target_properties(CallRecDriver PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    OUTPUT_NAME "CallRec"
    # Install to /Library/Audio/Plug-Ins/HAL/
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/CallRec.driver/Contents/MacOS"
)

# Copy Info.plist into bundle
add_custom_command(TARGET CallRecDriver POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:CallRecDriver>/Contents"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
        "$<TARGET_BUNDLE_DIR:CallRecDriver>/Contents/Info.plist"
)
