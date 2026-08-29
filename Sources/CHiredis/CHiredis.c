/*
 * Copyright (c) 2026 Nedithgar Amirka
 *
 * SPDX-License-Identifier: MIT
 */

#include "CHiredis.h"

#include <errno.h>

static struct timeval chiredisTimeval(int64_t microseconds) {
  struct timeval value;
  value.tv_sec = (time_t)(microseconds / 1000000);
  value.tv_usec = (suseconds_t)(microseconds % 1000000);
  return value;
}

redisContext *chiredisConnect(const char *hostname, int port,
                              int64_t connectTimeoutMicroseconds,
                              int64_t commandTimeoutMicroseconds) {
  redisOptions options = {0};
  struct timeval connectTimeout = chiredisTimeval(connectTimeoutMicroseconds);
  struct timeval commandTimeout = chiredisTimeval(commandTimeoutMicroseconds);

  REDIS_OPTIONS_SET_TCP(&options, hostname, port);
  options.connect_timeout = &connectTimeout;
  options.command_timeout = &commandTimeout;
  options.options |= REDIS_OPT_SET_SOCK_CLOEXEC;
  options.options |= REDIS_OPT_NO_PUSH_AUTOFREE;

  return redisConnectWithOptions(&options);
}

int chiredisContextIsConnected(const redisContext *context) {
  return context != NULL && context->err == 0 &&
         (context->flags & REDIS_CONNECTED) != 0;
}

int chiredisContextErrorCode(const redisContext *context) {
  return context == NULL ? REDIS_ERR_OTHER : context->err;
}

int chiredisContextErrorIsTimeout(const redisContext *context) {
  if (context == NULL) {
    return 0;
  }
  if (context->err == REDIS_ERR_TIMEOUT) {
    return 1;
  }

  /*
   * Darwin reports a blocking SO_RCVTIMEO expiry as EAGAIN/EWOULDBLOCK.
   * hiredis 1.4.1 classifies only ETIMEDOUT as REDIS_ERR_TIMEOUT, so retain
   * that thread-local errno long enough for the Swift error adapter to
   * provide the promised timeout category without modifying upstream code.
   */
  return context->err == REDIS_ERR_IO && context->command_timeout != NULL &&
         (errno == EAGAIN || errno == EWOULDBLOCK);
}

const char *chiredisContextErrorString(const redisContext *context) {
  return context == NULL ? "hiredis returned a null context" : context->errstr;
}

redisFD chiredisContextFileDescriptor(const redisContext *context) {
  return context == NULL ? REDIS_INVALID_FD : context->fd;
}

int chiredisReplyType(const void *reply) {
  return reply == NULL ? 0 : ((const redisReply *)reply)->type;
}

long long chiredisReplyInteger(const void *reply) {
  return reply == NULL ? 0 : ((const redisReply *)reply)->integer;
}

double chiredisReplyDouble(const void *reply) {
  return reply == NULL ? 0.0 : ((const redisReply *)reply)->dval;
}

size_t chiredisReplyLength(const void *reply) {
  return reply == NULL ? 0 : ((const redisReply *)reply)->len;
}

const unsigned char *chiredisReplyBytes(const void *reply) {
  return reply == NULL
             ? NULL
             : (const unsigned char *)((const redisReply *)reply)->str;
}

const char *chiredisReplyVerbatimType(const void *reply) {
  return reply == NULL ? NULL : ((const redisReply *)reply)->vtype;
}

size_t chiredisReplyElementCount(const void *reply) {
  return reply == NULL ? 0 : ((const redisReply *)reply)->elements;
}

const void *chiredisReplyElement(const void *reply, size_t index) {
  const redisReply *typedReply = (const redisReply *)reply;
  if (typedReply == NULL || typedReply->element == NULL ||
      index >= typedReply->elements) {
    return NULL;
  }
  return typedReply->element[index];
}
