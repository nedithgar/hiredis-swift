/*
 * Copyright (c) 2026 Nedithgar Amirka
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef CHIREDIS_H
#define CHIREDIS_H

#include <stddef.h>
#include <stdint.h>

#include <hiredis/alloc.h>
#include <hiredis/async.h>
#include <hiredis/hiredis.h>
#include <hiredis/read.h>
#include <hiredis/sds.h>
#include <hiredis/sockcompat.h>

#ifdef __cplusplus
extern "C" {
#endif

redisContext *chiredisConnect(const char *hostname, int port,
                              int64_t connectTimeoutMicroseconds,
                              int64_t commandTimeoutMicroseconds);

int chiredisContextIsConnected(const redisContext *context);
int chiredisContextErrorCode(const redisContext *context);
int chiredisContextErrorIsTimeout(const redisContext *context);
const char *chiredisContextErrorString(const redisContext *context);
redisFD chiredisContextFileDescriptor(const redisContext *context);

int chiredisReplyType(const void *reply);
long long chiredisReplyInteger(const void *reply);
double chiredisReplyDouble(const void *reply);
size_t chiredisReplyLength(const void *reply);
const unsigned char *chiredisReplyBytes(const void *reply);
const char *chiredisReplyVerbatimType(const void *reply);
size_t chiredisReplyElementCount(const void *reply);
const void *chiredisReplyElement(const void *reply, size_t index);

#ifdef __cplusplus
}
#endif

#endif /* CHIREDIS_H */
