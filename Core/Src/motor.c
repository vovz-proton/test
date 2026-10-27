#include "main.h"
#include "motor.h"
#include "instrument_logic.h"

MotorStatus motor_status;
typedef struct { uint8_t step,dir,m1,m2; } Mode;
/* STSPIN220 DS11633 rev5 table 8, order speed 0..8. */
static const Mode modes[9]={
  {0,0,1,1},{0,0,1,0},{0,1,1,1},{0,0,0,1},
  {1,1,1,1},{1,0,1,1},{0,1,0,1},{1,0,1,0},{0,0,0,0}
};
static volatile uint32_t left,emitted,unit;
static volatile uint8_t busy,done,stop_request,limit_hit;
static uint8_t direction,limit_enabled,limit_active;
static uint32_t target_hz,current_hz,accel_hz,move_started,last_ramp;
static uint32_t segment_timeout_ms;
static uint32_t mode_time,limit_time;
static uint8_t confirming,mode_valid;
static uint32_t configured_length;

uint32_t Instrument_Micros(void) { return TIM5->CNT; }
static uint8_t sensor_active(void)
{
#if BENCH_NO_MECHANICS
  /* Настольный режим: датчик считается всегда неактивным ("железа нет"). */
  return 0U;
#else
  return ((Konc_GPIO_Port->IDR&Konc_Pin)?1U:0U)==KONC_ACTIVE_LEVEL;
#endif
}
static void pin(GPIO_TypeDef *port,uint16_t p,uint8_t high)
{
  port->BSRR=high?p:(uint32_t)p<<16;
}
static void step_gpio(void)
{
  GPIO_InitTypeDef g={0};
  g.Pin=MotorCLK_Pin; g.Mode=GPIO_MODE_OUTPUT_PP;
  g.Pull=GPIO_NOPULL; g.Speed=GPIO_SPEED_FREQ_HIGH;
  HAL_GPIO_Init(MotorCLK_GPIO_Port,&g);
}
static void halt(void)
{
  TIM2->DIER=0; TIM2->CR1=0; TIM2->CCER=0;
  busy=0;
}
void Motor_Fault(void)
{
  halt();
  pin(MotorSTBY_GPIO_Port,MotorSTBY_Pin,0);
  motor_status.state=MOTOR_FAULT;
  ++motor_status.faults;
}
static uint32_t prep_hz(void)
{
  return Motion_PulseHz(0)*(1U<<MOTOR_PREP_SPEED)/(1U<<motor_status.active_speed);
}
static void start_segment(uint8_t out,uint32_t pulses,uint32_t hz,
                          uint8_t watch_limit,uint8_t wanted_active)
{
  GPIO_InitTypeDef g={0};
  if(motor_status.faults) return;
  halt();
  direction=out; left=pulses; emitted=0; done=0; stop_request=0;
  limit_hit=0; confirming=0; limit_enabled=watch_limit; limit_active=wanted_active;
  target_hz=hz;
  current_hz=hz<MOTOR_START_PULSES_HZ?hz:MOTOR_START_PULSES_HZ;
  accel_hz=Motion_AccelHz(motor_status.active_speed);
  /* Includes acceleration and a fixed margin; PL999 at PS0 needs >400 s. */
  segment_timeout_ms=(uint32_t)((uint64_t)pulses*1000U/hz)+
                     2U*hz*1000U/accel_hz+5000U;
  unit=1U<<motor_status.active_speed;
  move_started=HAL_GetTick(); last_ramp=Instrument_Micros();
  pin(MotorDIR_GPIO_Port,MotorDIR_Pin,out);
  /* Direction setup is satisfied while setting up PWM, before the first edge. */
  TIM2->CR1=0; TIM2->PSC=71; TIM2->ARR=1000000U/current_hz-1U;
  TIM2->CCR2=8; /* 8 us high; falling-edge IRQ counts completed pulses. */
  TIM2->CCMR1=TIM_CCMR1_OC2M_1|TIM_CCMR1_OC2M_2;
  TIM2->CCER=0; TIM2->EGR=TIM_EGR_UG;
  TIM2->CNT=TIM2->CCR2; /* Start low; first overflow generates the first pulse. */
  TIM2->SR=0;
  pin(MotorCLK_GPIO_Port,MotorCLK_Pin,0);
  g.Pin=MotorCLK_Pin; g.Mode=GPIO_MODE_AF_PP; g.Pull=GPIO_NOPULL;
  g.Speed=GPIO_SPEED_FREQ_HIGH; g.Alternate=GPIO_AF1_TIM2;
  HAL_GPIO_Init(MotorCLK_GPIO_Port,&g);
  if(!pulses) { done=1; return; }
  if(watch_limit && sensor_active()==wanted_active) {
    limit_hit=1; done=1; return;
  }
  uint32_t mask=__get_PRIMASK(); __disable_irq();
  if(!motor_status.faults) {
    busy=1;
    TIM2->CCER=TIM_CCER_CC2E;
    TIM2->DIER=TIM_DIER_CC2IE;
    TIM2->CR1=TIM_CR1_ARPE|TIM_CR1_CEN;
  }
  __set_PRIMASK(mask);
}
void TIM2_IRQHandler(void)
{
  if(!(TIM2->SR&TIM_SR_CC2IF)) return;
  TIM2->SR=~TIM_SR_CC2IF;
  if(!busy) return;
  ++emitted;
  motor_status.position_units += direction?(int32_t)unit:-(int32_t)unit;
  if(left) --left;
  if(limit_enabled && sensor_active()==limit_active) limit_hit=1;
  if(!left || stop_request || limit_hit) { halt(); done=1; }
}
static uint32_t ceil_pulses(uint32_t units)
{
  uint32_t u=1U<<motor_status.active_speed;
  return (units+u-1U)/u;
}
static uint32_t compensation(void)
{
  return ceil_pulses(motor_status.backlash_units)*(1U<<motor_status.active_speed);
}
static void position_out(MotorState state)
{
  uint16_t length=state==MOTOR_RETURN_OUT?(uint16_t)configured_length:motor_status.length_tenths_mm;
  int32_t destination=(int32_t)Motion_LengthUnits(length)+(int32_t)compensation();
  int32_t distance=destination-motor_status.position_units;
  if(distance<0) { Motor_Fault(); return; }
  motor_status.state=state;
  motor_status.returning=state==MOTOR_RETURN_OUT;
  configured_length=length;
  start_segment(1,ceil_pulses((uint32_t)distance),prep_hz(),0,0);
}
static void begin_mode(void)
{
  halt(); step_gpio();
  motor_status.position_valid=0;
  motor_status.returning=0;
  pin(MotorSTBY_GPIO_Port,MotorSTBY_Pin,0);
  motor_status.active_speed=motor_status.speed;
  const Mode *m=&modes[motor_status.active_speed];
  pin(MotorCLK_GPIO_Port,MotorCLK_Pin,m->step);
  pin(MotorDIR_GPIO_Port,MotorDIR_Pin,m->dir);
  pin(MotorM1_GPIO_Port,MotorM1_Pin,m->m1);
  pin(MotorM2_GPIO_Port,MotorM2_Pin,m->m2);
  mode_time=Instrument_Micros();
  motor_status.state=MOTOR_MODE_RESET;
  mode_valid=0;
}
#if !BENCH_NO_MECHANICS
static void begin_homing(void)
{
  motor_status.position_valid=0;
  motor_status.position_units=0;
  motor_status.state=MOTOR_HOME_SEEK_IN;
  /* First establish the metal-detected end, even if powered up extended.
   * If already active, start_segment emits NO pulses: just confirm the level.
   * Only the subsequent release/reacquire motion is measured as backlash. */
  start_segment(0,ceil_pulses(Motion_LengthUnits(MOTOR_HOME_MAX_TENTHS_MM)),prep_hz(),1,1);
}
#else
/* Настольный режим: нуль считается достигнутым на текущем месте, компенсация
 * люфта равна нулю. Заменяет всю процедуру поиска концевика. */
