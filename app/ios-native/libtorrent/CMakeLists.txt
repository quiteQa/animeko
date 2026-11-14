# iOS 上的 libtorrent 与 anitorrent C++ 封装. 由 build-ios.sh 调用, 不单独使用.
cmake_minimum_required(VERSION 3.21)
project(libtorrent_ios CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS OFF)

# 与上游 anitorrent-native 相同的编译选项
add_compile_definitions(TORRENT_HAVE_MMAP=0)
add_compile_definitions(TORRENT_ABI_VERSION=3)

# Boost 只用头文件 (来自 anitorrent 仓库); 用 CMake 自带的 FindBoost 查找.
set(CMAKE_POLICY_DEFAULT_CMP0167 OLD)
set(Boost_NO_SYSTEM_PATHS ON)
find_package(OpenSSL REQUIRED)

set(build_examples OFF CACHE BOOL "" FORCE)
set(build_tests OFF CACHE BOOL "" FORCE)
set(build_tools OFF CACHE BOOL "" FORCE)
set(python-bindings OFF CACHE BOOL "" FORCE)
set(deprecated-functions OFF CACHE BOOL "" FORCE)
add_subdirectory(${LIBTORRENT_SOURCE_DIR} libtorrent EXCLUDE_FROM_ALL)

# anitorrent 的 C++ 封装 (session_t, torrent_handle_t 等), 不含 SWIG/JNI 生成的代码
set(anitorrent_cpp ${ANITORRENT_NATIVE_DIR}/cpp)
add_library(anitorrent-core STATIC
        ${anitorrent_cpp}/src/anitorrent.cpp
        ${anitorrent_cpp}/src/events.cpp
        ${anitorrent_cpp}/src/torrent_info_t.cpp
        ${anitorrent_cpp}/src/torrent_add_info_t.cpp
        ${anitorrent_cpp}/src/session_t.cpp
        ${anitorrent_cpp}/src/torrent_handle_t.cpp
        ${anitorrent_cpp}/src/global_lock.cpp
        ${anitorrent_cpp}/src/plugin/peer_filter_plugin.cpp
        ${anitorrent_cpp}/src/peer_filter.cpp
)
target_include_directories(anitorrent-core PUBLIC ${anitorrent_cpp}/include)
target_link_libraries(anitorrent-core PUBLIC torrent-rasterbar)

install(TARGETS anitorrent-core torrent-rasterbar ARCHIVE DESTINATION lib)
install(DIRECTORY ${LIBTORRENT_SOURCE_DIR}/include/libtorrent DESTINATION include)
install(DIRECTORY ${anitorrent_cpp}/include/ DESTINATION include/anitorrent)

# 冒烟测试: 在模拟器中运行 (xcrun simctl spawn), 验证 libtorrent 能启动会话, 连上 DHT 并获取种子元数据
add_executable(lt-smoke smoke/main.cpp)
target_link_libraries(lt-smoke PRIVATE anitorrent-core)
# iOS 上可执行文件默认打包为 .app; 冒烟测试是命令行程序, 由 simctl spawn 直接运行
set_target_properties(lt-smoke PROPERTIES MACOSX_BUNDLE OFF)
install(TARGETS lt-smoke RUNTIME DESTINATION bin BUNDLE DESTINATION bin)
