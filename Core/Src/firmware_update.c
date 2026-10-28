/**
  ******************************************************************************
  * @file    firmware_update.c
  * @brief   Обновление ПО по USB через COM-порт (без ST-LINK и без драйверов).
  *
  *   Почему так, а не заводским DFU: у STM32F373 подтяжка D+ внешняя и
  *   постоянная, а на этом ПК DFU-устройство занято драйвером STTub30, с
  *   которым STM32CubeProgrammer не работает. Поэтому обновление сделано
  *   целиком по имеющемуся COM-порту.
  *
  *   Схема:
  *     1) команда BT переводит прибор в режим загрузки: синус останавливается,
  *        область загрузки (0x08008000, 16 страниц) стирается;
  *     2) ПК шлёт файл .hex построчно; строки разбираются, данные пишутся
  *        полусловами в область загрузки; каждые 64 записи - прогресс "R******";
  *     3) команда GO: считается контрольная сумма, в RAM кладётся маркер,
  *        D+ удерживается в нуле (хост видит отключение) и МК перезапускается;
  *     4) Firmware_BootCheck() в начале main() видит маркер, вызывает копировщик
  *        .copyer: тот проверяет сумму и переносит 30 КБ на 0x08000000, после
  *        чего передаёт управление новой версии без второго сброса.
  *
  *   Копировщик лежит на отдельной странице и обновлением не перезаписывается,
  *   поэтому может копировать приложение "поверх себя". Он не использует HAL,
  *   прерывания и библиотечные функции - только регистры флеша.
  ******************************************************************************
  */

/* Includes ------------------------------------------------------------------*/
#include "main.h"
#include "instrument_config.h"
#include "firmware_update.h"
#include "hex_line.h"
#include "dac_sine.h"
#include "acquisition.h"
#include "motor.h"
#include "led2020.h"
#include "usbd_cdc_if.h"
#include "usbd_core.h"
#include "usbd_def.h"
#include "usbd_cdc.h"
#include "ascii_output.h"
#include <string.h>

/* Private define ------------------------------------------------------------*/

#define APP_BASE            0x08000000UL              /* приложение */
#define APP_SIZE            (30UL*1024UL)             /* 30 КБ, страницы 0..14 */
#define STAGING_BASE        0x08008000UL              /* область загрузки, страницы 16..31 */
#define STAGING_SIZE        (32UL*1024UL)
#define FLASH_PAGE          2048UL
#define STAGING_PAGES       (STAGING_SIZE/FLASH_PAGE)

#define MARKER_ADDR         0x20000000UL              /* первые 16 байт RAM */
#define MARKER_MAGIC        0x55504431UL              /* "UPD1" */

#define UPLOAD_TIMEOUT_MS   30000U
#define LINE_MAX            200U
#define PROGRESS_EVERY      64U
/** Кольцевой буфер приёма: USB-IRQ только складывает байты, разбор и запись
  * флеша идут в главном цикле. Пока места мало, endpoint отвечает NAK. */
#define RING_SIZE           512U
#define RING_RESERVE        128U

#define FNV_BASIS           2166136261UL
#define FNV_PRIME           16777619UL

/* Private types -------------------------------------------------------------*/

typedef enum { UPLOAD_IDLE=0U, UPLOAD_ERASE, UPLOAD_RECEIVE } UploadState;

/* Private variables ---------------------------------------------------------*/

extern USBD_HandleTypeDef hUsbDeviceFS;

static volatile UploadState upload_state;
static uint32_t upload_last_ms;
static uint32_t upload_records;
static uint32_t upload_errors;
static uint8_t upload_eof;
static uint8_t upload_tx[64];
static uint16_t line_used;
static char     line_buf[LINE_MAX];
static uint32_t hex_extended;
static volatile uint8_t  ring[RING_SIZE];
static volatile uint16_t ring_head,ring_tail;

/* Private function prototypes -----------------------------------------------*/

uint32_t Firmware_CopyStub(uint32_t source,uint32_t destination,
                           uint32_t length,uint32_t checksum);

