#include "led_color.h"
#include "instrument_config.h"
#define FULL (255U*256U)
uint16_t Led_LevelFromSdadc(int32_t value)
{
  if(value<=-32768) return 0;
  if(value>=32767) return 65535;
  return (uint16_t)(value+32768);
}
LedColor Led_Rainbow(uint16_t level)
{
  /* Hue 0..270 degrees, without first reducing the 16-bit input to 8 bits.
   * 6 hue sectors use denominator 2*65535; our range covers 4.5 sectors. */
  uint32_t position=(uint32_t)level*9U;
  uint32_t sector=position/131070U;
  uint16_t rise=(uint16_t)((uint64_t)(position%131070U)*FULL/131070U);
  uint16_t fall=(uint16_t)(FULL-rise);
  switch(sector) {
    case 0: { LedColor c={FULL,rise,0}; return c; }
    case 1: { LedColor c={fall,FULL,0}; return c; }
    case 2: { LedColor c={0,FULL,rise}; return c; }
    case 3: { LedColor c={0,fall,FULL}; return c; }
    default: { LedColor c={rise,0,FULL}; return c; }
  }
}
LedColor Led_Preparing(uint32_t elapsed_ms)
{
  /* 250 ms on + 250 ms off = two complete flashes per second. */
  LedColor c={0,0,0};
  if((elapsed_ms/LED_BLINK_HALF_MS)%2U==0U) { c.r=FULL; c.g=64U*256U; }
  return c;
}
static uint8_t channel(uint16_t value,uint8_t *error)
{
  uint32_t sum=(uint32_t)value+*error;
  *error=(uint8_t)(sum&255U);
  return (uint8_t)(sum>>8);
}
LedRgb Led_Dither(LedColor c,LedDither *error)
{
  LedRgb out;
  out.r=channel(c.r,&error->r);
  out.g=channel(c.g,&error->g);
  out.b=channel(c.b,&error->b);
  return out;
}
void Led_Encode(LedRgb color,uint16_t words[LED_WS_WORDS])
{
  uint32_t g=(uint32_t)color.g*LED_BRIGHTNESS_PERCENT/100U;
  uint32_t r=(uint32_t)color.r*LED_BRIGHTNESS_PERCENT/100U;
  uint32_t b=(uint32_t)color.b*LED_BRIGHTNESS_PERCENT/100U;
  uint32_t grb=(g<<16)|(r<<8)|b;
  for(unsigned i=0;i<24;++i)
    words[i]=(grb&(1UL<<(23U-i)))?LED_WS_ONE_TICKS:LED_WS_ZERO_TICKS;
  words[24]=0; /* Keeps DIN low indefinitely after the last data bit. */
}
