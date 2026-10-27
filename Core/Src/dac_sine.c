#include "dac_sine.h"
#include "main.h"
/* RM0313: DAC1 -> DMA1 CH3 (remap), DAC2 -> DMA2 CH5 (default).
 * SDADC1 retains DMA2 CH3. TIM3 CH3 -> DMA1 CH2 (ARR),
 * TIM3 CH1 -> DMA1 CH6 (GPIOA BSRR). No sample interrupts.
 * TRGO latches both DACs; CC1/CC3 at CNT=1 update GPIO/ARR.
 * No ARR preload: writing at CNT=1 sets the CURRENT interval.
 *
 * Generation is never stopped for a level, frequency or phase change:
 * the DAC DMA buffers and the 32-entry ARR table are rewritten in place.
 * The sample index (phase) continues, so the sine does not restart.
 * A main-loop service moves the current values toward the targets in small
 * steps; the resulting small table updates are smooth on the output.
 */
extern DAC_HandleTypeDef hdac1, hdac2;
static DMA_HandleTypeDef dma1, dma2;
static uint16_t buf1[DAC_SINE_SAMPLES], buf2[DAC_SINE_SAMPLES];
static uint32_t trigger[DAC_SINE_SAMPLES];
static uint16_t periods[DAC_SINE_SAMPLES];
/* 128 points: even indices repeat the old 32-point table, odd points are used
 * only to interpolate a phase shift of DAC2. */
static const int16_t sine[DAC_SINE_TABLE]={
       0,   1608,   3212,   4808,   6393,   7962,   9512,  11039,
   12539,  14010,  15446,  16846,  18204,  19519,  20787,  22005,
   23170,  24279,  25329,  26319,  27245,  28105,  28898,  29621,
   30273,  30852,  31356,  31785,  32137,  32412,  32609,  32728,
   32767,  32728,  32609,  32412,  32137,  31785,  31356,  30852,
   30273,  29621,  28898,  28105,  27245,  26319,  25329,  24279,
   23170,  22005,  20787,  19519,  18204,  16846,  15446,  14010,
   12539,  11039,   9512,   7962,   6393,   4808,   3212,   1608,
       0,  -1608,  -3212,  -4808,  -6393,  -7962,  -9512, -11039,
  -12539, -14010, -15446, -16846, -18204, -19519, -20787, -22005,
  -23170, -24279, -25329, -26319, -27245, -28105, -28898, -29621,
  -30273, -30852, -31356, -31785, -32137, -32412, -32609, -32728,
  -32767, -32728, -32609, -32412, -32137, -31785, -31356, -30852,
  -30273, -29621, -28898, -28105, -27245, -26319, -25329, -24279,
  -23170, -22005, -20787, -19519, -18204, -16846, -15446, -14010,
  -12539, -11039,  -9512,  -7962,  -6393,  -4808,  -3212,  -1608
};

/* Targets are what the host asked for; currents are ramped toward them. */
static uint16_t a1_target=DAC_SINE_A1_DEFAULT,b1_target=DAC_SINE_B1_DEFAULT;
static uint16_t a2_target=DAC_SINE_A2_DEFAULT,b2_target=DAC_SINE_B2_DEFAULT;
static uint16_t freq_target=DAC_SINE_FREQ_DEFAULT;
static int16_t phase_target=0;
static int32_t a1_q8=(int32_t)DAC_SINE_A1_DEFAULT*256,b1_q8=(int32_t)DAC_SINE_B1_DEFAULT*256;
static int32_t a2_q8=(int32_t)DAC_SINE_A2_DEFAULT*256,b2_q8=(int32_t)DAC_SINE_B2_DEFAULT*256;
static int32_t freq_q8=(int32_t)DAC_SINE_FREQ_DEFAULT*256;
static int32_t phase_q8=0;
static uint32_t last_service_ms;
static uint16_t preload2=DAC_SINE_A2_DEFAULT;
static uint8_t running;

/* Per-millisecond ramps. Small enough to look continuous, fast enough to
 * follow a slider: full code range in ~130 ms, 45 degrees in ~90 ms,
 * 8 kHz to 20 kHz in ~120 ms. */
#define LEVEL_STEP_Q8 8192     /* 32 codes/ms */
#define FREQ_STEP_Q8  25600    /* 100 Hz/ms */
#define PHASE_STEP_Q8 1280     /* 0.5 deg/ms */
#define SERVICE_MAX_MS 10U

static uint16_t clamp_code(int32_t v) { return v<0?0U:(v>4095?4095U:(uint16_t)v); }
static int32_t level_code(int32_t q8) { return (q8+128)>>8; }