/* Копировщик: отдельная страница флеша, только регистры, без HAL и библиотек. */
__attribute__((section(".copyer"),used,noinline))
uint32_t Firmware_CopyStub(uint32_t source,uint32_t destination,
                           uint32_t length,uint32_t checksum)
{
  uint32_t sum=FNV_BASIS;
  uint32_t offset;
  uint32_t page_len;
  uint32_t i;
  uint16_t value;

  /* 1. Сначала проверяем всю область загрузки - до любого стирания. */
  for(offset=0U;offset<length;offset+=4U)
  {
    sum=(sum^*(volatile uint32_t*)(source+offset))*FNV_PRIME;
  }
  if(sum!=checksum) return 0U;

  /* 2. Разблокировать FPEC. */
  FLASH->KEYR=FLASH_KEY1;
  FLASH->KEYR=FLASH_KEY2;

  /* 3. Постранично: стереть, записать полусловами, проверить чтением. */
  for(offset=0U;offset<length;offset+=FLASH_PAGE)
  {
    page_len=((length-offset)<FLASH_PAGE)?(length-offset):FLASH_PAGE;

    FLASH->CR|=FLASH_CR_PER;
    FLASH->AR=destination+offset;
    FLASH->CR|=FLASH_CR_STRT;
    while((FLASH->SR&FLASH_SR_BSY)!=0U)
    {
    }
    if((FLASH->SR&(FLASH_SR_PGERR|FLASH_SR_WRPERR))!=0U)
    {
      FLASH->CR&=~FLASH_CR_PER;
      FLASH->CR|=FLASH_CR_LOCK;
      return 0U;
    }
    FLASH->SR=FLASH_SR_EOP;
    FLASH->CR&=~FLASH_CR_PER;

    for(i=0U;i<page_len;i+=2U)
    {
      value=*(volatile uint16_t*)(source+offset+i);
      FLASH->CR|=FLASH_CR_PG;
      *(volatile uint16_t*)(destination+offset+i)=value;
      while((FLASH->SR&FLASH_SR_BSY)!=0U)
      {
      }
      if((FLASH->SR&(FLASH_SR_PGERR|FLASH_SR_WRPERR))!=0U)
      {
        FLASH->CR&=~FLASH_CR_PG;
        FLASH->CR|=FLASH_CR_LOCK;
        return 0U;
      }
      FLASH->SR=FLASH_SR_EOP;
      FLASH->CR&=~FLASH_CR_PG;
      if(*(volatile uint16_t*)(destination+offset+i)!=value)
      {
        FLASH->CR|=FLASH_CR_LOCK;
        return 0U;
      }
    }
  }
  FLASH->CR|=FLASH_CR_LOCK;
  /* Never return into the application we just replaced: its call site's
   * address may now hold unrelated instructions. Reset from this protected
   * copyer section, without calling code or loading constants from APP. */
  *(volatile uint32_t*)MARKER_ADDR=0U;
  __DSB();
  SCB->AIRCR=(0x5FAUL<<SCB_AIRCR_VECTKEY_Pos)|
             (SCB->AIRCR&SCB_AIRCR_PRIGROUP_Msk)|SCB_AIRCR_SYSRESETREQ_Msk;
  __DSB();
  for(;;) { }
}

/**
  * @brief  Отпустить USB-шину: удерживать D+ в нуле (только регистры, без HAL).
  * @note   Нужно, чтобы хост заметил отключение: подтяжка D+ на плате постоянная.
  */
void Firmware_UsbHold(void)
{
  RCC->AHBENR|=RCC_AHBENR_GPIOAEN;
  GPIOA->MODER=(GPIOA->MODER&~(3UL<<(12U*2U)))|(1UL<<(12U*2U));  /* PA12 - выход */
  GPIOA->OTYPER&=~(1UL<<12U);
  GPIOA->OSPEEDR|= (3UL<<(12U*2U));
  GPIOA->BSRR=(1UL<<12U)<<16U;                                   /* низкий уровень */
}

/** @brief Контрольная сумма области загрузки (FNV-1a по 32-битным словам). */
static uint32_t Firmware_StagingSum(void)
{
  uint32_t sum=FNV_BASIS;
  for(uint32_t i=0U;i<APP_SIZE;i+=4U)
  {
    sum=(sum^*(volatile uint32_t*)(STAGING_BASE+i))*FNV_PRIME;
  }
  return sum;
}

/** @brief Разблокировать/заблокировать программирование флеша. */
static void Firmware_FlashUnlock(void)
{
  FLASH->KEYR=FLASH_KEY1;
  FLASH->KEYR=FLASH_KEY2;
}
static void Firmware_FlashLock(void)
{
  FLASH->CR|=FLASH_CR_LOCK;
}

