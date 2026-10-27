#ifndef DAC_SINE_H
#define DAC_SINE_H
#include <stdint.h>
/* 32 samples per period, 128-entry sine table for phase interpolation. */
#define DAC_SINE_SAMPLES       32U
#define DAC_SINE_TABLE         128U
#define DAC_SINE_FREQ_MIN      100U
#define DAC_SINE_FREQ_MAX      20000U
#define DAC_SINE_FREQ_DEFAULT  8000U
/* Phase of DAC2 relative to DAC1, in tenths of a degree: -450..+450. */
#define DAC_SINE_PHASE_MAX     450
#define DAC_SINE_A1_DEFAULT    2048U
#define DAC_SINE_B1_DEFAULT    1000U
#define DAC_SINE_A2_DEFAULT    2048U
#define DAC_SINE_B2_DEFAULT    1000U
void DAC_Sine_Init(void);
void DAC_Sine_Start(void);
void DAC_Sine_Stop(void);
uint8_t DAC_Sine_IsRunning(void);
/* Frequency and levels are targets: the main loop ramps the output to them. */
uint32_t DAC_Sine_SetFrequency(uint32_t hz);
uint32_t DAC_Sine_GetFrequency(void);
uint32_t DAC_Sine_GetSampleRate(void);
void DAC_Sine_SetPhaseTenths(int16_t tenths);
int16_t DAC_Sine_GetPhaseTenths(void);
void DAC_Sine_SetLevels(uint16_t a1,uint16_t b1,uint16_t a2,uint16_t b2);
void DAC_Sine_GetLevels(uint16_t *a1,uint16_t *b1,uint16_t *a2,uint16_t *b2);
/* Move current values toward targets and rebuild the DMA tables in place.
 * Call from the main loop; never stops generation, so the sine is continuous. */
void DAC_Sine_Service(void);
#define DAC_SINE_DMA1_UNDERRUN 0x10U
#define DAC_SINE_DMA2_UNDERRUN 0x20U
#define DAC_SINE_TRANSFER_ERROR 0x40U
uint8_t DAC_Sine_CheckDma(void);
#endif
