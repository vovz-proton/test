#ifndef ASCII_OUTPUT_H
#define ASCII_OUTPUT_H
#include <stddef.h>
#include <stdint.h>
/* Bounded ASCII output for the fixed USB protocol. No printf format parser. */
typedef struct { char *data; size_t capacity, length; } AsciiOutput;
void Ascii_Init(AsciiOutput *out,char *data,size_t capacity);
void Ascii_Text(AsciiOutput *out,const char *text);
void Ascii_U32(AsciiOutput *out,uint32_t value,unsigned width);
void Ascii_I32(AsciiOutput *out,int32_t value);
int Ascii_End(AsciiOutput *out);
#endif