/** @brief Стереть одну страницу (2 КБ). */
static uint8_t Firmware_FlashErasePage(uint32_t address)
{
  uint8_t ok;

  FLASH->CR|=FLASH_CR_PER;
  FLASH->AR=address;
  FLASH->CR|=FLASH_CR_STRT;
  while((FLASH->SR&FLASH_SR_BSY)!=0U)
  {
  }
  ok=(uint8_t)((FLASH->SR&(FLASH_SR_PGERR|FLASH_SR_WRPERR))==0U);
  FLASH->SR=FLASH_SR_EOP;
  FLASH->CR&=~FLASH_CR_PER;
  return ok;
}

/** @brief Записать полуслово с проверкой чтением. */
static uint8_t Firmware_FlashWriteHalf(uint32_t address,uint16_t value)
{
  uint8_t ok;

  FLASH->CR|=FLASH_CR_PG;
  *(volatile uint16_t*)address=value;
  while((FLASH->SR&FLASH_SR_BSY)!=0U)
  {
  }
  ok=(uint8_t)((FLASH->SR&(FLASH_SR_PGERR|FLASH_SR_WRPERR))==0U);
  FLASH->SR=FLASH_SR_EOP;
  FLASH->CR&=~FLASH_CR_PG;
  if(ok!=0U && *(volatile uint16_t*)address!=value) ok=0U;
  return ok;
}

/** @brief Стереть всю область загрузки. */
static uint8_t Firmware_StagingErase(void)
{
  uint8_t ok=1U;

  Firmware_FlashUnlock();
  for(uint32_t page=0U;page<STAGING_PAGES;++page)
  {
    if(Firmware_FlashErasePage(STAGING_BASE+page*FLASH_PAGE)==0U) ok=0U;
    LED2020_Poll();
  }
  Firmware_FlashLock();
  return ok;
}

/** @brief Записать порцию данных в область загрузки (полусловами). */
static uint8_t Firmware_StagingWrite(uint32_t offset,const uint8_t *data,uint8_t length)
{
  if(length==0U) return 1U;
  if((offset+length)>APP_SIZE) return 0U;
  if(((offset|length)&1U)!=0U) return 0U;                  /* пишем только целые полуслова */

  Firmware_FlashUnlock();
  for(uint32_t i=0U;i<length;i+=2U)
  {
    uint16_t value=(uint16_t)((uint16_t)data[i]|((uint16_t)data[i+1U]<<8));
    if(Firmware_FlashWriteHalf(STAGING_BASE+offset+i,value)==0U)
    {
      Firmware_FlashLock();
      return 0U;
    }
  }
  Firmware_FlashLock();
  LED2020_Poll();
  return 1U;
}

/** @brief Отправить строку в COM-порт (ждём освобождения буфера, но недолго). */
static void Firmware_Send(const char *text)
{
  uint32_t start=HAL_GetTick();
  /* CDC keeps this pointer until IN completes; never give it a stack buffer.
   * Re-read class state because disconnect/reset can invalidate it in an IRQ. */
  do {
    LED2020_Poll();
    uint32_t mask=__get_PRIMASK();
    __disable_irq();
    USBD_CDC_HandleTypeDef *cdc=(USBD_CDC_HandleTypeDef*)hUsbDeviceFS.pClassData;
    if(hUsbDeviceFS.dev_state!=USBD_STATE_CONFIGURED || cdc==0) {
      __set_PRIMASK(mask); return;
    }
    if(!cdc->TxState) {
      size_t n=strlen(text);
      if(n<sizeof upload_tx) {
        memcpy(upload_tx,text,n);
        (void)CDC_Transmit_FS(upload_tx,(uint16_t)n);
      }
      __set_PRIMASK(mask); return;
    }
    __set_PRIMASK(mask);
  } while((uint32_t)(HAL_GetTick()-start)<100U);
}

/** @brief Проверить правдоподобие принятого образа перед установкой.
  * @note  Защита от "GO" без данных: иначе на место приложения лёг бы мусор из
  *        0xFF, и прибор пришлось бы спасать программатором. Проверяем, что
  *        получен конец HEX-файла и данные, стек указывает в RAM, а вектор сброса -
  *        внутрь приложения и с битом Thumb.
  */
static uint8_t Firmware_ImageLooksValid(void)
{
  uint32_t stack=*(volatile uint32_t*)STAGING_BASE;
  uint32_t entry=*(volatile uint32_t*)(STAGING_BASE+4U);

  if(!upload_eof || !upload_records) return 0U; /* complete HEX file required */
  if(stack<0x20000010UL || stack>0x20004000UL) return 0U;
  if(entry<APP_BASE || entry>=(APP_BASE+APP_SIZE)) return 0U;
  if((entry&1U)==0U) return 0U;                      /* Thumb-бит обязателен */
  return 1U;
}

