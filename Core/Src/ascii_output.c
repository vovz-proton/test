#include "ascii_output.h"
static void put(AsciiOutput *out,char c)
{
  if(out->length+1U<out->capacity) out->data[out->length]=c;
  ++out->length;
}
void Ascii_Init(AsciiOutput *out,char *data,size_t capacity)
{
  out->data=data; out->capacity=capacity; out->length=0;
}
void Ascii_Text(AsciiOutput *out,const char *text)
{
  while(*text) put(out,*text++);
}
void Ascii_U32(AsciiOutput *out,uint32_t value,unsigned width)
{
  char digits[10];
  unsigned n=0;
  do { digits[n++]=(char)('0'+value%10U); value/=10U; } while(value);
  while(width>n) { put(out,'0'); --width; }
  while(n) put(out,digits[--n]);
}
void Ascii_I32(AsciiOutput *out,int32_t value)
{
  uint32_t magnitude=(uint32_t)value;
  if(value<0) { put(out,'-'); magnitude=0U-magnitude; }
  Ascii_U32(out,magnitude,0);
}
int Ascii_End(AsciiOutput *out)
{
  if(out->capacity) {
    size_t n=out->length<out->capacity?out->length:out->capacity-1U;
    out->data[n]=0;
  }
  return (int)out->length;
}