/* 128-entry table position in 1/256 of an entry; wrap is a full period. */
static int32_t sine_at(uint32_t pos)
{
  uint32_t idx=(pos>>8)&(DAC_SINE_TABLE-1U);
  int32_t frac=(int32_t)(pos&255U);
  int32_t a=sine[idx],b=sine[(idx+1U)&(DAC_SINE_TABLE-1U)];
  return (a*(256-frac)+b*frac+128)>>8;
}

/* 32 periods whose sum gives the requested frequency exactly over one period.
 * Average sample rate = 72 MHz / (sum of ARR+1); sum is rounded to an integer,
 * so the frequency error is below a few Hz even at 20 kHz. */
static void build_periods(uint32_t hz)
{
  uint32_t total=(72000000U+hz/2U)/hz;
  uint32_t base=total/DAC_SINE_SAMPLES;
  uint32_t rem=total%DAC_SINE_SAMPLES;
  uint32_t acc=0;
  for(unsigned i=0;i<DAC_SINE_SAMPLES;++i) {
    acc+=rem;
    uint32_t extra=acc/DAC_SINE_SAMPLES;
    acc%=DAC_SINE_SAMPLES;
    periods[i]=(uint16_t)(base+extra-1U);
  }
}

/* DAC2 is A2 - B2*sin(theta+phase); phase is interpolated in the 128 table.
 * The same table is used for DAC1 at phase zero, so phase 0 reproduces the
 * original 32-point waveform exactly. */
static void build_tables(void)
{
  int32_t a1=level_code(a1_q8),b1=level_code(b1_q8);
  int32_t a2=level_code(a2_q8),b2=level_code(b2_q8);
  int32_t offset=(phase_q8*128)/3600;    /* 32768/3600 in Q8 table entries */
  for(unsigned i=0;i<DAC_SINE_SAMPLES;++i) {
    /* DHR pipeline: sample zero is preloaded, DMA starts with sample one. */
    unsigned next=(i+1U)&(DAC_SINE_SAMPLES-1U);
    int32_t s=sine[next*4U];
    buf1[i]=clamp_code(a1+(b1*s)/32767);
    uint32_t pos=((uint32_t)(i+1U)*1024U+(uint32_t)offset)&32767U;
    int32_t sp=sine_at(pos);
    buf2[i]=clamp_code(a2-(b2*sp)/32767);
  }
  uint32_t pos0=(uint32_t)offset&32767U;
  preload2=clamp_code(a2-(b2*sine_at(pos0))/32767);
}

static int32_t approach(int32_t cur,int32_t target,int32_t step)
{
  int32_t diff=target-cur;
  if(diff>step) diff=step;
  else if(diff<-step) diff=-step;
  return cur+diff;
}

