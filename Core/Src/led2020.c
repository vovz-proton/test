#include "main.h"
#include "led2020.h"
#include "led_color.h"
#include "motor.h"
#include "acquisition.h"
#include "instrument_config.h"

/* PA15 AF10 = TIM12_CH2. TIM12 has no DMA request of its own:
 * TIM4_UP -> DMA1 CH7 -> TIM12 CCR2 preload.
 * Both timers run from the same 72 MHz APB1 timer clock, ARR=89.
 * TIM12 starts FIRST, TIM4 a few bus clocks later, inside a tiny critical
 * section. Each DMA write follows TIM12's latch and has nearly 1.25 us
 * to complete before the next latch. Thus bus arbitration affects the
 * preload deadline, not the output pulse width. Motor/DAC/SDADC unchanged.
 * 24 data words + zero. No bit IRQs; timers keep output low after DMA ends.
 */
static uint16_t frame[LED_WS_WORDS];

static uint32_t last_frame_us;



Led2020Status led2020_status;

void LED2020_Init(void)
{
  GPIO_InitTypeDef gpio={0};
  if(HAL_RCC_GetPCLK1Freq()*2U!=72000000U) Error_Handler();
  __HAL_RCC_TIM4_CLK_ENABLE();
  __HAL_RCC_TIM12_CLK_ENABLE();
  __HAL_RCC_DMA1_CLK_ENABLE();
  TIM4->CR1=0; TIM4->DIER=0; TIM4->CR2=0;
  TIM4->PSC=0; TIM4->ARR=LED_WS_PERIOD_TICKS-1U;
  TIM4->EGR=TIM_EGR_UG; TIM4->SR=0;
  TIM12->CR1=0; TIM12->DIER=0; TIM12->CCER=0;
  TIM12->PSC=0; TIM12->ARR=LED_WS_PERIOD_TICKS-1U;
  TIM12->CCMR1=TIM_CCMR1_OC2M_1|TIM_CCMR1_OC2M_2|TIM_CCMR1_OC2PE;
  TIM12->CCR2=0;
  TIM12->EGR=TIM_EGR_UG; TIM12->SR=0;
  TIM12->CCER=TIM_CCER_CC2E;
  gpio.Pin=LED2020_Pin; gpio.Mode=GPIO_MODE_AF_PP;
  gpio.Pull=GPIO_NOPULL; gpio.Speed=GPIO_SPEED_FREQ_HIGH;
  gpio.Alternate=GPIO_AF10_TIM12;
  HAL_GPIO_Init(LED2020_GPIO_Port,&gpio);
  /* At power-up keep DIN low for a complete reset interval before first frame. */
  last_frame_us=Instrument_Micros()-(LED_FRAME_US-LED_RESET_US);


}
static void send(LedRgb rgb)
{
  TIM4->CR1=0; TIM4->DIER=0;
  TIM12->CR1=0;
  DMA1_Channel7->CCR &= ~DMA_CCR_EN;
  DMA1->IFCR=DMA_IFCR_CGIF7;
  Led_Encode(rgb,frame);
  /* Clear active AND preload values, so the first two periods are low. */
  TIM12->CCR2=0;
  TIM12->EGR=TIM_EGR_UG;
  TIM12->CNT=0; TIM12->SR=0;
  TIM4->EGR=TIM_EGR_UG;
  TIM4->CNT=0; TIM4->SR=0;
  DMA1_Channel7->CPAR=(uint32_t)&TIM12->CCR2;
  DMA1_Channel7->CMAR=(uint32_t)frame;
  DMA1_Channel7->CNDTR=LED_WS_WORDS;
  DMA1_Channel7->CCR=DMA_CCR_DIR|DMA_CCR_MINC|DMA_CCR_PSIZE_0|
                         DMA_CCR_MSIZE_0|DMA_CCR_EN; /* normal, low priority */
  TIM4->DIER=TIM_DIER_UDE;
  __DMB();
  uint32_t mask=__get_PRIMASK();
  __disable_irq();
  TIM12->CR1=TIM_CR1_ARPE|TIM_CR1_CEN;
  TIM4->CR1=TIM_CR1_CEN;
  __set_PRIMASK(mask);
  last_frame_us=Instrument_Micros();
  ++led2020_status.frames;
}
void LED2020_Poll(void)
{
  uint32_t now=Instrument_Micros();
  if((uint32_t)(now-last_frame_us)<LED_FRAME_US) return;
  if(led2020_status.frames && ((DMA1->ISR&DMA_ISR_TEIF7) || DMA1_Channel7->CNDTR)) {
    /* Recover locally: malformed LED packets must not stop motor/acquisition. */
    TIM4->CR1=0; TIM4->DIER=0; TIM12->CR1=0;
    DMA1_Channel7->CCR &= ~DMA_CCR_EN;
    DMA1_Channel7->CNDTR=0; DMA1->IFCR=DMA_IFCR_CGIF7;
    TIM12->CCR2=0; TIM12->EGR=TIM_EGR_UG; TIM12->CNT=0;
    last_frame_us=Instrument_Micros()-(LED_FRAME_US-LED_RESET_US);
    ++led2020_status.faults;
    return;
  }
  /* Direct limit-switch indication, including bench mode: PF7 low is active. */
  uint8_t active=((Konc_GPIO_Port->IDR&Konc_Pin)?1U:0U)==KONC_ACTIVE_LEVEL;
  LedRgb color={0,0,0};
  /* 20% of the full 8-bit channel value. */
  if(active) color.r=51U;
  else color.g=51U;
  led2020_status.level=Led_LevelFromSdadc(acquisition_status.value);
  send(color);
}