/*
 * 红果短剧客户端 Rust 核心 —— C ABI 头文件（ARCH §3.1）。
 *
 * 仅两个符号，是 Dart 侧与 Rust 侧的唯一契约面：
 *   char* drama_request(const char* utf8_json);
 *   void  drama_free(char* ptr);
 *
 * 信封（ARCH §3.2）：
 *   入参：{"v":1,"op":"...","source":"...","params":{...}}
 *   出参：{"ok":true,"data":...}  或  {"ok":false,"error":{"code":"...","msg":"...","retry":false}}
 *
 * 约束：入参为 UTF-8、以 NUL 结尾，且 > 1 MiB 时返回 TOO_LARGE。
 * 返回指针始终非空，必须用 drama_free 释放。
 */
#ifndef DRAMA_CORE_H
#define DRAMA_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

char* drama_request(const char* utf8_json);

void drama_free(char* ptr);

#ifdef __cplusplus
}
#endif

#endif /* DRAMA_CORE_H */
