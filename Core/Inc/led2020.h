#ifndef LED2020_H
#define LED2020_H
#include <stdint.h>
typedef struct {
  volatile uint32_t frames,faults;
  uint16_t level;
} Led2020Status;
extern Led2020Status led2020_status;
void LED2020_Init(void);
void LED2020_Poll(void);
#endif
