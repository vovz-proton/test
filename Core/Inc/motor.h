#ifndef MOTOR_H
#define MOTOR_H
#include <stdint.h>
typedef enum {
  MOTOR_MODE_RESET, MOTOR_MODE_HOLD, MOTOR_HOME_SEEK_IN, MOTOR_HOME_OUT, MOTOR_HOME_IN,
  MOTOR_POSITION_OUT, MOTOR_COMPENSATE, MOTOR_READY, MOTOR_SCAN,
  MOTOR_RETURN_OUT, MOTOR_FAULT
} MotorState;
typedef struct {
  volatile MotorState state;
  volatile int32_t position_units;
  volatile uint32_t backlash_units, faults;
  volatile uint8_t position_valid;
  uint8_t returning;
  uint16_t length_tenths_mm;
  uint8_t speed, active_speed;
} MotorStatus;
extern MotorStatus motor_status;
void Motor_Init(void);
void Motor_Poll(void);
typedef enum { MOTOR_OK, MOTOR_BUSY, MOTOR_NOT_SCANNING, MOTOR_ZERO_LENGTH, MOTOR_ERROR } MotorResult;
MotorResult Motor_StartScan(void);
MotorResult Motor_StopScan(void);
void Motor_SetLength(uint16_t tenths_mm);
void Motor_SetSpeed(uint8_t speed);
void Motor_Fault(void);
uint8_t Motor_IsScanning(void);
uint32_t Instrument_Micros(void);
#endif