static void dac_dma(DMA_HandleTypeDef *d,DMA_Channel_TypeDef *ch,DAC_HandleTypeDef *dac)
{
  d->Instance=ch;
  d->Init.Direction=DMA_MEMORY_TO_PERIPH;
  d->Init.PeriphInc=DMA_PINC_DISABLE;
  d->Init.MemInc=DMA_MINC_ENABLE;
  d->Init.PeriphDataAlignment=DMA_PDATAALIGN_HALFWORD;
  d->Init.MemDataAlignment=DMA_MDATAALIGN_HALFWORD;
  d->Init.Mode=DMA_CIRCULAR;
  d->Init.Priority=DMA_PRIORITY_VERY_HIGH;
  if(HAL_DMA_Init(d)!=HAL_OK) Error_Handler();
  dac->DMA_Handle1=d;
  d->Parent=dac;
}
void DAC_Sine_Init(void)
{
  DAC_ChannelConfTypeDef c={0};
  if(HAL_RCC_GetPCLK1Freq()*2U!=72000000U) Error_Handler();
  __HAL_RCC_DMA1_CLK_ENABLE();
  __HAL_RCC_DMA2_CLK_ENABLE();
  __HAL_RCC_TIM3_CLK_ENABLE();
  __HAL_REMAPTRIGGER_ENABLE(HAL_REMAPDMA_TIM6_DAC1_CH1_DMA1_CH3);
  __HAL_REMAPTRIGGER_DISABLE(HAL_REMAPDMA_TIM18_DAC2_CH1_DMA1_CH5);
  dac_dma(&dma1,DMA1_Channel3,&hdac1);
  dac_dma(&dma2,DMA2_Channel5,&hdac2);
  c.DAC_Trigger=DAC_TRIGGER_T3_TRGO;
  c.DAC_OutputBuffer=DAC_OUTPUTBUFFER_ENABLE;
  if(HAL_DAC_ConfigChannel(&hdac1,&c,DAC_CHANNEL_1)!=HAL_OK ||
     HAL_DAC_ConfigChannel(&hdac2,&c,DAC_CHANNEL_1)!=HAL_OK) Error_Handler();
  build_periods(freq_target);
  build_tables();
  last_service_ms=HAL_GetTick();
}
void DAC_Sine_Start(void)
{
  if(running) return;
  /* After a stop (firmware update) apply the latest settings at once:
   * there is no running phase to continue. */
  a1_q8=(int32_t)a1_target*256; b1_q8=(int32_t)b1_target*256;
  a2_q8=(int32_t)a2_target*256; b2_q8=(int32_t)b2_target*256;
  freq_q8=(int32_t)freq_target*256;
  phase_q8=(int32_t)phase_target*256;
  build_periods(freq_target);
  build_tables();
  last_service_ms=HAL_GetTick();

  TIM3->CR1=0; TIM3->DIER=0; TIM3->CR2=0;
  TIM3->PSC=0; TIM3->CNT=0;
  TIM3->CCR1=1; TIM3->CCR3=1;
  TIM3->CCMR1=0; TIM3->CCMR2=0;
  TIM3->ARR=periods[0];
  TIM3->EGR=TIM_EGR_UG; TIM3->SR=0;
  /* Start just before update: the first TRGO latches sample 0. */
  TIM3->CNT=periods[0];
  DMA1_Channel2->CCR=0;
  DMA1_Channel2->CPAR=(uint32_t)&TIM3->ARR;
  DMA1_Channel2->CMAR=(uint32_t)periods;
  DMA1_Channel2->CNDTR=DAC_SINE_SAMPLES;
  DMA1_Channel2->CCR=DMA_CCR_DIR|DMA_CCR_MINC|DMA_CCR_CIRC|
                         DMA_CCR_PSIZE_0|DMA_CCR_MSIZE_0|DMA_CCR_PL;
  DMA1_Channel6->CCR=0;
  DMA1_Channel6->CPAR=(uint32_t)&SensTrig_GPIO_Port->BSRR;
  DMA1_Channel6->CMAR=(uint32_t)trigger;
  DMA1_Channel6->CNDTR=DAC_SINE_SAMPLES;
  DMA1_Channel6->CCR=DMA_CCR_DIR|DMA_CCR_MINC|DMA_CCR_CIRC|
                         DMA_CCR_PSIZE_1|DMA_CCR_MSIZE_1|DMA_CCR_PL;
  DMA1->IFCR=DMA_IFCR_CGIF2|DMA_IFCR_CGIF6;
  DAC1->SR=DAC_SR_DMAUDR1; DAC2->SR=DAC_SR_DMAUDR1;
  DAC1->DHR12R1=(uint32_t)level_code(a1_q8);
  DAC2->DHR12R1=preload2;
  if(HAL_DAC_Start_DMA(&hdac1,DAC_CHANNEL_1,(uint32_t*)buf1,DAC_SINE_SAMPLES,DAC_ALIGN_12B_R)!=HAL_OK ||
     HAL_DAC_Start_DMA(&hdac2,DAC_CHANNEL_1,(uint32_t*)buf2,DAC_SINE_SAMPLES,DAC_ALIGN_12B_R)!=HAL_OK)
    Error_Handler();
  DMA1_Channel3->CCR &= ~(DMA_CCR_HTIE|DMA_CCR_TCIE|DMA_CCR_TEIE);
  DMA2_Channel5->CCR &= ~(DMA_CCR_HTIE|DMA_CCR_TCIE|DMA_CCR_TEIE);
  DAC1->CR &= ~DAC_CR_DMAUDRIE1; DAC2->CR &= ~DAC_CR_DMAUDRIE1;
  DMA1_Channel2->CCR |= DMA_CCR_EN; DMA1_Channel6->CCR |= DMA_CCR_EN;
  TIM3->CR2=TIM_CR2_MMS_1;
  TIM3->DIER=TIM_DIER_CC1DE|TIM_DIER_CC3DE;
  running=1; TIM3->CR1=TIM_CR1_CEN;
}
void DAC_Sine_Stop(void)
{
  TIM3->CR1=0; TIM3->DIER=0;
  DMA1_Channel2->CCR &= ~DMA_CCR_EN; DMA1_Channel6->CCR &= ~DMA_CCR_EN;
  if(running) {
    (void)HAL_DAC_Stop_DMA(&hdac1,DAC_CHANNEL_1);
    (void)HAL_DAC_Stop_DMA(&hdac2,DAC_CHANNEL_1);
  }
  running=0;
}
uint8_t DAC_Sine_IsRunning(void) { return running; }
uint32_t DAC_Sine_SetFrequency(uint32_t hz)
{
  if(hz<DAC_SINE_FREQ_MIN || hz>DAC_SINE_FREQ_MAX) return 0U;
  freq_target=(uint16_t)hz;
  if(!running) {
    freq_q8=(int32_t)hz*256;
    build_periods(hz);
  }
  return hz;
}
uint32_t DAC_Sine_GetFrequency(void) { return freq_target; }
uint32_t DAC_Sine_GetSampleRate(void) { return (uint32_t)freq_target*DAC_SINE_SAMPLES; }
void DAC_Sine_SetPhaseTenths(int16_t tenths)
{
  if(tenths<-DAC_SINE_PHASE_MAX) tenths=-DAC_SINE_PHASE_MAX;
  if(tenths>DAC_SINE_PHASE_MAX) tenths=DAC_SINE_PHASE_MAX;
  phase_target=tenths;
  if(!running) {
    phase_q8=(int32_t)tenths*256;
    build_tables();
  }
}
int16_t DAC_Sine_GetPhaseTenths(void) { return phase_target; }
/* Levels, frequency and phase only set targets; the service ramps them and
 * rewrites the running DMA tables. Generation is not stopped, so the phase
 * of the sample stream (and of the sine) continues. */
