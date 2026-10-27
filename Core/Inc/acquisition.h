#ifndef ACQUISITION_H
#define ACQUISITION_H
#include <stdint.h>
typedef struct {
  volatile int32_t value;
  volatile uint32_t blocks, faults, max_cycles;
} AcquisitionStatus;
extern AcquisitionStatus acquisition_status;
void Acquisition_Start(void);
/* Останов захвата: нужен на время обновления ПО, когда ядро надолго
   блокируется операциями с флешем. */
void Acquisition_Stop(void);
void Acquisition_Poll(void);
#endif
