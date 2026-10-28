#include "main.h"
#include "motor.h"
#include "instrument_logic.h"

MotorStatus motor_status;
MotorCalibrationStatus motor_calibration;
volatile uint32_t motor_shuttle_strokes;
#if MOTOR_MUSIC_TEST
static uint8_t music_half;
#endif
#if MOTOR_TRAVEL_CAL
static volatile uint8_t cal_armed;
static volatile uint32_t cal_release_us,cal_edge_us;
static uint8_t cal_start_requested;
#endif
#ifdef MotorFAULT_Pin
static volatile uint8_t driver_fault_armed;
static uint8_t driver_fault_active(void)
{
  return (MotorFAULT_GPIO_Port->IDR&MotorFAULT_Pin)==0U;
}
#endif
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
#if BENCH_NO_MECHANICS && !MOTOR_LIMIT_JOG && !MOTOR_SHUTTLE_TEST && !MOTOR_MUSIC_TEST
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
static void disable_driver(void)
{
#ifdef MotorFAULT_Pin
  driver_fault_armed=0;
#endif
  pin(MotorSTBY_GPIO_Port,MotorSTBY_Pin,0);
}
void Motor_Fault(void)
{
#if MOTOR_TRAVEL_CAL
  if(motor_calibration.phase==1U || motor_calibration.phase==2U) motor_calibration.phase=4U;
#endif
  halt();
  disable_driver();
  motor_status.state=MOTOR_FAULT;
  ++motor_status.faults;
}
#ifdef MotorFAULT_Pin
static void driver_fault(void)
{
  if(!driver_fault_armed || motor_status.faults) return;
  ++motor_status.driver_faults;
  Motor_Fault();
}
void EXTI9_5_IRQHandler(void)
{
  if(EXTI->PR&MotorFAULT_Pin) {
    EXTI->PR=MotorFAULT_Pin;
    /* Latch even a pulse which has returned high before ISR entry. */
    driver_fault();
  }
}
#endif
static uint32_t prep_hz(void)
{
  return Motion_PulseHz(0)*(1U<<MOTOR_PREP_SPEED)/(1U<<motor_status.active_speed);
}
static void start_segment(uint8_t out,uint32_t pulses,uint32_t hz,
                          uint8_t watch_limit,uint8_t wanted_active)
{
  GPIO_InitTypeDef g={0};
  if(motor_status.faults) return;
#ifdef MotorFAULT_Pin
  if(driver_fault_armed && driver_fault_active()) { driver_fault(); return; }
#endif
  halt();
  direction=out; left=pulses; emitted=0; done=0; stop_request=0;
  limit_hit=0; confirming=0; limit_enabled=watch_limit; limit_active=wanted_active;
  target_hz=hz;
  current_hz=hz<MOTOR_START_PULSES_HZ?hz:MOTOR_START_PULSES_HZ;
#if MOTOR_MUSIC_TEST
  current_hz=hz; /* Constant STEP pitch; short, slow full-step segments. */
#endif
  accel_hz=Motion_AccelHz(motor_status.active_speed);
#if MOTOR_SHUTTLE_TEST
  /* Bench shuttle: faster acceleration and braking, without changing top speed. */
  accel_hz*=4U;
#endif
  /* Includes acceleration and a fixed margin; PL999 at PS0 needs >400 s. */
  segment_timeout_ms=(uint32_t)((uint64_t)pulses*1000U/hz)+
                     2U*hz*1000U/accel_hz+5000U;
  unit=1U<<motor_status.active_speed;
  move_started=HAL_GetTick(); last_ramp=Instrument_Micros();
  pin(MotorDIR_GPIO_Port,MotorDIR_Pin,out);
  /* Direction setup is satisfied while setting up PWM, before the first edge. */
  TIM2->CR1=0; TIM2->PSC=17; TIM2->ARR=4000000U/current_hz-1U;
  TIM2->CCR2=4; /* 1 us high at 4 MHz; falling-edge IRQ counts completed pulses. */
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
#if MOTOR_MUSIC_TEST
static void start_music_half(void)
{
  static const uint16_t notes[4]={1048U,1176U,1320U,1396U}; /* Previous pitches x2. */
  motor_status.state=MOTOR_SCAN;
  motor_status.position_valid=0;
  motor_status.returning=0;
  uint32_t hz=notes[music_half];
  /* Each pair is one full step out, then one back. About 50 ms per note.
   * No accumulated commanded travel; one-full-step oscillation (~5 um).
   * Limit is not used for this zero-net excitation; FAULT/CC remain active. */
  start_segment(MOTOR_DIR_EXTEND,2U*((hz*50U+500U)/1000U),2U*hz,0U,0U);
}
#endif
#if MOTOR_SHUTTLE_TEST
static void start_shuttle(uint8_t dir)
{
  motor_status.state=MOTOR_SCAN;
  motor_status.position_valid=0;
  motor_status.returning=dir==MOTOR_DIR_RETRACT;
  uint32_t scale=1U<<motor_status.active_speed;
  start_segment(dir,(MOTOR_SHUTTLE_PULSES+scale/2U)/scale,MOTOR_SHUTTLE_HZ/scale,
                dir==MOTOR_DIR_RETRACT,1);
}
#endif
#if MOTOR_LIMIT_JOG
static void start_limit_jog(void)
{
#if MOTOR_TRAVEL_CAL
  motor_calibration.phase=1U;
  motor_calibration.pulse_hz=Motion_PulseHz(motor_status.active_speed)*5U;
  cal_armed=0; cal_release_us=0;
  motor_status.state=MOTOR_SCAN;
  motor_status.position_valid=0;
  start_segment(0,UINT32_MAX,motor_calibration.pulse_hz,0,1);
#else
  uint8_t active=sensor_active();
  motor_status.state=MOTOR_SCAN;
  motor_status.position_valid=0;
  /* Green/high -> DIR=0; red/low -> DIR=1. No finite travel in this bench mode. */
  start_segment(active,UINT32_MAX,Motion_PulseHz(motor_status.active_speed),1,!active);
#endif
}
#endif
void TIM2_IRQHandler(void)
{
  if(!(TIM2->SR&TIM_SR_CC2IF)) return;
  TIM2->SR=~TIM_SR_CC2IF;
  if(!busy) return;
  ++emitted;
#if MOTOR_LIMIT_JOG || MOTOR_SHUTTLE_TEST || MOTOR_MUSIC_TEST
  /* No fictitious position accumulation during an unbounded bench run. */
  if(motor_status.state!=MOTOR_SCAN)
#endif
    motor_status.position_units += direction?(int32_t)unit:-(int32_t)unit;
  if(left) --left;
#if MOTOR_TRAVEL_CAL
  if(motor_status.state==MOTOR_SCAN) {
    uint32_t now=Instrument_Micros();
    if(!sensor_active()) {
      if(!cal_release_us) cal_release_us=now;
      if((uint32_t)(now-cal_release_us)>=5000U) cal_armed=1U;
    } else {
      cal_release_us=0;
      if(cal_armed) {
        cal_armed=0;
        cal_edge_us=now;
        limit_hit=1;
      }
    }
  } else
#endif
  if(limit_enabled && sensor_active()==limit_active) limit_hit=1;
  if(!left || stop_request || limit_hit) { halt(); done=1; }
#if MOTOR_MUSIC_TEST
  else {
    /* Change DIR after STEP falls, leaving the entire low phase for setup. */
    direction^=1U;
    pin(MotorDIR_GPIO_Port,MotorDIR_Pin,direction);
  }
#endif
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
  disable_driver();
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
  motor_shuttle_strokes=0;
#if MOTOR_MUSIC_TEST
  music_half=0;
#endif
  GPIO_InitTypeDef sensor={0};
  sensor.Pin=Konc_Pin; sensor.Mode=GPIO_MODE_INPUT;
  sensor.Pull=GPIO_NOPULL; /* External +5V pull-up: never enable internal pulls. */
  HAL_GPIO_Init(Konc_GPIO_Port,&sensor);
#ifdef MotorFAULT_Pin
  /* External EN/FAULT pull-up and RC: never drive the shared line high. */
  sensor.Pin=MotorFAULT_Pin; sensor.Mode=GPIO_MODE_IT_FALLING;
  sensor.Pull=GPIO_NOPULL;
  HAL_GPIO_Init(MotorFAULT_GPIO_Port,&sensor);
  EXTI->PR=MotorFAULT_Pin;
  HAL_NVIC_SetPriority(EXTI9_5_IRQn,0,0);
  HAL_NVIC_EnableIRQ(EXTI9_5_IRQn);
#endif
  __HAL_RCC_TIM2_CLK_ENABLE(); __HAL_RCC_TIM5_CLK_ENABLE();
  TIM5->CR1=0; TIM5->PSC=71; TIM5->ARR=0xFFFFFFFFU;
  TIM5->EGR=TIM_EGR_UG; TIM5->CNT=0; TIM5->CR1=TIM_CR1_CEN;
  motor_status.length_tenths_mm=DEFAULT_LENGTH_TENTHS_MM;
  motor_status.speed=DEFAULT_SPEED;
#if MOTOR_SHUTTLE_TEST
  motor_status.speed=MOTOR_SHUTTLE_MODE;
#endif
#if MOTOR_MUSIC_TEST
  motor_status.speed=8U; /* Full-step mode for audible coil excitation. */
#endif
#if MOTOR_TRAVEL_CAL
  cal_start_requested=0;
#endif
  HAL_NVIC_SetPriority(TIM2_IRQn,1,0);
  HAL_NVIC_EnableIRQ(TIM2_IRQn);
  if(MOTOR_DISABLED) {
    halt();
    disable_driver();
    step_gpio();
    pin(MotorCLK_GPIO_Port,MotorCLK_Pin,0);
    motor_status.state=MOTOR_READY;
    motor_status.position_valid=0;
    return;
  }
  begin_mode();
}
void Motor_SetLength(uint16_t n) { if(!MOTOR_SHUTTLE_TEST && n<=999U) motor_status.length_tenths_mm=n; }
void Motor_SetSpeed(uint8_t s) { if(!MOTOR_SHUTTLE_TEST && s<=8U) motor_status.speed=s; }
uint8_t Motor_IsScanning(void) { return motor_status.state==MOTOR_SCAN; }
MotorResult Motor_StartScan(void)
{
  if(MOTOR_DISABLED) return MOTOR_ERROR;
  if(motor_status.faults || motor_status.state==MOTOR_FAULT) return MOTOR_ERROR;
#if MOTOR_SHUTTLE_TEST || MOTOR_MUSIC_TEST
  if(motor_status.state!=MOTOR_READY || !mode_valid) return MOTOR_BUSY;
  motor_shuttle_strokes=0;
#if MOTOR_MUSIC_TEST
  music_half=0;
#endif
  begin_mode();
  return MOTOR_OK;
#endif
#if MOTOR_TRAVEL_CAL
  if(motor_status.state!=MOTOR_READY || !mode_valid) return MOTOR_BUSY;
  motor_calibration.phase=0;
  motor_calibration.start_us=0; motor_calibration.end_us=0;
  motor_calibration.elapsed_us=0; motor_calibration.pulses=0;
  cal_start_requested=1;
  begin_mode();
  return MOTOR_OK;
#endif
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
  if(left<=braking && (!limit_enabled || MOTOR_SHUTTLE_TEST)) {
    uint32_t floor=target_hz<MOTOR_START_PULSES_HZ?target_hz:MOTOR_START_PULSES_HZ;
    current_hz=current_hz>floor+change?current_hz-change:floor;
  } else if(current_hz<target_hz) {
    current_hz=target_hz-current_hz>change?current_hz+change:target_hz;
  }
  TIM2->ARR=4000000U/current_hz-1U; /* Buffered until overflow, no runt pulse. */
}
void Motor_Poll(void)
{
  if(MOTOR_DISABLED) {
    halt();
    disable_driver();
    return;
  }
#ifdef MotorFAULT_Pin
  if(driver_fault_armed && driver_fault_active()) driver_fault();
#endif
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
#if MOTOR_TRAVEL_CAL
      if(!cal_start_requested) {
        mode_valid=1;
        disable_driver();
        motor_status.state=MOTOR_READY;
        return;
      }
#endif
#ifdef MotorFAULT_Pin
      EXTI->PR=MotorFAULT_Pin;
      driver_fault_armed=1;
      if(driver_fault_active()) { driver_fault(); return; }
#endif
      mode_valid=1;
#if MOTOR_MUSIC_TEST
      start_music_half();
#elif MOTOR_SHUTTLE_TEST
      start_shuttle(MOTOR_DIR_EXTEND);
#elif MOTOR_TRAVEL_CAL
      if(cal_start_requested) {
        cal_start_requested=0;
        start_limit_jog();
      } else {
        disable_driver();
        motor_status.state=MOTOR_READY;
      }
#elif MOTOR_LIMIT_JOG
      start_limit_jog();
#elif BENCH_NO_MECHANICS
      bench_zero_here();
#else
      begin_homing();
#endif
    }
    return;
  }
  if(state==MOTOR_READY) {
#if MOTOR_SHUTTLE_TEST || MOTOR_MUSIC_TEST
    return;
#endif
#if MOTOR_TRAVEL_CAL
    /* Completed/cancelled measurement stays stopped until an explicit reset. */
    return;
#endif
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
#if MOTOR_LIMIT_JOG
  if(state!=MOTOR_SCAN)
#endif
  if((uint32_t)(HAL_GetTick()-move_started)>timeout) { Motor_Fault(); return; }
  if(busy) {
    if(!MOTOR_MUSIC_TEST) ramp();
    return;
  }
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
#if MOTOR_MUSIC_TEST
  if(state==MOTOR_SCAN) {
    uint32_t guard=__get_PRIMASK(); __disable_irq();
    if(motor_status.faults) { __set_PRIMASK(guard); return; }
    if(stop_request || limit_hit || ++music_half>=4U) {
      disable_driver();
      motor_status.returning=0;
      motor_status.state=MOTOR_READY;
    } else {
      start_music_half();
    }
    __set_PRIMASK(guard);
    return;
  }
#endif
#if MOTOR_SHUTTLE_TEST
  if(state==MOTOR_SCAN) {
    uint32_t guard=__get_PRIMASK(); __disable_irq();
    if(motor_status.faults) { __set_PRIMASK(guard); return; }
    if(stop_request) {
      disable_driver();
      motor_status.returning=0;
      motor_status.state=MOTOR_READY;
    } else {
      ++motor_shuttle_strokes;
      if(motor_shuttle_strokes>=2U) {
        disable_driver();
        motor_status.returning=0;
        motor_status.state=MOTOR_READY;
      } else {
        start_shuttle(MOTOR_DIR_RETRACT);
      }
    }
    __set_PRIMASK(guard);
    return;
  }
#endif
#if MOTOR_LIMIT_JOG
  if(state==MOTOR_SCAN) {
    uint32_t guard=__get_PRIMASK(); __disable_irq();
    if(motor_status.faults) { __set_PRIMASK(guard); return; }
    if(stop_request) {
#if MOTOR_TRAVEL_CAL
      motor_calibration.phase=4U;
      disable_driver();
#endif
      motor_status.state=MOTOR_READY;
      __set_PRIMASK(guard);
      return;
    }
#if MOTOR_TRAVEL_CAL
    if(motor_calibration.phase==1U) {
      cal_armed=0; cal_release_us=0;
      motor_calibration.start_us=Instrument_Micros();
      motor_calibration.phase=2U;
      start_segment(1,UINT32_MAX,motor_calibration.pulse_hz,0,1);
    } else if(motor_calibration.phase==2U) {
      motor_calibration.end_us=cal_edge_us;
      motor_calibration.elapsed_us=cal_edge_us-motor_calibration.start_us;
      motor_calibration.pulses=emitted;
      motor_calibration.phase=3U;
      disable_driver();
      motor_status.state=MOTOR_READY;
    }
#else
    start_limit_jog();
#endif
    __set_PRIMASK(guard);
    return;
  }
#endif
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