static void bench_zero_here(void)
{
  motor_status.position_units=0;
  motor_status.backlash_units=0;
  motor_status.position_valid=1;
  motor_status.returning=0;
  configured_length=motor_status.length_tenths_mm;
  motor_status.state=MOTOR_READY;
}
#endif
void Motor_Init(void)
{
  GPIO_InitTypeDef sensor={0};
  sensor.Pin=Konc_Pin; sensor.Mode=GPIO_MODE_INPUT;
  sensor.Pull=GPIO_NOPULL; /* External +5V pull-up: never enable internal pulls. */
  HAL_GPIO_Init(Konc_GPIO_Port,&sensor);
  __HAL_RCC_TIM2_CLK_ENABLE(); __HAL_RCC_TIM5_CLK_ENABLE();
  TIM5->CR1=0; TIM5->PSC=71; TIM5->ARR=0xFFFFFFFFU;
  TIM5->EGR=TIM_EGR_UG; TIM5->CNT=0; TIM5->CR1=TIM_CR1_CEN;
  motor_status.length_tenths_mm=DEFAULT_LENGTH_TENTHS_MM;
  motor_status.speed=DEFAULT_SPEED;
  HAL_NVIC_SetPriority(TIM2_IRQn,1,0);
  HAL_NVIC_EnableIRQ(TIM2_IRQn);
  begin_mode();
}
void Motor_SetLength(uint16_t n) { if(n<=999U) motor_status.length_tenths_mm=n; }
void Motor_SetSpeed(uint8_t s) { if(s<=8U) motor_status.speed=s; }
uint8_t Motor_IsScanning(void) { return motor_status.state==MOTOR_SCAN; }
MotorResult Motor_StartScan(void)
{
  if(motor_status.faults || motor_status.state==MOTOR_FAULT) return MOTOR_ERROR;
  if(motor_status.state!=MOTOR_READY || !mode_valid || !motor_status.position_valid) return MOTOR_BUSY;
  if(!motor_status.length_tenths_mm) return MOTOR_ZERO_LENGTH;
  if(motor_status.speed!=motor_status.active_speed || configured_length!=motor_status.length_tenths_mm) return MOTOR_BUSY;
  motor_status.state=MOTOR_SCAN;
  /* Stop normally on KONC. Bound excess travel if KONC fails. */
  uint32_t max=Motion_LengthUnits(motor_status.length_tenths_mm+MOTOR_BACKLASH_MAX_TENTHS_MM);
  start_segment(0,ceil_pulses(max),Motion_PulseHz(motor_status.active_speed),1,1);
  return motor_status.faults?MOTOR_ERROR:MOTOR_OK;
}
MotorResult Motor_StopScan(void)
{
  if(motor_status.faults || motor_status.state==MOTOR_FAULT) return MOTOR_ERROR;
  if(motor_status.state!=MOTOR_SCAN) return MOTOR_NOT_SCANNING;
  stop_request=1;
  return MOTOR_OK;
}
static void ramp(void)
{
  uint32_t now=Instrument_Micros(),dt=now-last_ramp;
  if(dt<1000U) return;
  last_ramp=now;
  uint32_t change=(uint32_t)((uint64_t)accel_hz*dt/1000000U);
  if(!change) change=1;
  /* Brake before finite positioning endpoints. KONC/CC stop immediately. */
  uint32_t braking=(uint32_t)((uint64_t)current_hz*current_hz/(2U*accel_hz));
  if(left<=braking && !limit_enabled) {
    uint32_t floor=target_hz<MOTOR_START_PULSES_HZ?target_hz:MOTOR_START_PULSES_HZ;
    current_hz=current_hz>floor+change?current_hz-change:floor;
  } else if(current_hz<target_hz) {
    current_hz=target_hz-current_hz>change?current_hz+change:target_hz;
  }
  TIM2->ARR=1000000U/current_hz-1U; /* Buffered until overflow, no runt pulse. */
}
void Motor_Poll(void)
{
  MotorState state=motor_status.state;
  uint32_t now=Instrument_Micros();
  if(motor_status.faults) { motor_status.state=MOTOR_FAULT; return; }
  if(state==MOTOR_FAULT) return;
  if(state==MOTOR_MODE_RESET) {
    if((uint32_t)(now-mode_time)>=1000U) {
      uint32_t mask=__get_PRIMASK(); __disable_irq();
      if(!motor_status.faults) pin(MotorSTBY_GPIO_Port,MotorSTBY_Pin,1);
      __set_PRIMASK(mask);
      mode_time=now; motor_status.state=MOTOR_MODE_HOLD;
    }
    return;
  }
  if(state==MOTOR_MODE_HOLD) {
    /* >=100 us hold of ALL four mode pins after STBY rising. */
    if((uint32_t)(now-mode_time)>=1000U) {
      mode_valid=1;
#if BENCH_NO_MECHANICS
      bench_zero_here();
#else
      begin_homing();
#endif
    }
    return;
  }
  if(state==MOTOR_READY) {
    /* Mode resets invalidate position, so select mode and home before moving. */
    if(motor_status.speed!=motor_status.active_speed) begin_mode();
    else if(configured_length!=motor_status.length_tenths_mm) {
#if BENCH_NO_MECHANICS
      /* Без механики повторная подготовка мгновенная: нуль здесь же. */
      bench_zero_here();
#else
      /* Re-home also handles shortening L without an unmodelled reversal. */
      begin_homing();
#endif
    }
    return;
  }
  uint32_t timeout=segment_timeout_ms;
  if((uint32_t)(HAL_GetTick()-move_started)>timeout) { Motor_Fault(); return; }
  if(busy) { ramp(); return; }
  if(!done) return;
  /* CC also wins while stopped for optical-level confirmation. */
  if(state==MOTOR_SCAN && stop_request) limit_hit=0;
  if(limit_hit) {
    if(!confirming) { confirming=1; limit_time=now; }
    if(sensor_active()!=limit_active) {
      /* Optical glitch: resume the remaining segment without resetting mode. */
      uint32_t saved=emitted,remaining=left,started=move_started,timeout_ms=segment_timeout_ms;
      start_segment(direction,remaining,target_hz,limit_enabled,limit_active);
      emitted+=saved;
      move_started=started;
      segment_timeout_ms=timeout_ms;
      return;
    }
    if((uint32_t)(now-limit_time)<KONC_CONFIRM_US) return;
  }
  done=0;
  if(state==MOTOR_HOME_SEEK_IN) {
    if(!limit_hit) { Motor_Fault(); return; }
    motor_status.position_units=0;
    motor_status.state=MOTOR_HOME_OUT;
    start_segment(1,ceil_pulses(Motion_LengthUnits(MOTOR_HOME_MAX_TENTHS_MM)),prep_hz(),1,0);
  } else if(state==MOTOR_HOME_OUT) {
    if(!limit_hit) { Motor_Fault(); return; }
    motor_status.state=MOTOR_HOME_IN;
    start_segment(0,ceil_pulses(Motion_LengthUnits(MOTOR_BACKLASH_MAX_TENTHS_MM)),prep_hz(),1,1);
  } else if(state==MOTOR_HOME_IN) {
    if(!limit_hit) { Motor_Fault(); return; }
    motor_status.backlash_units=emitted*(1U<<motor_status.active_speed);
    motor_status.position_units=0;
    motor_status.position_valid=1;
    position_out(MOTOR_POSITION_OUT);
  } else if(state==MOTOR_POSITION_OUT || state==MOTOR_RETURN_OUT) {
    motor_status.state=MOTOR_COMPENSATE;
    start_segment(0,ceil_pulses(compensation()),prep_hz(),0,0);
  } else if(state==MOTOR_COMPENSATE) {
    motor_status.returning=0;
    motor_status.state=MOTOR_READY;
  } else if(state==MOTOR_SCAN) {
#if BENCH_NO_MECHANICS
    /* Без концевика трасса считается штатно законченной, когда исчерпаны
     * импульсы ограничителя хода: дальше обычный возврат на L. */
    if(!stop_request && !limit_hit) limit_hit=1;
#endif
    if(!limit_hit && !stop_request) { Motor_Fault(); return; }
    if(limit_hit) motor_status.position_units=0;
    position_out(MOTOR_RETURN_OUT);
  }
}
