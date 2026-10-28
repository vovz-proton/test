#include "main.h"
#include "instrument_app.h"
#include "serial_protocol.h"
#include "acquisition.h"
#include "dac_sine.h"
#include "led2020.h"
#include "firmware_update.h"
#include "usbd_cdc_if.h"
#include "usbd_def.h"
#include "usbd_cdc.h"
#include "ascii_output.h"
#include <string.h>

extern USBD_HandleTypeDef hUsbDeviceFS;
static CommandParser parser;
typedef struct { Command command; ReplyCode code; uint8_t handled; } QueuedCommand;
static QueuedCommand commands[64];
static volatile uint8_t head,tail;
/* Replies persist until USB accepts a packet. If the host stops reading,
 * stop executing more commands when full, then NAK OUT as the RX queue fills. */
static CommandReply replies[16];
static volatile uint8_t reply_head,reply_tail;
static volatile uint32_t usb_epoch;
static uint8_t tx_buffer[64];
static volatile uint8_t rx_paused;
static volatile WireState last_sent_state=WIRE_UNKNOWN;
static uint32_t next_tx;
static uint8_t last_scanning;
#if MOTOR_TRAVEL_CAL
static uint32_t last_cal_reported=UINT32_MAX;
#endif
volatile uint32_t instrument_usb_skipped, instrument_command_overruns;

/* --- Приветствие при подключении -------------------------------------------
   Пока HELLO_BRINGUP = 1, прошивка один раз отправляет отдельным пакетом две
   строки: имя прибора и версию. Отправляется при запуске, после нового
   USB-подключения и каждый раз, когда хост открывает порт (DTR). Для рабочего
   режима достаточно поставить 0. */
#define HELLO_BRINGUP    1
#if HELLO_BRINGUP
static uint8_t hello_line[]="Hello from PortProfMini\r\nFirmware " FIRMWARE_VERSION "\r\n";
static uint8_t hello_pending=1U;
#endif

