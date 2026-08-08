#ifndef NAMECARD_APP_H
#define NAMECARD_APP_H

#include <stdint.h>

typedef enum {
    APP_STATE_BOOT = 0,
    APP_STATE_RECEIVING = 1,
    APP_STATE_CHARGING = 2,
    APP_STATE_READY = 3,
    APP_STATE_EXECUTE_ACK = 4,
    APP_STATE_REFRESHING = 5,
    APP_STATE_COMPLETE = 6,
    APP_STATE_ERROR = 7
} app_state_t;

void app_init(void);
void app_process(void);
app_state_t app_state(void);

#endif
