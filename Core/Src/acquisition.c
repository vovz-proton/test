#include "main.h"
#include "acquisition.h"
#include "instrument_logic.h"
#include "motor.h"
#include <string.h>
extern SDADC_HandleTypeDef hsdadc1;
static DMA_HandleTypeDef dma;
static volatile int16_t samples[2U*FILTER_N];
AcquisitionStatus acquisition_status;
static uint8_t expected_half;

static void fault(void)
{
  ++acquisition_status.faults;
  /* Latch fault: do not publish partially overwritten data or keep scanning. */
  SDADC1->CR1 &= ~SDADC_CR1_RDMAEN;
  SDADC1->CR2 &= ~SDADC_CR2_RCONT;
  DMA2_Channel3->CCR &= ~DMA_CCR_EN;
  Motor_Fault();
}
static void process(unsigned half)
{
  int16_t work[FILTER_N];
  uint32_t start=DWT->CYCCNT;
  uint32_t remaining=DMA2_Channel3->CNDTR;
  if(acquisition_status.faults) return;
  /* Half 0 must be processed while DMA writes half 1, and conversely. */
  if(half!=expected_half || (half==0U ? remaining>FILTER_N || remaining==0U : remaining<=FILTER_N)) {
    fault(); return;
  }
  for(unsigned i=0;i<FILTER_N;++i) work[i]=samples[half*FILTER_N+i];
  __DMB();
  remaining=DMA2_Channel3->CNDTR;
  if(half==0U ? remaining>FILTER_N || remaining==0U : remaining<=FILTER_N) {
    fault(); return;
  }
  int32_t value=Filter_TrimmedMean(work);
  uint32_t cycles=DWT->CYCCNT-start;
  if(cycles>acquisition_status.max_cycles) acquisition_status.max_cycles=cycles;
  if(cycles>=SystemCoreClock/SDADC_RATE_HZ*FILTER_N) { fault(); return; }
  acquisition_status.value=value;
  ++acquisition_status.blocks;
  expected_half^=1U;
}
void HAL_SDADC_ConvHalfCpltCallback(SDADC_HandleTypeDef *h) { if(h==&hsdadc1) process(0); }
void HAL_SDADC_ConvCpltCallback(SDADC_HandleTypeDef *h) { if(h==&hsdadc1) process(1); }
void HAL_SDADC_ErrorCallback(SDADC_HandleTypeDef *h) { if(h==&hsdadc1) fault(); }
void DMA2_Channel3_IRQHandler(void)
{
  uint32_t f=DMA2->ISR;
  if((f&(DMA_ISR_HTIF3|DMA_ISR_TCIF3))==(DMA_ISR_HTIF3|DMA_ISR_TCIF3)) {
    DMA2->IFCR=DMA_IFCR_CGIF3; fault(); return;
  }
  HAL_DMA_IRQHandler(&dma);
}
void Acquisition_Start(void)
{
  SDADC_ConfParamTypeDef conf={0};
  __HAL_RCC_DMA2_CLK_ENABLE();
  dma.Instance=DMA2_Channel3;
  dma.Init.Direction=DMA_PERIPH_TO_MEMORY;
  dma.Init.PeriphInc=DMA_PINC_DISABLE;
  dma.Init.MemInc=DMA_MINC_ENABLE;
  dma.Init.PeriphDataAlignment=DMA_PDATAALIGN_HALFWORD;
  dma.Init.MemDataAlignment=DMA_MDATAALIGN_HALFWORD;
  dma.Init.Mode=DMA_CIRCULAR;
  dma.Init.Priority=DMA_PRIORITY_HIGH;
  if(HAL_DMA_Init(&dma)!=HAL_OK) Error_Handler();
  __HAL_LINKDMA(&hsdadc1,hdma,dma);
  conf.InputMode=SDADC_INPUT_MODE_SE_ZERO_REFERENCE;
  conf.Gain=SDADC_GAIN_1;
  conf.CommonMode=SDADC_COMMON_MODE_VSSA;
  conf.Offset=0;
  if(HAL_SDADC_PrepareChannelConfig(&hsdadc1,SDADC_CONF_INDEX_0,&conf)!=HAL_OK ||
     HAL_SDADC_AssociateChannelConfig(&hsdadc1,SDADC_CHANNEL_5,SDADC_CONF_INDEX_0)!=HAL_OK ||
     HAL_SDADC_ConfigChannel(&hsdadc1,SDADC_CHANNEL_5,SDADC_CONTINUOUS_CONV_ON)!=HAL_OK ||
     HAL_SDADC_SelectRegularTrigger(&hsdadc1,SDADC_SOFTWARE_TRIGGER)!=HAL_OK ||
     HAL_SDADC_CalibrationStart(&hsdadc1,SDADC_CALIBRATION_SEQ_1)!=HAL_OK ||
     HAL_SDADC_PollForCalibEvent(&hsdadc1,100)!=HAL_OK) Error_Handler();
  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
  DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
  HAL_NVIC_SetPriority(DMA2_Channel3_IRQn,2,0);
  HAL_NVIC_EnableIRQ(DMA2_Channel3_IRQn);
  if(HAL_SDADC_Start_DMA(&hsdadc1,(uint32_t*)samples,2U*FILTER_N)!=HAL_OK) Error_Handler();
}
/* Останов захвата. Нужен на время обновления ПО: при стирании и записи флеша
 * ядро блокируется на десятки миллисекунд, а проверки фазы DMA в process()
 * посчитали бы это нарушением темпа и защёлкнули ошибку. */
void Acquisition_Stop(void)
{
  HAL_NVIC_DisableIRQ(DMA2_Channel3_IRQn);
  (void)HAL_SDADC_Stop_DMA(&hsdadc1);
  expected_half=0U;
}
void Acquisition_Poll(void)
{
  if(!acquisition_status.faults && (SDADC1->ISR&SDADC_ISR_ROVRF)) fault();
}
