#ifndef LED_COLOR_H
#define LED_COLOR_H
#include <stdint.h>
/* Q8 channels: 255*256 is full output. Fractions are temporally dithered. */
typedef struct { uint16_t r,g,b; } LedColor;
typedef struct { uint8_t r,g,b; } LedDither;
typedef struct { uint8_t r,g,b; } LedRgb;
#define LED_WS_PERIOD_TICKS 90U
#define LED_WS_ZERO_TICKS 24U
#define LED_WS_ONE_TICKS 62U
#define LED_WS_WORDS 25U
uint16_t Led_LevelFromSdadc(int32_t value);
LedColor Led_Rainbow(uint16_t level);
LedColor Led_Preparing(uint32_t elapsed_ms);
LedRgb Led_Dither(LedColor color,LedDither *error);
/* WS2812B: GRB, most significant bit first, then zero duty for reset. */
void Led_Encode(LedRgb color,uint16_t words[LED_WS_WORDS]);
#endif