/** @brief Завершение приёма: маркер, разрыв шины, перезапуск. */
static void upload_delay(uint32_t ms)
{
  uint32_t start=HAL_GetTick();
  do { LED2020_Poll(); } while((uint32_t)(HAL_GetTick()-start)<ms);
}
static void Firmware_Finish(void)
{
  char msg[24];
  volatile uint32_t *marker=(volatile uint32_t*)MARKER_ADDR;

  if(upload_errors!=0U)
  {
    AsciiOutput out;
    Ascii_Init(&out,msg,sizeof msg);
    Ascii_Text(&out,"ERR "); Ascii_U32(&out,upload_errors,0);
    Ascii_Text(&out,"\r\n"); (void)Ascii_End(&out);
    Firmware_Send(msg);
    return;                       /* остаёмся в режиме загрузки: можно повторить */
  }
  if(Firmware_ImageLooksValid()==0U)
  {
    Firmware_Send("ERR IMAGE\r\n");
    return;                       /* образ не принят: приложение не трогаем */
  }

  marker[1]=APP_SIZE;
  marker[2]=Firmware_StagingSum();
  marker[0]=MARKER_MAGIC;         /* магия пишется последней */
  Firmware_Send("DONE\r\n");
  upload_delay(100);              /* дать хосту принять ответ */
  /* Гасим USB целиком: иначе прерывание или класс успеют вернуть PA12 в режим
     USB, хост не увидит отключения и не перечислит устройство заново. */
  HAL_NVIC_DisableIRQ(USB_LP_IRQn);
  (void)USBD_DeInit(&hUsbDeviceFS);
  Firmware_UsbHold();
  upload_delay(500);
  NVIC_SystemReset();
}

/** @brief Обработать одну строку протокола загрузки. */
static void Firmware_Line(char *line)
{
  HexLine record;
  char msg[24];

  if(line[0]==':')
  {
    if(HexLine_Parse(line,&record,&hex_extended)==0U)
    {
      ++upload_errors;
      return;
    }
    if(record.type==0x01U) upload_eof=1U;
    if(record.type==0x00U && record.address>=APP_BASE)
    {
      uint32_t offset=record.address-APP_BASE;
      if(offset<APP_SIZE)         /* записи копировщика (от 30 КБ) пропускаем */
      {
        if(Firmware_StagingWrite(offset,record.data,record.length)==0U)
        {
          ++upload_errors;
          return;
        }
        ++upload_records;
        if((upload_records%PROGRESS_EVERY)==0U)
        {
          AsciiOutput out;
          Ascii_Init(&out,msg,sizeof msg);
          Ascii_Text(&out,"R"); Ascii_U32(&out,upload_records,6);
          Ascii_Text(&out,"\r\n"); (void)Ascii_End(&out);
          Firmware_Send(msg);
        }
      }
    }
    return;
  }
  if(strcmp(line,"BT")==0) {
    /* Start a clean retry, including erase and resetting previous errors. */
    upload_state=UPLOAD_ERASE;
    return;
  }
  if(strcmp(line,"GO")==0 || strcmp(line,"END")==0)
  {
    Firmware_Finish();
    return;
  }
  if(strcmp(line,"ID")==0)
  {
    Firmware_Send("UPD " FIRMWARE_VERSION "\r\n");
    return;
  }
  /* прочие строки игнорируем */
}

/* Exported functions --------------------------------------------------------*/

void Firmware_BootCheck(void)
{
  volatile uint32_t *marker=(volatile uint32_t*)MARKER_ADDR;

  if(marker[0]!=MARKER_MAGIC) return;
  if(marker[1]!=APP_SIZE) { marker[0]=0U; return; }

  /* Пока идёт копирование, хост не должен видеть устройство. */
  Firmware_UsbHold();

  /* Копировщик сначала проверяет сумму всей области загрузки и только потом
     стирает приложение: при плохой сумме прежняя версия остаётся целой.
     После копирования ОБЯЗАТЕЛЕН сброс: передать управление приложению "на
     ходу" нельзя, потому что код, который это делал бы, уже перезаписан новым
     образом (проверено на железе: МК зависал, USB не поднимался). Чистое
     перечисление обеспечивает удержание D+ в начале main(). */
  (void)Firmware_CopyStub(STAGING_BASE,APP_BASE,APP_SIZE,marker[2]);
  marker[0]=0U;
  NVIC_SystemReset();
}