uint8_t Instrument_UsbCanReceive(void)
{
  /* В режиме обновления место считается по кольцу загрузчика: пока его мало,
     endpoint отвечает NAK и хост сам тормозит поток. */
  if(Firmware_UploadActive()) return Firmware_UploadCanReceive();
  /* Reserve an entire 64-byte packet (at most 33 parser events). */
  return (uint8_t)((tail-head-1U)&63U)>=33U;
}
void Instrument_UsbLineState(uint16_t state)
{
#if MOTOR_TRAVEL_CAL
  if(state&1U) last_cal_reported=UINT32_MAX;
#endif
#if HELLO_BRINGUP
  /* bit 0 = DTR: хост открыл порт - здороваемся один раз. */
  if(state&1U) hello_pending=1U;
#else
  (void)state;
#endif
}
void Instrument_UsbReset(void)
{
#if MOTOR_TRAVEL_CAL
  last_cal_reported=UINT32_MAX;
#endif
  ++usb_epoch;
  head=tail=0; reply_head=reply_tail=0;
  parser.used=0; rx_paused=0; last_sent_state=WIRE_UNKNOWN;
#if HELLO_BRINGUP
  hello_pending=1U;           /* новое подключение - здороваемся один раз */
#endif
}
void Instrument_UsbReceive(const uint8_t *bytes,uint32_t length)
{
  uint32_t ms=HAL_GetTick();

  /* В режиме обновления ПО те же байты идут в загрузчик. */
  if(Firmware_UploadActive()) {
    Firmware_UploadBytes(bytes,length);
    rx_paused=!Instrument_UsbCanReceive();
    return;
  }

  for(uint32_t i=0;i<length;++i) {
    Command c=Protocol_Push(&parser,bytes[i],ms);
    if(c.type!=CMD_NONE) {
      uint8_t next=(head+1U)&63U;
      if(next==tail) { ++instrument_command_overruns; continue; }
      QueuedCommand queued={c,REPLY_OK,0};
      /* A received CC must still stop an active scan when the ACK queue is
       * blocked by a slow reader. Preserve its acceptance result for later.
       * Otherwise leave CC queued, so a preceding CS in the same packet works. */
      if(c.type==CMD_STOP && Motor_IsScanning()) {
        queued.code=Serial_Execute(c).code; queued.handled=1;
      }
      commands[head]=queued; __DMB(); head=next;
    }
  }
  rx_paused=!Instrument_UsbCanReceive();
}
void Instrument_Init(void)
{
  Motor_Init(); LED2020_Init(); Acquisition_Start();
  next_tx=HAL_GetTick();
}
static void execute_commands(void)
{
  /* Bounded work per main-loop pass, even under a continuous command stream. */
  for(unsigned i=0;i<8U;++i) {
    QueuedCommand c;
    uint32_t mask=__get_PRIMASK(); __disable_irq();
    if(tail==head || ((reply_head+1U)&15U)==reply_tail) {
      __set_PRIMASK(mask); break;
    }
    uint32_t epoch=usb_epoch;
    c=commands[tail]; tail=(tail+1U)&63U;
    __set_PRIMASK(mask);
    CommandReply reply={c.command,c.code};
    if(!c.handled) reply=Serial_Execute(c.command);
    mask=__get_PRIMASK(); __disable_irq();
    if(epoch==usb_epoch) {
      replies[reply_head]=reply; __DMB(); reply_head=(reply_head+1U)&15U;
    }
    __set_PRIMASK(mask);
    /* Commands after accepted BT belong to neither normal operation nor HEX.
     * Do not execute a queued CS after acquisition has already been stopped. */
    if(Firmware_UploadActive()) {
      mask=__get_PRIMASK(); __disable_irq();
      tail=head; parser.used=0;
      __set_PRIMASK(mask);
      break;
    }
  }
}
static uint8_t append(const char *line,int length,uint16_t *used)
{
  if(length<=0 || (unsigned)length>sizeof tx_buffer-*used) return 0;
  memcpy(tx_buffer+*used,line,(size_t)length);
  *used+=(uint16_t)length;
  return 1;
}
static void transmit(void)
{
  uint8_t scanning=Motor_IsScanning();
  uint32_t now=HAL_GetTick(),period=scanning?2U:50U;
  if(scanning!=last_scanning) { next_tx=now; last_scanning=scanning; }
  uint8_t due=(int32_t)(now-next_tx)>=0;
  if(Firmware_UploadActive()) due=0U;   /* во время обновления ПО телеметрия не идёт */
  uint32_t mask=__get_PRIMASK(); __disable_irq();
  USBD_CDC_HandleTypeDef *cdc=(USBD_CDC_HandleTypeDef*)hUsbDeviceFS.pClassData;
  uint8_t ready=hUsbDeviceFS.dev_state==USBD_STATE_CONFIGURED && cdc && !cdc->TxState;
  uint32_t epoch=usb_epoch;
  /* Coherent snapshot: a STEP IRQ cannot change position/validity between reads. */
  int32_t z=acquisition_status.value,x=motor_status.position_units;
  uint8_t valid=motor_status.position_valid;
  WireState state=Serial_State(motor_status.state);
  uint8_t have_reply=reply_tail!=reply_head;
  CommandReply reply={{CMD_NONE,0},REPLY_OK};
  if(have_reply) reply=replies[reply_tail];
  uint8_t state_due=state!=last_sent_state;
  __set_PRIMASK(mask);
  if(!ready) {
    if(due) { ++instrument_usb_skipped; next_tx=now+period; }
    return;
  }
#if HELLO_BRINGUP
  /* Приветствие уходит отдельным пакетом один раз на подключение и не сдвигает
     расписание телеметрии: если пакет занят, попробуем в следующем проходе. */
  if(hello_pending) {
    mask=__get_PRIMASK(); __disable_irq();
    uint8_t sent=epoch==usb_epoch &&
                 CDC_Transmit_FS(hello_line,(uint16_t)(sizeof hello_line-1U))==USBD_OK;
    if(sent) hello_pending=0U;
    __set_PRIMASK(mask);
    if(sent) return;
  }
#endif
  /* Calibration state/result persists in RAM and is resent on USB reconnect. */
#if MOTOR_TRAVEL_CAL
  uint32_t phase=motor_calibration.phase;
  if(phase!=last_cal_reported) {
    AsciiOutput cal;
    Ascii_Init(&cal,(char*)tx_buffer,sizeof tx_buffer);
    Ascii_Text(&cal,"CAL="); Ascii_U32(&cal,phase,0);
    Ascii_Text(&cal,",T_US="); Ascii_U32(&cal,motor_calibration.elapsed_us,0);
    Ascii_Text(&cal,",PULSES="); Ascii_U32(&cal,motor_calibration.pulses,0);
    Ascii_Text(&cal,",L_UM=30850\r\n");
    int n=Ascii_End(&cal);
    mask=__get_PRIMASK(); __disable_irq();
    uint8_t sent=n>0 && epoch==usb_epoch && CDC_Transmit_FS(tx_buffer,(uint16_t)n)==USBD_OK;
    if(sent) last_cal_reported=phase;
    __set_PRIMASK(mask);
    if(sent) return;
  }
#endif
  if(!due && !have_reply && !state_due) return;
  /* A USB packet can contain several CRLF-terminated lines. Reserve telemetry
   * first, so ACK traffic cannot starve the 20/500 Hz measurement schedule. */
  char line[64];
  uint16_t used=0;
  uint8_t sent_data=0,sent_reply=0,sent_state=0;
  if(due) {
    int n=Serial_FormatTelemetry(line,sizeof line,z,x,valid);
    sent_data=append(line,n,&used);
  }
  if(have_reply) {
    int n=Serial_FormatReply(line,sizeof line,reply);
    sent_reply=append(line,n,&used);
  }
  if(state_due) {
    AsciiOutput out;
    Ascii_Init(&out,line,sizeof line);
    Ascii_Text(&out,"STATE="); Ascii_Text(&out,Serial_StateName(state));
    Ascii_Text(&out,"\r\n");
    int n=Ascii_End(&out);
    sent_state=append(line,n,&used);
  }
  if(!used) return;
  mask=__get_PRIMASK(); __disable_irq();
  /* Also protects USB class state against deinitialization inside its IRQ. */
  uint8_t sent=epoch==usb_epoch && CDC_Transmit_FS(tx_buffer,used)==USBD_OK;
  if(sent) {
    if(sent_reply) reply_tail=(reply_tail+1U)&15U;
    if(sent_state) last_sent_state=state;
    if(sent_data) next_tx=now+period;
  }
  __set_PRIMASK(mask);
}
/** @brief Перевооружить приёмный endpoint, когда в очереди появилось место. */
static void usb_rearm(void)
{
  if(rx_paused && Instrument_UsbCanReceive()) {
    uint32_t mask=__get_PRIMASK(); __disable_irq();
    if(hUsbDeviceFS.dev_state==USBD_STATE_CONFIGURED && hUsbDeviceFS.pClassData) {
      rx_paused=0;
      (void)USBD_CDC_ReceivePacket(&hUsbDeviceFS);
    }
    __set_PRIMASK(mask);
  }
}
void Instrument_Poll(void)
{
  /* Режим обновления ПО: прибор не измеряет, порт занят загрузчиком. */
  if(Firmware_UploadActive()) {
    transmit();                   /* отдать ACK=BT и прочие ответы */
    LED2020_Poll();               /* show upload before erase blocks the CPU */
    Firmware_UploadService();     /* стереть область, разобрать принятое, тайм-аут */
    usb_rearm();
    LED2020_Poll();
    return;
  }

  Acquisition_Poll();
  if(DAC_Sine_CheckDma() && motor_status.state!=MOTOR_FAULT) Motor_Fault();
  execute_commands();
  /* Плавно подтянуть уровни/частоту/фазу к целям, не останавливая генерацию. */
  DAC_Sine_Service();
  Motor_Poll(); LED2020_Poll();
  usb_rearm();
  transmit();
}
