#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "main.h"
#include "instrument_logic.h"
#include "motor.h"
#include "led_color.h"
#include "serial_protocol.h"
#include "instrument_app.h"
#include "acquisition.h"
#include "usbd_cdc.h"
#include "hex_line.h"
Timer timer2,timer5;
GPIO_TypeDef portb,portf;
static uint64_t time_us;
static uint32_t sensor_pull,sensor_mode;
uint32_t HAL_GetTick(void) { return (uint32_t)(time_us/1000U); }
void HAL_GPIO_Init(GPIO_TypeDef *p,GPIO_InitTypeDef *g)
{
  if(p==Konc_GPIO_Port && g->Pin==Konc_Pin) { sensor_pull=g->Pull; sensor_mode=g->Mode; }
}
void HAL_NVIC_SetPriority(uint32_t i,uint32_t p,uint32_t s) { (void)i;(void)p;(void)s; }
void HAL_NVIC_EnableIRQ(uint32_t i) { (void)i; }
void TIM2_IRQHandler(void);
/* Уровни ЦАП: dac_sine.c в хостовые тесты не входит, поэтому здесь заглушки. */
static uint16_t mock_a1=2048,mock_b1=1000,mock_a2=2048,mock_b2=1000;
void DAC_Sine_GetLevels(uint16_t *a1,uint16_t *b1,uint16_t *a2,uint16_t *b2)
{
  *a1=mock_a1; *b1=mock_b1; *a2=mock_a2; *b2=mock_b2;
}
void DAC_Sine_SetLevels(uint16_t a1,uint16_t b1,uint16_t a2,uint16_t b2)
{
  mock_a1=a1; mock_b1=b1; mock_a2=a2; mock_b2=b2;
}
/* Обновление по ПО по USB: в тестах режим загрузки только отмечается. */
static unsigned upload_requests;
uint8_t Firmware_StartUpload(void) { ++upload_requests; return 1U; }
uint8_t Firmware_UploadCanReceive(void) { return 1U; }
uint8_t Firmware_UploadActive(void) { return 0U; }
void Firmware_UploadBytes(const uint8_t *data,uint32_t length) { (void)data;(void)length; }
void Firmware_UploadService(void) { }
void Firmware_UploadAbort(void) { }
static void advance(uint32_t us) { time_us+=us; timer5.CNT=(uint32_t)time_us; }
static int cmp(const void *a,const void *b) { return (int)*(const int16_t*)a-*(const int16_t*)b; }
static void hexlines(void)
{
  HexLine r;
  uint32_t ext=0U;
  /* запись старшего адреса (тип 04) */
  assert(HexLine_Parse(":020000040800F2",&r,&ext)==1U);
  assert(r.type==0x04U && ext==0x08000000U);
  /* запись данных: 16 байт 00..0F по адресу 0x08000000 */
  assert(HexLine_Parse(":10000000000102030405060708090A0B0C0D0E0F78",&r,&ext)==1U);
  assert(r.type==0x00U && r.length==16U && r.address==0x08000000U);
  assert(r.data[0]==0x00U && r.data[15]==0x0FU);
  /* конец файла */
  assert(HexLine_Parse(":00000001FF",&r,&ext)==1U && r.type==0x01U);
  /* битая контрольная сумма */
  assert(HexLine_Parse(":10000000000102030405060708090A0B0C0D0E0F79",&r,&ext)==0U);
  /* мусор и пустая строка */
  assert(HexLine_Parse("Z=123,X=0.000000",&r,&ext)==0U);
  assert(HexLine_Parse("",&r,&ext)==0U);
  /* без записи типа 04 адрес остаётся 16-битным */
  ext=0U;
  assert(HexLine_Parse(":10000000000102030405060708090A0B0C0D0E0F78",&r,&ext)==1U);
  assert(r.address==0U);
  puts("PASS: Intel HEX line parsing, extended addresses, checksum rejection");
}
static void filters(void)
{
  int16_t a[FILTER_N],b[FILTER_N];
  for(unsigned trial=0;trial<10000;++trial) {
    for(unsigned i=0;i<FILTER_N;++i) {
      int16_t x=(int16_t)(rand()^((unsigned)rand()<<7));
      if(trial==0) x=-32768;
      if(trial==1) x=32767;
      if(trial==2) x=(int16_t)(FILTER_N-i);
      a[i]=b[i]=x;
    }
    qsort(b,FILTER_N,sizeof b[0],cmp);
    int32_t sum=0;
    for(unsigned i=2;i<FILTER_N-2U;++i) sum+=b[i];
    assert(Filter_TrimmedMean(a)==sum/(int32_t)(FILTER_N-4U));
    assert(memcmp(a,b,sizeof a)==0);
  }
}
static void protocol(void)
{
  const char *s="CSCCPL001PL013PL320PL999PS0PS1PS8PS9\r\n";
  const Command expected[]={
    {CMD_START,0},{CMD_STOP,0},{CMD_LENGTH,1},{CMD_LENGTH,13},
    {CMD_LENGTH,320},{CMD_LENGTH,999},{CMD_SPEED,0},{CMD_SPEED,1},{CMD_SPEED,8},{CMD_SPEED,9}
  };
  /* Each byte delivered separately, as if split across arbitrary USB packets. */
  CommandParser p={0}; unsigned n=0;
  for(unsigned i=0;s[i];++i) {
    Command c=Protocol_Push(&p,(uint8_t)s[i],i);
    if(c.type) { assert(n<sizeof expected/sizeof expected[0]);
      assert(c.type==expected[n].type && c.value==expected[n].value); ++n; }
  }
  assert(n==sizeof expected/sizeof expected[0]);
  memset(&p,0,sizeof p);
  Protocol_Push(&p,'P',0); Protocol_Push(&p,'L',1); Protocol_Push(&p,'1',2);
  assert(Protocol_Push(&p,'2',300).type==CMD_NONE);
  assert(Protocol_Push(&p,'3',301).type==CMD_NONE);
  Protocol_Push(&p,'P',302); Protocol_Push(&p,'L',303);
  assert(Protocol_Push(&p,'C',304).type==CMD_NONE);
  assert(Protocol_Push(&p,'C',305).type==CMD_STOP);
  /* Уровни ЦАП: DA1/DB1/DA2/DB2 + 4 цифры, мусор внутри - CMD_INVALID. */
  memset(&p,0,sizeof p);
  const char *d="DA12048DB11000DA24095DB20000DA34095DAL1D\r\n";
  const Command dexp[]={
    {CMD_DAC_A1,2048},{CMD_DAC_B1,1000},{CMD_DAC_A2,4095},{CMD_DAC_B2,0},
    {CMD_INVALID,0},{CMD_INVALID,0}
  };
  unsigned m=0;
  for(unsigned i=0;d[i];++i) {
    Command c=Protocol_Push(&p,(uint8_t)d[i],i);
    if(c.type) { assert(m<sizeof dexp/sizeof dexp[0]);
      assert(c.type==dexp[m].type && c.value==dexp[m].value); ++m; }
  }
  assert(m==sizeof dexp/sizeof dexp[0]);
  /* Незавершённая команда уровней сбрасывается по тайм-ауту. */
  memset(&p,0,sizeof p);
  Protocol_Push(&p,'D',0); Protocol_Push(&p,'B',1); Protocol_Push(&p,'2',2);
  assert(Protocol_Push(&p,'0',300).type==CMD_NONE);
  /* BT - переход в загрузчик; B с другим символом - ошибка формы. */
  memset(&p,0,sizeof p);
  Protocol_Push(&p,'B',0);
  assert(Protocol_Push(&p,'T',1).type==CMD_BOOT);
  memset(&p,0,sizeof p);
  Protocol_Push(&p,'B',0);
  assert(Protocol_Push(&p,'X',1).type==CMD_INVALID);
  assert(Motion_LengthUnits(20)==72282U);
  assert(Motion_LengthUnits(999)==3610504U);
  for(uint8_t i=0;i<=8;++i) assert(Motion_PulseHz(i)==9035U);
}
static void pulse(void)
{
  assert(timer2.CR1&TIM_CR1_CEN);
  advance(timer2.ARR+1U);
  timer2.SR=TIM_SR_CC2IF;
  TIM2_IRQHandler();
  Motor_Poll();
}
static void settle(void) { Motor_Poll(); advance(KONC_CONFIRM_US+1); Motor_Poll(); }
static void finish_position(void)
{
  unsigned budget=500000;
  while(motor_status.state!=MOTOR_READY && motor_status.state!=MOTOR_FAULT && budget--) {
    if(timer2.CR1&TIM_CR1_CEN) pulse();
    else { advance(1001); Motor_Poll(); }
  }
  assert(budget && motor_status.state==MOTOR_READY);
}
static void home_to_ready(void)
{
  /* Mode setup and hold complete before homing. */
  advance(1001); Motor_Poll(); advance(1001); Motor_Poll();
  assert(motor_status.state==MOTOR_HOME_SEEK_IN);
  assert(!(timer2.CR1&TIM_CR1_CEN)); /* Metal already present: no inward STEP. */
  settle();
  assert(motor_status.state==MOTOR_HOME_OUT);
  for(unsigned i=0;i<5;++i) pulse();
  portf.IDR=Konc_Pin; pulse();
  assert(!(timer2.CR1&TIM_CR1_CEN));
  settle(); assert(motor_status.state==MOTOR_HOME_IN);
  for(unsigned i=0;i<3;++i) pulse();
  portf.IDR=0; pulse(); settle();
  assert(motor_status.backlash_units==4U*(1U<<motor_status.active_speed));
  assert(motor_status.state==MOTOR_POSITION_OUT);
  assert(motor_status.position_valid && motor_status.position_units==0);
  portf.IDR=Konc_Pin;
  finish_position();
}
static void motor(void)
{
  memset(&motor_status,0,sizeof motor_status);
  portf.IDR=0; Motor_Init(); home_to_ready();
  assert(motor_status.position_units==(int32_t)Motion_LengthUnits(20));
  Motor_StopScan(); assert(motor_status.state==MOTOR_READY);
  Motor_StartScan(); assert(Motor_IsScanning());
  for(unsigned i=0;i<25;++i) pulse();
  /* CC ends scan, then the instrument returns and compensates. */
  Motor_StopScan(); pulse(); assert(motor_status.state==MOTOR_RETURN_OUT);
  assert(!Motor_IsScanning()); finish_position();
  assert(motor_status.position_units==(int32_t)Motion_LengthUnits(20));
  Motor_StartScan();
  for(unsigned i=0;i<8;++i) pulse();
  /* Optical glitch pauses immediately but must not terminate the scan. */
  portf.IDR=0; pulse(); portf.IDR=Konc_Pin; Motor_Poll();
  assert(Motor_IsScanning() && (timer2.CR1&TIM_CR1_CEN));
  pulse(); portf.IDR=0; pulse(); settle();
  assert(motor_status.state==MOTOR_RETURN_OUT);
  portf.IDR=Konc_Pin; finish_position();
  assert(motor_status.position_units==(int32_t)Motion_LengthUnits(20));
  Motor_StartScan(); pulse();
  portf.IDR=0; pulse();
  Motor_StopScan(); Motor_Poll();
  assert(motor_status.state==MOTOR_RETURN_OUT); /* CC during confirmation */
  portf.IDR=Konc_Pin; finish_position();
  Motor_SetSpeed(8); Motor_Poll();
  assert(motor_status.state==MOTOR_MODE_RESET);
  portf.IDR=0; home_to_ready();
  assert(motor_status.active_speed==8);
  assert(abs(motor_status.position_units-(int32_t)Motion_LengthUnits(20))<256);
  /* CC is deliberately ignored during preparation. */
  Motor_SetLength(13); Motor_Poll(); Motor_StopScan();
  assert(motor_status.state==MOTOR_HOME_SEEK_IN);
  Motor_Fault(); Motor_StartScan();
  assert(motor_status.state==MOTOR_FAULT && !(timer2.CR1&TIM_CR1_CEN));
}
static void reflective_limit(void)
{
  /* Actual GP2S700HCP circuit: metal -> LOW, no metal -> external +5V HIGH. */
  assert(KONC_ACTIVE_LEVEL==0);
  memset(&motor_status,0,sizeof motor_status);
  portf.IDR=Konc_Pin; /* Powered up already extended, no reflecting metal. */
  Motor_Init();
  assert(sensor_pull==GPIO_NOPULL && sensor_mode==GPIO_MODE_INPUT);
  advance(1001); Motor_Poll(); advance(1001); Motor_Poll();
  assert(motor_status.state==MOTOR_HOME_SEEK_IN && !motor_status.position_valid);
  assert(timer2.CR1&TIM_CR1_CEN);
  for(unsigned i=0;i<100000;++i) pulse(); /* >2 mm, must not count as backlash. */
  assert(motor_status.state==MOTOR_HOME_SEEK_IN && !motor_status.faults);
  portf.IDR=0; pulse();
  assert(!(timer2.CR1&TIM_CR1_CEN));
  settle(); assert(motor_status.state==MOTOR_HOME_OUT);
  assert(!motor_status.position_valid && motor_status.position_units==0);
  for(unsigned i=0;i<5;++i) pulse();
  portf.IDR=Konc_Pin; pulse(); settle();
  assert(motor_status.state==MOTOR_HOME_IN && !motor_status.position_valid);
  for(unsigned i=0;i<3;++i) pulse();
  portf.IDR=0; pulse();
  assert(!(timer2.CR1&TIM_CR1_CEN) && !motor_status.position_valid);
  settle();
  assert(motor_status.backlash_units==4 && motor_status.position_units==0);
  assert(motor_status.position_valid && motor_status.state==MOTOR_POSITION_OUT);
  portf.IDR=Konc_Pin; finish_position();
  assert(Motor_StartScan()==MOTOR_OK);
  for(unsigned i=0;i<5;++i) pulse();
  portf.IDR=0; pulse();
  assert(!(timer2.CR1&TIM_CR1_CEN));
  settle();
  assert(motor_status.state==MOTOR_RETURN_OUT && motor_status.position_units==0);
  assert(motor_status.position_valid);
  portf.IDR=Konc_Pin; finish_position();
  /* A sensor that never detects metal must terminate the initial search. */
  memset(&motor_status,0,sizeof motor_status); portf.IDR=Konc_Pin;
  Motor_Init(); advance(1001); Motor_Poll(); advance(1001); Motor_Poll();
  advance(60000000); Motor_Poll();
  assert(motor_status.state==MOTOR_FAULT && !(timer2.CR1&TIM_CR1_CEN));
  assert(!motor_status.position_valid);
  /* Metal permanently detected: release search also has a hard deadline. */
  memset(&motor_status,0,sizeof motor_status); portf.IDR=0;
  Motor_Init(); advance(1001); Motor_Poll(); advance(1001); Motor_Poll(); settle();
  assert(motor_status.state==MOTOR_HOME_OUT);
  advance(60000000); Motor_Poll();
  assert(motor_status.state==MOTOR_FAULT && !(timer2.CR1&TIM_CR1_CEN));
  puts("PASS: GP2S700HCP active-low/NOPULL, extended startup, isolated backlash, zero on metal detection, stuck levels");
}
static void long_scan(void)
{
  /* The slowest, longest valid scan must not trip a short fixed timeout. */
  memset(&motor_status,0,sizeof motor_status);
  portf.IDR=0; Motor_Init();
  Motor_SetLength(999);
  advance(1001); Motor_Poll(); advance(1001); Motor_Poll();
  settle();
  portf.IDR=Konc_Pin; pulse(); settle();
  portf.IDR=0; pulse(); settle();
  portf.IDR=Konc_Pin;
  unsigned budget=4000000;
  while(motor_status.state!=MOTOR_READY && budget--) pulse();
  assert(budget && motor_status.state==MOTOR_READY);
  Motor_StartScan();
  for(unsigned i=0;i<1900000;++i) pulse(); /* >210 seconds */
  assert(Motor_IsScanning() && !motor_status.faults);
  Motor_StopScan(); pulse();
  assert(motor_status.state==MOTOR_RETURN_OUT);
  Motor_Fault();
}
static void led(void)
{
  assert(Led_LevelFromSdadc(-32768)==0);
  assert(Led_LevelFromSdadc(0)==32768);
  assert(Led_LevelFromSdadc(32767)==65535);
  assert(Led_LevelFromSdadc(INT32_MIN)==0);
  assert(Led_LevelFromSdadc(INT32_MAX)==65535);
  LedColor previous=Led_Rainbow(0);
  assert(previous.r==65280 && previous.g==0 && previous.b==0);
  for(uint32_t i=1;i<=65535;++i) {
    LedColor c=Led_Rainbow((uint16_t)i);
    assert(c.r<=65280 && c.g<=65280 && c.b<=65280);
    /* Every consecutive ADC code has a different interpolated color. */
    unsigned delta=(unsigned)(abs((int)c.r-previous.r)+abs((int)c.g-previous.g)+abs((int)c.b-previous.b));
    assert(delta>=4 && delta<=5);
    previous=c;
  }
  assert(previous.r==32640 && previous.g==0 && previous.b==65280);
  /* 256 displayed frames reproduce each fractional Q8 channel exactly
   * in the numerical average, including the extreme channel values. */
  for(uint32_t i=0;i<65536;i+=127U) {
    LedColor c=Led_Rainbow((uint16_t)i);
    LedDither error={0};
    uint32_t r=0,g=0,b=0;
    for(unsigned f=0;f<256;++f) {
      LedRgb rgb=Led_Dither(c,&error);
      r+=rgb.r; g+=rgb.g; b+=rgb.b;
    }
    assert(r==c.r && g==c.g && b==c.b);
    assert(!error.r && !error.g && !error.b);
  }
  assert(Led_Preparing(0).r && Led_Preparing(249).r);
  assert(!Led_Preparing(250).r && !Led_Preparing(499).r);
  assert(Led_Preparing(500).r && !Led_Preparing(750).r);
  const uint8_t bytes[3]={0x01,0x80,0xA5}; /* GRB */
  LedRgb rgb={0x80,0x01,0xA5};
  uint16_t words[LED_WS_WORDS];
  Led_Encode(rgb,words);
  for(unsigned i=0;i<24;++i)
    assert(words[i]==((bytes[i/8]&(1U<<(7U-i%8)))?LED_WS_ONE_TICKS:LED_WS_ZERO_TICKS));
  assert(words[24]==0);
  /* WS2812B-2020 timing limits, using exact integer clock ratios. */
  assert(LED_WS_PERIOD_TICKS==90);
  assert(LED_WS_ZERO_TICKS*1000U>=220U*72U && LED_WS_ZERO_TICKS*1000U<=380U*72U);
  assert(LED_WS_ONE_TICKS*1000U>=580U*72U && LED_WS_ONE_TICKS*1000U<=1000U*72U);
  assert((90U-LED_WS_ZERO_TICKS)*1000U>=580U*72U && (90U-LED_WS_ZERO_TICKS)*1000U<=1000U*72U);
  assert((90U-LED_WS_ONE_TICKS)*1000U>=220U*72U && (90U-LED_WS_ONE_TICKS)*1000U<=420U*72U);
  /* Model preload: TIM12 latches before TIM4 writes the next value. */
  uint16_t preload=0;
  for(unsigned cycle=0;cycle<27;++cycle) {
    uint16_t active=preload;
    if(cycle>=1 && cycle<=24) assert(active==words[cycle-1]);
    else assert(active==0);
    if(cycle<25) preload=words[cycle];
  }
  puts("PASS: all 65536 LED gradient levels, temporal averaging, 2 Hz blink, GRB, WS2812B timings and preload pipeline");
}
static void serial(void)
{
  char line[64];
  Serial_FormatTelemetry(line,sizeof line,-123,307200,1);
  assert(!strcmp(line,"Z=-123,X=8.500000\r\n"));
  Serial_FormatTelemetry(line,sizeof line,42,-307200,1);
  assert(!strcmp(line,"Z=42,X=-8.500000\r\n"));
  Serial_FormatTelemetry(line,sizeof line,-32768,1,1);
  assert(!strcmp(line,"Z=-32768,X=0.000028\r\n"));
  Serial_FormatTelemetry(line,sizeof line,32767,-1,1);
  assert(!strcmp(line,"Z=32767,X=-0.000028\r\n"));
  Serial_FormatTelemetry(line,sizeof line,0,0,1);
  assert(!strcmp(line,"Z=0,X=0.000000\r\n"));
  Serial_FormatTelemetry(line,sizeof line,0,123456,0);
  assert(!strcmp(line,"Z=0,X=NA\r\n"));
  int n=Serial_FormatTelemetry(line,sizeof line,INT32_MIN,INT32_MIN,1);
  assert(n>0 && n<(int)sizeof line && strstr(line,"X=-"));
  CommandReply r={{CMD_LENGTH,20},REPLY_OK};
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ACK=PL020\r\n"));
  r.command.type=CMD_SPEED; r.command.value=9; r=Serial_Execute(r.command);
  assert(r.code==REPLY_RANGE);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ERR=PS9,RANGE\r\n"));
  r.command.type=CMD_INVALID; r=Serial_Execute(r.command);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ERR=FORMAT\r\n"));
  assert(Serial_State(MOTOR_HOME_IN)==WIRE_HOMING);
  assert(Serial_State(MOTOR_READY)==WIRE_READY);
  assert(Serial_State(MOTOR_SCAN)==WIRE_SCAN);
  assert(Serial_State(MOTOR_RETURN_OUT)==WIRE_RETURN);
  memset(&motor_status,0,sizeof motor_status);
  portf.IDR=0; Motor_Init();
  Command cs={CMD_START,0},cc={CMD_STOP,0};
  assert(!motor_status.position_valid);
  assert(Serial_Execute(cs).code==REPLY_BUSY);
  assert(Serial_Execute(cc).code==REPLY_NOT_SCANNING);
  home_to_ready(); assert(motor_status.position_valid);
  for(uint8_t speed=0;speed<=8;++speed) {
    if(speed) {
      Motor_SetSpeed(speed); Motor_Poll();
      assert(!motor_status.position_valid);
      portf.IDR=0; home_to_ready();
    }
    assert(Serial_Execute(cs).code==REPLY_OK);
    assert(Serial_Execute(cs).code==REPLY_BUSY);
    int32_t before=motor_status.position_units;
    pulse(); assert(before-motor_status.position_units==(int32_t)(1U<<speed));
    assert(Serial_Execute(cc).code==REPLY_OK);
    pulse(); assert(motor_status.state==MOTOR_RETURN_OUT);
    finish_position();
    assert(motor_status.position_valid);
  }
  Motor_SetLength(0);
  assert(Serial_Execute(cs).code==REPLY_ZERO_LENGTH);
  Motor_Fault(); assert(Serial_Execute(cs).code==REPLY_FAULT);
  /* Уровни ЦАП не связаны с движением и работают даже в FAULT. */
  Command d={CMD_DAC_A1,2048};
  r=Serial_Execute(d);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ACK=DA12048\r\n"));
  d.type=CMD_DAC_B1; d.value=1000; r=Serial_Execute(d);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ACK=DB11000\r\n"));
  d.type=CMD_DAC_A2; d.value=4095; r=Serial_Execute(d);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ACK=DA24095\r\n"));
  d.type=CMD_DAC_B2; d.value=0; r=Serial_Execute(d);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ACK=DB20000\r\n"));
  assert(mock_a1==2048 && mock_b1==1000 && mock_a2==4095 && mock_b2==0);
  d.type=CMD_DAC_A1; d.value=4096; r=Serial_Execute(d);
  assert(r.code==REPLY_RANGE);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ERR=DA14096,RANGE\r\n"));
  assert(mock_a1==2048); /* при RANGE уровни не меняются */
  /* BT: запрос режима загрузки ПО, ответ ACK=BT. */
  Command b={CMD_BOOT,0};
  r=Serial_Execute(b);
  assert(r.code==REPLY_OK && upload_requests==1);
  Serial_FormatReply(line,sizeof line,r); assert(!strcmp(line,"ACK=BT\r\n"));
  puts("PASS: command ACK/ERR, coordinate units/rounding/sign/validity, all nine microstep modes");
}