void DAC_Sine_SetLevels(uint16_t x1,uint16_t y1,uint16_t x2,uint16_t y2)
{
  a1_target=clamp_code(x1); b1_target=clamp_code(y1);
  a2_target=clamp_code(x2); b2_target=clamp_code(y2);
  if(!running) {
    a1_q8=(int32_t)a1_target*256; b1_q8=(int32_t)b1_target*256;
    a2_q8=(int32_t)a2_target*256; b2_q8=(int32_t)b2_target*256;
    build_tables();
  }
}
void DAC_Sine_GetLevels(uint16_t *x1,uint16_t *y1,uint16_t *x2,uint16_t *y2)
{
  if(x1) *x1=a1_target;
  if(y1) *y1=b1_target;
  if(x2) *x2=a2_target;
  if(y2) *y2=b2_target;
}
void DAC_Sine_Service(void)
{
  if(!running) return;
  uint32_t now=HAL_GetTick();
  uint32_t dt=now-last_service_ms;
  if(dt==0U) return;
  if(dt>SERVICE_MAX_MS) dt=SERVICE_MAX_MS;
  last_service_ms=now;

  int32_t step=(int32_t)(LEVEL_STEP_Q8*dt);
  int32_t old_a1=a1_q8,old_b1=b1_q8,old_a2=a2_q8,old_b2=b2_q8;
  a1_q8=approach(a1_q8,(int32_t)a1_target*256,step);
  b1_q8=approach(b1_q8,(int32_t)b1_target*256,step);
  a2_q8=approach(a2_q8,(int32_t)a2_target*256,step);
  b2_q8=approach(b2_q8,(int32_t)b2_target*256,step);

  int32_t old_freq=freq_q8;
  freq_q8=approach(freq_q8,(int32_t)freq_target*256,(int32_t)(FREQ_STEP_Q8*dt));
  if((freq_q8>>8)!=(old_freq>>8)) build_periods((uint32_t)(freq_q8>>8));

  int32_t old_phase=phase_q8;
  phase_q8=approach(phase_q8,(int32_t)phase_target*256,(int32_t)(PHASE_STEP_Q8*dt));

  if(a1_q8!=old_a1 || b1_q8!=old_b1 || a2_q8!=old_a2 || b2_q8!=old_b2 ||
     phase_q8!=old_phase) build_tables();
}
uint8_t DAC_Sine_CheckDma(void)
{
  uint8_t e=0;
  if(DAC1->SR&DAC_SR_DMAUDR1) e|=DAC_SINE_DMA1_UNDERRUN;
  if(DAC2->SR&DAC_SR_DMAUDR1) e|=DAC_SINE_DMA2_UNDERRUN;
  if((DMA1->ISR&(DMA_ISR_TEIF2|DMA_ISR_TEIF3|DMA_ISR_TEIF6)) ||
     (DMA2->ISR&DMA_ISR_TEIF5)) e|=DAC_SINE_TRANSFER_ERROR;
  return e;
}
