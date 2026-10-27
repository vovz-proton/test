/**
  ******************************************************************************
  * @file    hex_line.c
  * @brief   Разбор одной строки Intel HEX.
  *
  *   Формат: :LLAAAATT[DD...]CC
  *     LL   - число байт данных
  *     AAAA - 16-битный адрес или старшие 16 бит для типа 04
  *     TT   - тип записи: 00 данные, 01 конец файла, 04 старший адрес
  *     DD   - данные
  *     CC   - контрольная сумма: сумма всех байт строки (без ':') плюс CC = 0
  ******************************************************************************
  */

/* Includes ------------------------------------------------------------------*/
#include "hex_line.h"
#include <string.h>

/* Private functions ---------------------------------------------------------*/

/** @brief Одна hex-цифра; 0xFF - не цифра. */
static uint8_t hex_digit(char c)
{
  if(c>='0' && c<='9') return (uint8_t)(c-'0');
  if(c>='A' && c<='F') return (uint8_t)(c-'A'+10);
  if(c>='a' && c<='f') return (uint8_t)(c-'a'+10);
  return 0xFFU;
}

/** @brief Разобрать байт из двух символов; 1 - успех. */
static uint8_t hex_byte(const char *p,uint8_t *value)
{
  uint8_t hi=hex_digit(p[0]);
  uint8_t lo=hex_digit(p[1]);
  if(hi==0xFFU || lo==0xFFU) return 0U;
  *value=(uint8_t)((hi<<4)|lo);
  return 1U;
}

/* Exported functions --------------------------------------------------------*/

uint8_t HexLine_Parse(const char *line,HexLine *out,uint32_t *extended)
{
  uint8_t count,type,sum,byte,hi,lo;
  uint16_t address;
  uint32_t i;

  if(line==0 || out==0 || extended==0) return 0U;

  /* Пропускаем пробелы перед ':' */
  while(*line==' ' || *line=='\t' || *line=='\r' || *line=='\n') ++line;
  if(*line!=':') return 0U;
  ++line;

  size_t text_length=strlen(line);
  while(text_length && (line[text_length-1U]==' ' || line[text_length-1U]=='\t' ||
                        line[text_length-1U]=='\r' || line[text_length-1U]=='\n')) --text_length;
  if(text_length<10U || !hex_byte(line,&count)) return 0U;
  /* Validate the whole length before any further two-character reads. */
  if(count>HEX_LINE_MAX_DATA || text_length!=10U+2U*count) return 0U;
  line+=2;
  if(!hex_byte(line,&hi)) return 0U;
  if(!hex_byte(line+2,&lo)) return 0U;
  address=(uint16_t)(((uint16_t)hi<<8)|lo);
  line+=4;
  if(!hex_byte(line,&type)) return 0U;
  line+=2;

  sum=(uint8_t)(count+hi+lo+type);

  out->length=count;
  out->type=type;
  for(i=0U;i<count;++i)
  {
    if(!hex_byte(line,&byte)) return 0U;
    sum=(uint8_t)(sum+byte);
    out->data[i]=byte;
    line+=2;
  }
  if(!hex_byte(line,&byte)) return 0U;    /* контрольная сумма записи */
  sum=(uint8_t)(sum+byte);
  if(sum!=0U) return 0U;                  /* сумма всех байт, включая CC, равна 0 */

  if(type==0x04U)
  {
    if(count!=2U || address!=0U) return 0U;
    *extended=((uint32_t)out->data[0]<<24)|((uint32_t)out->data[1]<<16);
    out->address=*extended;
  }
  else
  {
    if(type==0x01U && (count!=0U || address!=0U)) return 0U;
    out->address=*extended+(uint32_t)address;
  }
  return 1U;
}
