/*
 * config.h —— libdca 0.0.7 在 iOS / arm64 上的手工配置。
 *
 * libdca 官方只提供 configure.ac，config.h 由 autoconf 生成，tarball 里没有。
 * 在 Gradle/Xcode 环境里跑 autotools 太重（还要 --host 交叉编译那一套），
 * 而库里真正用到的配置宏极少（源码里只查 HAVE_MEMALIGN 和 WORDS_BIGENDIAN），
 * 所以这里直接手写一份，等价于 configure 在 arm64-apple-darwin 上的输出。
 *
 * 由 .github/workflows/build.yml 的 "Build libdca" 步骤拷进源码树后编译。
 */

#ifndef LIBDCA_CONFIG_H
#define LIBDCA_CONFIG_H

/* ── 包信息 ─────────────────────────────────────────── */
#define PACKAGE "libdca"
#define PACKAGE_NAME "libdca"
#define PACKAGE_TARNAME "libdca"
#define PACKAGE_VERSION "0.0.7"
#define PACKAGE_STRING "libdca 0.0.7"
#define PACKAGE_BUGREPORT ""
#define VERSION "0.0.7"

/* ── 头文件可用性（iOS SDK 全都有）───────────────────── */
#define STDC_HEADERS 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_MEMORY_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_UNISTD_H 1

/* clang 有 __builtin_expect */
#define HAVE_BUILTIN_EXPECT 1

/* ── 刻意不定义 ─────────────────────────────────────── */
/* HAVE_MEMALIGN：iOS 上 memalign 已废弃，parse.c 会退回 malloc，
   malloc 在 arm64 上本来就是 16 字节对齐，够 qmf 用。 */
/* WORDS_BIGENDIAN：arm64 是小端。 */
/* LIBDCA_FIXED / LIBDCA_DOUBLE：用默认的 float 输出。 */

/* ── 基本类型宽度 ───────────────────────────────────── */
#define SIZEOF_CHAR 1
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_VOIDP 8

#endif /* LIBDCA_CONFIG_H */
