#include "instrument_logic.h"

Command Protocol_Push(CommandParser *p,uint8_t c,uint32_t ms)
{
  Command out={CMD_NONE,0};
  if((uint32_t)(ms-p->last_ms)>COMMAND_TIMEOUT_MS) p->used=0;
  p->last_ms=ms;
  /* Управляющие символы и пробелы в разборе не участвуют: иначе хвостовой
   * CR/LF после неполной команды давал бы ложный ERR=FORMAT. */
  if(c=='\r' || c=='\n' || c==' ' || c=='\t') return out;
  /* Продолжение DB/DA имеет приоритет над "стартовой" буквой B: иначе
   * DB1/DB2 (уровни второго ЦАП) разбирались бы как начало BT. */
  if(p->used==1 && p->bytes[0]=='D' && (c=='A' || c=='B')) {
    p->bytes[p->used++]=(char)c;
    return out;
  }
  if(c=='P' || c=='C' || c=='D' || c=='B' || c=='F') {
    if(p->used==1 && p->bytes[0]=='C' && c=='C') {
      out.type=CMD_STOP; p->used=0; return out;
    }
    p->bytes[0]=(char)c; p->used=1; return out;
  }
  if(p->used==1) {
    if(p->bytes[0]=='C' && c=='S') { out.type=CMD_START; p->used=0; }
    else if(p->bytes[0]=='B' && c=='T') { out.type=CMD_BOOT; p->used=0; }
    else if(p->bytes[0]=='P' && (c=='L' || c=='S' || c=='H')) p->bytes[p->used++]=(char)c;
    else if(p->bytes[0]=='F' && c>='0' && c<='9') p->bytes[p->used++]=(char)c;
    else { p->used=0; out.type=CMD_INVALID; }
  } else if(p->used>=2) {
    /* PH+450/PH-045: знак идёт до цифр, остальные команды его не допускают. */
    if(p->used==2 && p->bytes[0]=='P' && p->bytes[1]=='H') {
      if(c=='+' || c=='-') p->bytes[p->used++]=(char)c;
      else { p->used=0; out.type=CMD_INVALID; }
      return out;
    }
    if(c<'0' || c>'9') { p->used=0; out.type=CMD_INVALID; return out; }
    p->bytes[p->used++]=(char)c;
    if(p->bytes[0]=='P' && p->bytes[1]=='S') {
      out.type=CMD_SPEED; out.value=(int32_t)(c-'0');
      p->used=0;
    } else if(p->bytes[0]=='P' && p->bytes[1]=='L' && p->used==5) {
      out.type=CMD_LENGTH;
      out.value=(p->bytes[2]-'0')*100+(p->bytes[3]-'0')*10+p->bytes[4]-'0';
      p->used=0;
    } else if(p->bytes[0]=='P' && p->bytes[1]=='H' && p->used==6) {
      /* PH<знак><три цифры в десятых градуса>: PH+450 = +45.0, PH-045 = -4.5 */
      int32_t mag=(p->bytes[3]-'0')*100+(p->bytes[4]-'0')*10+p->bytes[5]-'0';
      out.type=CMD_PHASE;
      out.value=(p->bytes[2]=='-')?-mag:mag;
      p->used=0;
    } else if(p->bytes[0]=='F' && p->used==6) {
      /* F<5 цифр>: F08000 = 8000 Гц */
      out.type=CMD_FREQ;
      out.value=(p->bytes[1]-'0')*10000+(p->bytes[2]-'0')*1000+
                (p->bytes[3]-'0')*100+(p->bytes[4]-'0')*10+p->bytes[5]-'0';
      p->used=0;
    } else if(p->bytes[0]=='D' && p->used==7) {
      /* D<A|B><1|2><4 digits>: 0..9999, допустимый диапазон кодов проверяет
       * Serial_Execute (0..4095), здесь только форма записи. */
      if(p->bytes[2]=='1' || p->bytes[2]=='2') {
        if(p->bytes[1]=='A') {
          out.type=(p->bytes[2]=='1')?CMD_DAC_A1:CMD_DAC_A2;
        } else {
          out.type=(p->bytes[2]=='1')?CMD_DAC_B1:CMD_DAC_B2;
        }
        out.value=(p->bytes[3]-'0')*1000+(p->bytes[4]-'0')*100+
                  (p->bytes[5]-'0')*10+(p->bytes[6]-'0');
      } else {
        out.type=CMD_INVALID;
      }
      p->used=0;
    }
  }
  return out;
}

/* Heapsort: bounded O(N log N), constant extra memory. Signed SDADC codes. */
static void sift(int16_t *a,unsigned root,unsigned count)
{
  while(root*2U+1U<count) {
    unsigned child=root*2U+1U;
    if(child+1U<count && a[child]<a[child+1U]) ++child;
    if(a[root]>=a[child]) break;
    int16_t t=a[root]; a[root]=a[child]; a[child]=t;
    root=child;
  }
}
int32_t Filter_TrimmedMean(int16_t a[FILTER_N])
{
  for(unsigned i=FILTER_N/2U;i>0;--i) sift(a,i-1U,FILTER_N);
  for(unsigned n=FILTER_N;n>1U;--n) {
    int16_t t=a[0]; a[0]=a[n-1U]; a[n-1U]=t;
    sift(a,0,n-1U);
  }
  int32_t sum=0;
  for(unsigned i=2;i<FILTER_N-2U;++i) sum+=a[i];
  return sum/(int32_t)(FILTER_N-4U);
}
uint32_t Motion_LengthUnits(uint16_t tenths_mm)
{
  return ((uint32_t)tenths_mm*FULL_STEPS_PER_TRAVEL*256U+TRAVEL_TENTHS_MM/2U)/TRAVEL_TENTHS_MM;
}
uint32_t Motion_PulseHz(uint8_t speed)
{
  /* v=0.25*2^speed mm/s. All scan modes therefore have the same STEP rate. */
  (void)speed;
  return (FULL_STEPS_PER_TRAVEL*256U*5U+TRAVEL_TENTHS_MM)/(2U*TRAVEL_TENTHS_MM);
}
uint32_t Motion_AccelHz(uint8_t shift)
{
  return (MOTOR_ACCEL_MM_S2*FULL_STEPS_PER_TRAVEL*10U*(256U>>shift))/TRAVEL_TENTHS_MM;
}
