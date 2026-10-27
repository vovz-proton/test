#ifndef MOCK_USBD_CDC_H
#define MOCK_USBD_CDC_H
#include "usbd_def.h"
typedef struct { uint32_t TxState; } USBD_CDC_HandleTypeDef;
uint8_t USBD_CDC_ReceivePacket(USBD_HandleTypeDef *device);
#endif
