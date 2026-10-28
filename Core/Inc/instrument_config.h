#ifndef INSTRUMENT_CONFIG_H
#define INSTRUMENT_CONFIG_H
/* Board/mechanics settings. Distances use 1/256 full-step units internally. */
/* Версия прошивки: попадает в приветствие по COM и видна при обновлении. */
#define FIRMWARE_VERSION "1.002"
#define FILTER_N 32U
#define SDADC_RATE_HZ 50000U
#define DEFAULT_LENGTH_TENTHS_MM 20U
#define DEFAULT_SPEED 0U
#ifndef MOTOR_DISABLED
#define MOTOR_DISABLED 0
#endif
/* Dedicated bench build: continuous direction selected by the raw limit input. */
#ifndef MOTOR_LIMIT_JOG
#define MOTOR_LIMIT_JOG 0
#endif
#ifndef MOTOR_TRAVEL_CAL
#define MOTOR_TRAVEL_CAL 0
#endif
#ifndef MOTOR_SHUTTLE_TEST
#define MOTOR_SHUTTLE_TEST 0
#endif
#ifndef MOTOR_MUSIC_TEST
#define MOTOR_MUSIC_TEST 0
#endif
/* Corrected by direct observation of the shuttle's FIRST (DIR=0) movement. */
#define MOTOR_DIR_EXTEND 1U
#define MOTOR_DIR_RETRACT 0U
/* 1547788 pulses measured over 30850 um, PS0 = 1/256 microstep. */
#define MOTOR_SHUTTLE_PULSES ((uint32_t)((1547788ULL*10000U+15425U)/30850U))
/* Speed in equivalent 1/256 pulses/s; actual STEP scales with subdivision. */
#define MOTOR_SHUTTLE_HZ 1445600U
#define MOTOR_SHUTTLE_MODE 2U /* 1/64 microstep. */
#define FULL_STEPS_PER_TRAVEL 1200U
#define TRAVEL_TENTHS_MM 85U
/* GP2S700HCP: emitter to GND, collector PF7 with external R35=4.7k to +5V.
 * Reflecting metal = active LOW = fully retracted; no metal = HIGH.
 * GPIO must use NOPULL to preserve PF7's 5V input tolerance. */
#define KONC_ACTIVE_LEVEL 0U
#define KONC_CONFIRM_US 100U
#define MOTOR_ACCEL_MM_S2 20U
#define MOTOR_START_PULSES_HZ 100U
#define MOTOR_PREP_SPEED 2U /* 1 mm/s, still at 1/256 subdivision */
#define MOTOR_HOME_MAX_TENTHS_MM 400U
#define MOTOR_BACKLASH_MAX_TENTHS_MM 20U
/* 1: board test without a connected limit switch. Motor STEP/ramp/return
 * remain enabled; only homing and sensor checks are bypassed.
 * 0: real mechanics, homing and backlash compensation.
 * Host tests explicitly select the real motor implementation. */
#ifndef BENCH_NO_MECHANICS
#define BENCH_NO_MECHANICS 1
#endif
#define COMMAND_TIMEOUT_MS 250U
#define LED_FRAME_US 1000U /* 1 kHz temporal dithering, not bit interrupts */
#define LED_RESET_US 350U
#define LED_BLINK_HALF_MS 250U /* 2 Hz, 50 percent duty cycle */
#define LED_BRIGHTNESS_PERCENT 5U /* 95 percent dimmer than full output */
#if LED_FRAME_US < LED_RESET_US + 40U || LED_RESET_US < 300U
#error LED frame period must include data plus at least 300 us reset low
#endif
#if FILTER_N < 6 || FILTER_N > 128
#error FILTER_N must be in 6..128
#endif
#endif
