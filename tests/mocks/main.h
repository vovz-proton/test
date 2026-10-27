#ifndef MOCK_MAIN_H
#define MOCK_MAIN_H
#include <stdint.h>
typedef struct { volatile uint32_t CR1,PSC,ARR,EGR,CNT,SR,DIER,CCR2,CCMR1,CCER; } Timer;
typedef struct { volatile uint32_t IDR,BSRR; } GPIO_TypeDef;
typedef struct { uint32_t Pin,Mode,Pull,Speed,Alternate; } GPIO_InitTypeDef;
extern Timer timer2,timer5;
extern GPIO_TypeDef portb,portf;
#define TIM2 (&timer2)
#define TIM5 (&timer5)
#define MotorCLK_Pin (1U<<3)
#define MotorDIR_Pin (1U<<4)
#define MotorM1_Pin (1U<<5)
#define MotorM2_Pin (1U<<6)
#define MotorSTBY_Pin (1U<<7)
#define MotorCLK_GPIO_Port (&portb)
#define MotorDIR_GPIO_Port (&portb)
#define MotorM1_GPIO_Port (&portb)
#define MotorM2_GPIO_Port (&portb)
#define MotorSTBY_GPIO_Port (&portb)
#define Konc_Pin (1U<<7)
#define Konc_GPIO_Port (&portf)
#define GPIO_MODE_OUTPUT_PP 1U
#define GPIO_MODE_AF_PP 2U
#define GPIO_MODE_INPUT 0U
#define GPIO_NOPULL 0U
#define GPIO_PULLUP 1U
#define GPIO_PULLDOWN 2U
#define GPIO_SPEED_FREQ_HIGH 3U
#define GPIO_AF1_TIM2 1U
#define TIM2_IRQn 28U
#define TIM_EGR_UG 1U
#define TIM_CCMR1_OC2M_1 (1U<<13)
#define TIM_CCMR1_OC2M_2 (1U<<14)
#define TIM_CCER_CC2E (1U<<4)
#define TIM_DIER_CC2IE (1U<<2)
#define TIM_CR1_ARPE (1U<<7)
#define TIM_CR1_CEN 1U
#define TIM_SR_CC2IF (1U<<2)
#define __HAL_RCC_TIM2_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM5_CLK_ENABLE() ((void)0)
#define __get_PRIMASK() 0U
#define __disable_irq() ((void)0)
#define __set_PRIMASK(x) ((void)(x))
#define __DMB() ((void)0)
uint32_t HAL_GetTick(void);
void HAL_GPIO_Init(GPIO_TypeDef *p,GPIO_InitTypeDef *g);
void HAL_NVIC_SetPriority(uint32_t irq,uint32_t p,uint32_t s);
void HAL_NVIC_EnableIRQ(uint32_t irq);
#endif
