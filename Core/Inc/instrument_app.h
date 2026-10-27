#ifndef INSTRUMENT_APP_H
#define INSTRUMENT_APP_H
#include <stdint.h>
void Instrument_Init(void);
void Instrument_Poll(void);
void Instrument_UsbReceive(const uint8_t *bytes,uint32_t length);
uint8_t Instrument_UsbCanReceive(void);
void Instrument_UsbReset(void);
/* wValue запроса CDC_SET_CONTROL_LINE_STATE: bit 0 = DTR, bit 1 = RTS. */
void Instrument_UsbLineState(uint16_t state);
#endif
