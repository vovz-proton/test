#ifndef MOCK_USBD_DEF_H
#define MOCK_USBD_DEF_H
#include <stdint.h>
#define USBD_STATE_CONFIGURED 3U
#define USBD_OK 0U
#define USBD_BUSY 1U
#define USBD_FAIL 2U
typedef struct { uint8_t dev_state; void *pClassData; } USBD_HandleTypeDef;
#endif
