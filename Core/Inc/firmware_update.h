/**
  ******************************************************************************
  * @file    firmware_update.h
  * @brief   Обновление ПО по USB (через COM-порт), без ST-LINK и без драйверов.
  *
  *   Раскладка флеша (страница 2 КБ, см. STM32F373C8TX_FLASH.ld):
  *     0x08000000..0x080077FF  приложение (30 КБ)
  *     0x08007800..0x08007FFF  копировщик .copyer (2 КБ, не перезаписывается)
  *     0x08008000..0x0800FFFF  область загрузки нового ПО (32 КБ)
  *
  *   Обновление: команда BT -> приложение принимает Intel HEX по COM в область
  *   загрузки -> команда GO -> маркер в RAM -> сброс -> копировщик переносит
  *   новое ПО на место приложения -> переход в приложение без второго сброса.
  ******************************************************************************
  */

#ifndef FIRMWARE_UPDATE_H
#define FIRMWARE_UPDATE_H

#include <stdint.h>

/* Hold USB D+ low before initialization/reset; does not use HAL. */
void Firmware_UsbHold(void);

/**
  * @brief  Вызывается в самом начале main() до HAL_Init(): если загружено новое
  *         ПО, переносит его на место приложения и передаёт управление новой версии.
  */
void    Firmware_BootCheck(void);

/**
  * @brief  Войти в режим загрузки ПО (команда BT).
  * @retval 1 - принято, 0 - занято (идёт сканирование).
  */
uint8_t Firmware_StartUpload(void);

/** @brief 1 - идёт приём нового ПО. */
uint8_t Firmware_UploadActive(void);

/** @brief  Принять байты из COM-порта (вызывается из прерывания USB). */
void    Firmware_UploadBytes(const uint8_t *data,uint32_t length);

/** @brief  1 - в кольцевом буфере есть место под целый USB-пакет. */
uint8_t Firmware_UploadCanReceive(void);

/** @brief  Обслуживание режима загрузки: стирание области, тайм-аут. */
void    Firmware_UploadService(void);

/** @brief  Выйти из режима загрузки, вернув прибор в рабочее состояние. */
void    Firmware_UploadAbort(void);

#endif /* FIRMWARE_UPDATE_H */
