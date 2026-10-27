#ifndef SERIAL_PROTOCOL_H
#define SERIAL_PROTOCOL_H
#include "instrument_logic.h"
#include "motor.h"
typedef enum { REPLY_OK, REPLY_BUSY, REPLY_NOT_SCANNING, REPLY_ZERO_LENGTH,
               REPLY_FAULT, REPLY_RANGE, REPLY_FORMAT } ReplyCode;
typedef struct { Command command; ReplyCode code; } CommandReply;
typedef enum { WIRE_HOMING, WIRE_POSITIONING, WIRE_READY, WIRE_SCAN,
               WIRE_RETURN, WIRE_FAULT, WIRE_UNKNOWN } WireState;
/* ACK means accepted, not that an asynchronous move has completed. */
CommandReply Serial_Execute(Command command);
int Serial_FormatReply(char *buffer,size_t size,CommandReply reply);
int Serial_FormatTelemetry(char *buffer,size_t size,int32_t z,int32_t units,uint8_t valid);
WireState Serial_State(MotorState state);
const char *Serial_StateName(WireState state);
#endif
