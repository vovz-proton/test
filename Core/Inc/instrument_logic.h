#ifndef INSTRUMENT_LOGIC_H
#define INSTRUMENT_LOGIC_H
#include <stdint.h>
#include <stddef.h>
#include "instrument_config.h"
typedef enum { CMD_NONE, CMD_START, CMD_STOP, CMD_LENGTH, CMD_SPEED, CMD_INVALID,
               CMD_DAC_A1, CMD_DAC_B1, CMD_DAC_A2, CMD_DAC_B2,
               CMD_FREQ, CMD_PHASE, CMD_BOOT } CommandType;
typedef struct { CommandType type; int32_t value; } Command;
/* bytes[] holds the longest command (DA1xxxx - 7 characters). */
typedef struct { char bytes[8]; uint8_t used; uint32_t last_ms; } CommandParser;
/* Fixed-size ASCII protocol; no terminators required. Malformed prefixes resync. */
Command Protocol_Push(CommandParser *p,uint8_t byte,uint32_t ms);
int32_t Filter_TrimmedMean(int16_t samples[FILTER_N]);
uint32_t Motion_LengthUnits(uint16_t tenths_mm);
uint32_t Motion_PulseHz(uint8_t speed);
uint32_t Motion_AccelHz(uint8_t subdivision_shift);
#endif
