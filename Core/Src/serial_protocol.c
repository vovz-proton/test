#include "serial_protocol.h"
#include "dac_sine.h"
#include "firmware_update.h"
#include "ascii_output.h"

static ReplyCode result(MotorResult r)
{
  switch(r) {
    case MOTOR_OK: return REPLY_OK;
    case MOTOR_BUSY: return REPLY_BUSY;
    case MOTOR_NOT_SCANNING: return REPLY_NOT_SCANNING;
    case MOTOR_ZERO_LENGTH: return REPLY_ZERO_LENGTH;
    default: return REPLY_FAULT;
  }
}
/* DA1/DB1/DA2/DB2 - уровни ЦАП, независимые от двигателя. F/PH меняют
 * частоту и фазу генератора и тоже работают в любом состоянии, включая FAULT. */
static uint8_t is_level_command(CommandType t)
{
  return (uint8_t)(t==CMD_DAC_A1 || t==CMD_DAC_B1 || t==CMD_DAC_A2 || t==CMD_DAC_B2);
}
static void apply_level(Command c)
{
  uint16_t a1,b1,a2,b2;
  DAC_Sine_GetLevels(&a1,&b1,&a2,&b2);
  if(c.type==CMD_DAC_A1) a1=(uint16_t)c.value;
  else if(c.type==CMD_DAC_B1) b1=(uint16_t)c.value;
  else if(c.type==CMD_DAC_A2) a2=(uint16_t)c.value;
  else b2=(uint16_t)c.value;
  /* Только цели: генерация не останавливается, уровни подтягиваются плавно. */
  DAC_Sine_SetLevels(a1,b1,a2,b2);
}
CommandReply Serial_Execute(Command c)
{
  CommandReply reply={c,REPLY_OK};
  if(c.type==CMD_INVALID || c.type==CMD_NONE) reply.code=REPLY_FORMAT;
  else if((c.type==CMD_SPEED && (c.value<0 || c.value>8)) ||
          (c.type==CMD_LENGTH && (c.value<0 || c.value>999)) ||
          (is_level_command(c.type) && (c.value<0 || c.value>4095)) ||
          (c.type==CMD_FREQ && (c.value<(int32_t)DAC_SINE_FREQ_MIN ||
                                c.value>(int32_t)DAC_SINE_FREQ_MAX)) ||
          (c.type==CMD_PHASE && (c.value<-DAC_SINE_PHASE_MAX ||
                                 c.value>DAC_SINE_PHASE_MAX)))
    reply.code=REPLY_RANGE;
  else if(is_level_command(c.type)) apply_level(c);
  else if(c.type==CMD_FREQ) (void)DAC_Sine_SetFrequency((uint32_t)c.value);
  else if(c.type==CMD_PHASE) DAC_Sine_SetPhaseTenths((int16_t)c.value);
  else if(c.type==CMD_BOOT) { if(Firmware_StartUpload()==0U) reply.code=REPLY_BUSY; }
  else if(motor_status.faults || motor_status.state==MOTOR_FAULT) reply.code=REPLY_FAULT;
  else switch(c.type) {
    case CMD_START: reply.code=result(Motor_StartScan()); break;
    case CMD_STOP: reply.code=result(Motor_StopScan()); break;
    case CMD_LENGTH: Motor_SetLength((uint16_t)c.value); break;
    case CMD_SPEED: Motor_SetSpeed((uint8_t)c.value); break;
    default: reply.code=REPLY_FORMAT; break;
  }
  return reply;
}
int Serial_FormatReply(char *buffer,size_t size,CommandReply r)
{
  AsciiOutput out;
  Ascii_Init(&out,buffer,size);
  if(r.command.type==CMD_NONE || r.command.type==CMD_INVALID) {
    Ascii_Text(&out,"ERR=FORMAT\r\n"); return Ascii_End(&out);
  }
  Ascii_Text(&out,r.code==REPLY_OK?"ACK=":"ERR=");
  unsigned width=0;
  switch(r.command.type) {
    case CMD_START: Ascii_Text(&out,"CS"); break;
    case CMD_STOP: Ascii_Text(&out,"CC"); break;
    case CMD_LENGTH: Ascii_Text(&out,"PL"); width=3; break;
    case CMD_SPEED: Ascii_Text(&out,"PS"); width=1; break;
    case CMD_DAC_A1: Ascii_Text(&out,"DA1"); width=4; break;
    case CMD_DAC_B1: Ascii_Text(&out,"DB1"); width=4; break;
    case CMD_DAC_A2: Ascii_Text(&out,"DA2"); width=4; break;
    case CMD_DAC_B2: Ascii_Text(&out,"DB2"); width=4; break;
    case CMD_FREQ: Ascii_Text(&out,"F"); width=5; break;
    case CMD_PHASE: {
      int32_t v=r.command.value;
      Ascii_Text(&out,"PH");
      Ascii_Text(&out,v<0?"-":"+");
      Ascii_U32(&out,(uint32_t)(v<0?-v:v),3);
      width=0;
      break;
    }
    case CMD_BOOT: Ascii_Text(&out,"BT"); break;
    default:
      Ascii_Init(&out,buffer,size);
      Ascii_Text(&out,"ERR=FORMAT\r\n"); return Ascii_End(&out);
  }
  if(width) Ascii_U32(&out,(uint32_t)r.command.value,width);
  if(r.code!=REPLY_OK) {
    const char *reason;
    switch(r.code) {
      case REPLY_BUSY: reason="BUSY"; break;
      case REPLY_NOT_SCANNING: reason="NOT_SCANNING"; break;
      case REPLY_ZERO_LENGTH: reason="ZERO_LENGTH"; break;
      case REPLY_FAULT: reason="FAULT"; break;
      case REPLY_RANGE: reason="RANGE"; break;
      default: reason="FORMAT"; break;
    }
    Ascii_Text(&out,","); Ascii_Text(&out,reason);
  }
  Ascii_Text(&out,"\r\n");
  return Ascii_End(&out);
}
int Serial_FormatTelemetry(char *buffer,size_t size,int32_t z,int32_t units,uint8_t valid)
{
  AsciiOutput out;
  Ascii_Init(&out,buffer,size);
  Ascii_Text(&out,"Z="); Ascii_I32(&out,z); Ascii_Text(&out,",X=");
  if(!valid) Ascii_Text(&out,"NA");
  else {
    /* Units are 1/256 full step. All rounding uses integer arithmetic. */
    uint64_t magnitude=units<0?(uint64_t)(-(int64_t)units):(uint64_t)units;
    const uint32_t denominator=FULL_STEPS_PER_TRAVEL*256U;
    uint64_t millionths=(magnitude*TRAVEL_TENTHS_MM*100000U+denominator/2U)/denominator;
    if(units<0 && millionths) Ascii_Text(&out,"-");
    Ascii_U32(&out,(uint32_t)(millionths/1000000U),0);
    Ascii_Text(&out,".");
    Ascii_U32(&out,(uint32_t)(millionths%1000000U),6);
  }
  Ascii_Text(&out,"\r\n");
  return Ascii_End(&out);
}
WireState Serial_State(MotorState state)
{
  switch(state) {
    case MOTOR_READY: return WIRE_READY;
    case MOTOR_SCAN: return WIRE_SCAN;
    case MOTOR_RETURN_OUT: return WIRE_RETURN;
    case MOTOR_COMPENSATE: return motor_status.returning?WIRE_RETURN:WIRE_POSITIONING;
    case MOTOR_POSITION_OUT: return WIRE_POSITIONING;
    case MOTOR_FAULT: return WIRE_FAULT;
    default: return WIRE_HOMING;
  }
}
const char *Serial_StateName(WireState state)
{
  switch(state) {
    case WIRE_READY: return "READY";
    case WIRE_SCAN: return "SCAN";
    case WIRE_RETURN: return "RETURN";
    case WIRE_POSITIONING: return "POSITIONING";
    case WIRE_FAULT: return "FAULT";
    default: return "HOMING";
  }
}