USBD_HandleTypeDef hUsbDeviceFS;
AcquisitionStatus acquisition_status;
static USBD_CDC_HandleTypeDef usb_class;
static char usb_text[65536];
static size_t usb_used;
static uint8_t *usb_owned;
static uint16_t usb_owned_length;
static uint8_t usb_snapshot[64];
static unsigned usb_rearms;
extern volatile uint32_t instrument_command_overruns;
void Acquisition_Start(void) { }
void Acquisition_Stop(void) { }
void Acquisition_Poll(void) { }
void LED2020_Init(void) { }
void LED2020_Poll(void) { }
uint8_t DAC_Sine_CheckDma(void) { return 0; }
uint8_t USBD_CDC_ReceivePacket(USBD_HandleTypeDef *device)
{
  assert(device==&hUsbDeviceFS); ++usb_rearms; return USBD_OK;
}
uint8_t CDC_Transmit_FS(uint8_t *buffer,uint16_t length)
{
  if(hUsbDeviceFS.dev_state!=USBD_STATE_CONFIGURED || !hUsbDeviceFS.pClassData) return USBD_FAIL;
  if(usb_class.TxState) return USBD_BUSY;
  assert(length<=64 && usb_used+length<sizeof usb_text);
  memcpy(usb_text+usb_used,buffer,length); usb_used+=length; usb_text[usb_used]=0;
  usb_owned=buffer; usb_owned_length=length;
  memcpy(usb_snapshot,buffer,length); usb_class.TxState=1;
  return USBD_OK;
}
static void usb_complete(void)
{
  if(usb_class.TxState) assert(!memcmp(usb_owned,usb_snapshot,usb_owned_length));
  usb_class.TxState=0;
}
static void usb_pump(unsigned count)
{
  for(unsigned i=0;i<count;++i) {
    usb_complete(); advance(1000); Instrument_Poll();
  }
}
static unsigned occurrences(const char *needle)
{
  unsigned n=0;
  for(const char *p=usb_text;(p=strstr(p,needle))!=NULL;p+=strlen(needle)) ++n;
  return n;
}
static void usb(void)
{
  memset(&motor_status,0,sizeof motor_status);
  hUsbDeviceFS.dev_state=USBD_STATE_CONFIGURED;
  hUsbDeviceFS.pClassData=&usb_class;
  Instrument_UsbReset(); portf.IDR=0; Instrument_Init();
  acquisition_status.value=-123;
  usb_used=0; usb_text[0]=0;
  Instrument_Poll();
  /* Приветствие уходит отдельным пакетом и не сдвигает расписание телеметрии:
     первый проход отдаёт только его, измерение - следующим проходом. */
  assert(strstr(usb_text,"Hello!"));
  usb_complete(); advance(1000); Instrument_Poll();
  assert(strstr(usb_text,"Z=-123,X=NA\r\n"));
  assert(strstr(usb_text,"STATE=HOMING\r\n"));
  /* Stop reading IN. Replies and then RX fill up; no overwrite or execution
   * without room for the command's reply. Reconnect is not required to resume. */
  uint8_t packet[64];
  for(unsigned i=0;i<21;++i) memcpy(packet+i*3,"PS0",3);
  packet[63]='\n';
  unsigned accepted=0,batches=0;
  while(Instrument_UsbCanReceive() && batches++<16) {
    Instrument_UsbReceive(packet,64); accepted+=21;
    Instrument_Poll(); Instrument_Poll();
  }
  assert(batches<16 && !Instrument_UsbCanReceive());
  assert(!instrument_command_overruns);
  usb_complete(); usb_pump(200);
  assert(occurrences("ACK=PS0\r\n")==accepted);
  assert(Instrument_UsbCanReceive() && usb_rearms);
  const char *bad="PS9PL12xCCCS";
  Instrument_UsbReceive((const uint8_t*)bad,(uint32_t)strlen(bad)); usb_pump(20);
  assert(strstr(usb_text,"ERR=PS9,RANGE\r\n"));
  assert(strstr(usb_text,"ERR=FORMAT\r\n"));
  assert(strstr(usb_text,"ERR=CC,NOT_SCANNING\r\n"));
  assert(strstr(usb_text,"ERR=CS,BUSY\r\n"));
  /* Fresh session at a referenced position. */
  usb_complete(); Instrument_UsbReset();
  memset(&motor_status,0,sizeof motor_status); portf.IDR=0;
  Instrument_Init(); home_to_ready();
  usb_used=0; usb_text[0]=0;
  Instrument_Poll();                       /* приветствие отдельным пакетом */
  usb_complete(); Instrument_Poll();
  assert(strstr(usb_text,"STATE=READY\r\n"));
  assert(strstr(usb_text,"Z=-123,X=1.999990\r\n"));
  usb_pump(250);
  assert(occurrences("Z=-123,X=")==6); /* 20 Hz in READY */
  usb_used=0; usb_text[0]=0;
  Instrument_UsbReceive((const uint8_t*)"CS",2); usb_pump(1);
  assert(Motor_IsScanning()); assert(strstr(usb_text,"ACK=CS\r\n"));
  usb_pump(100);
  unsigned data_count=occurrences("Z=-123,X=");
  assert(data_count>=50 && data_count<=52); /* 500 Hz, no STEP simulated */
  /* Fill ACK queue while IN is busy, then CC still stops the active scan. */
  Instrument_UsbReceive(packet,64); Instrument_Poll(); Instrument_Poll();
  assert(Instrument_UsbCanReceive());
  Instrument_UsbReceive((const uint8_t*)"CC",2);
  pulse(); assert(motor_status.state==MOTOR_RETURN_OUT);
  usb_pump(60);
  assert(strstr(usb_text,"ACK=CC\r\n") && strstr(usb_text,"STATE=RETURN\r\n"));
  assert(!instrument_command_overruns);
  finish_position(); usb_complete(); Instrument_UsbReset();
  usb_used=0; usb_text[0]=0;
  Instrument_UsbReceive((const uint8_t*)"CSCC",4); Instrument_Poll();
  assert(Motor_IsScanning()); pulse();
  assert(motor_status.state==MOTOR_RETURN_OUT);
  usb_pump(5);
  assert(strstr(usb_text,"ACK=CS\r\n") && strstr(usb_text,"ACK=CC\r\n"));
  /* A new connection must not get stale replies from the old connection. */
  usb_complete(); Instrument_UsbReceive((const uint8_t*)"PS1",3);
  Instrument_UsbReset(); usb_used=0; usb_text[0]=0; usb_pump(5);
  assert(!strstr(usb_text,"ACK=PS1"));
  puts("PASS: actual USB app, ACK retention/backpressure, busy TX buffer, 500 Hz X/Z, prompt CC, reconnection");
}
int main(void)
{
  hexlines(); filters(); protocol(); motor(); reflective_limit(); long_scan(); led(); serial(); usb();
  puts("PASS: 10000 filter vectors, fixed-width protocol, mechanics, CC return, optical glitch, mode change, faults");
  return 0;
}