uint8_t Firmware_StartUpload(void)
{
  if(upload_state!=UPLOAD_IDLE) return 1U;
  /* Flash operations suspend the main loop: do not enter during any motion. */
  if(motor_status.state!=MOTOR_READY && motor_status.state!=MOTOR_FAULT) return 0U;

  DAC_Sine_Stop();                /* выходы ЦАП больше не обновляются */
  Acquisition_Stop();             /* захват стоп: флеш-операции блокируют ядро */
  upload_records=0U;
  upload_errors=0U;
  line_used=0U;
  hex_extended=0U;
  upload_last_ms=HAL_GetTick();
  upload_state=UPLOAD_ERASE;
  return 1U;
}

uint8_t Firmware_UploadActive(void)
{
  return (uint8_t)(upload_state!=UPLOAD_IDLE);
}

void Firmware_UploadBytes(const uint8_t *data,uint32_t length)
{
  /* Вызывается из прерывания USB: только копируем байты в кольцо. */
  if(upload_state!=UPLOAD_RECEIVE) return;

  for(uint32_t i=0U;i<length;++i)
  {
    uint16_t next=(uint16_t)((ring_head+1U)%RING_SIZE);
    if(next==ring_tail)
    {
      ++upload_errors;            /* кольцо переполнено: хост шлёт слишком быстро */
      return;
    }
    ring[ring_head]=(uint8_t)data[i];
    ring_head=next;
  }
}

uint8_t Firmware_UploadCanReceive(void)
{
  uint16_t used=(uint16_t)((uint16_t)(ring_head-ring_tail+RING_SIZE)%RING_SIZE);
  return (uint8_t)(upload_state==UPLOAD_RECEIVE && (RING_SIZE-used)>=RING_RESERVE);
}

/** @brief Разобрать накопленные байты (главный цикл, не прерывание). */
static void Firmware_Drain(void)
{
  while(ring_tail!=ring_head)
  {
    char c=(char)ring[ring_tail];
    ring_tail=(uint16_t)((ring_tail+1U)%RING_SIZE);
    upload_last_ms=HAL_GetTick();

    if(c=='\n')
    {
      line_buf[line_used]='\0';
      if(line_used!=0U) Firmware_Line(line_buf);
      line_used=0U;
      if(upload_state!=UPLOAD_RECEIVE) return;
      continue;
    }
    if(c=='\r') continue;
    if(line_used<(LINE_MAX-1U)) line_buf[line_used++]=c;
    else
    {
      line_used=0U;
      ++upload_errors;            /* слишком длинная строка */
    }
  }
}

void Firmware_UploadService(void)
{
  if(upload_state==UPLOAD_IDLE) return;

  if(upload_state==UPLOAD_ERASE)
  {
    /* Let ACK=BT finish before flash erase stalls instruction fetch. */
    USBD_CDC_HandleTypeDef *cdc=(USBD_CDC_HandleTypeDef*)hUsbDeviceFS.pClassData;
    if(cdc!=0 && cdc->TxState) {
      if((uint32_t)(HAL_GetTick()-upload_last_ms)>UPLOAD_TIMEOUT_MS)
        Firmware_UploadAbort();
      return;
    }
    if(Firmware_StagingErase()==0U)
    {
      Firmware_Send("UPD ERASE_ERR\r\n");
      Firmware_UploadAbort();
      return;
    }
    ring_head=0U; ring_tail=0U; line_used=0U;
    upload_records=0U; upload_errors=0U; hex_extended=0U; upload_eof=0U;
    upload_last_ms=HAL_GetTick();
    upload_state=UPLOAD_RECEIVE;
    Firmware_Send("UPD READY\r\n");
    return;
  }

  Firmware_Drain();

  if((uint32_t)(HAL_GetTick()-upload_last_ms)>UPLOAD_TIMEOUT_MS)
  {
    Firmware_Send("UPD TIMEOUT\r\n");
    Firmware_UploadAbort();
  }
}

void Firmware_UploadAbort(void)
{
  if(upload_state==UPLOAD_IDLE) return;
  upload_state=UPLOAD_IDLE;
  line_used=0U;
  DAC_Sine_Start();               /* возвращаем генерацию возбуждения */
  Acquisition_Start();            /* и захват высоты */
}
